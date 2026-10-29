#!/usr/bin/env bash
# tests/helpers/test-drain-reclaim-stale.sh
#
# decisions#298 (L1-F1): helpers/drain-audit-spool.sh must re-claim batches
# stranded by a drain that was killed mid-loop ("$SPOOL.draining.<pid>" /
# "$SPOOL.merge.<pid>"), without duplicating rows the dead drain already
# committed, and without touching a live drain's file.
#
#   1. Stranded .draining.<deadpid>        -> applied, file removed, original preserved
#   2. Partially-applied batch (new format, explicit started_at) -> no duplicates
#   3. Partially-applied batch (legacy rows, no started_at)      -> no duplicates
#   4. Stranded .merge.<deadpid>           -> applied
#   5. Fresh file owned by a LIVE pid      -> untouched
#   6. Old file owned by a live pid        -> treated as stuck, reclaimed
#   7. Stale + live spool together         -> both applied, stale (older) first
#   8. Backend failure mid-reclaim         -> unapplied tail re-queued, file gone, exit 1
#   9. started_at on the row is honoured (not replaced by drain time)
#
# Each test uses an isolated fixture repo; JUVANT_SPOOL / JUVANT_BACKUP_DIR are
# overridden so nothing touches a real instance.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAKETURSO="$REPO/tests/hooks/fake-turso.sh"

for dep in sqlite3 jq; do
  command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }
done

PASS=0; FAIL=0
ok()  { echo "    PASS: $1"; PASS=$(( PASS + 1 )); }
no()  { echo "    FAIL: $1"; FAIL=$(( FAIL + 1 )); }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing: $3)"; printf '%s\n' "$2" | sed 's/^/        > /'; fi; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }

TMP=$(mktemp -d)
FAKEBIN=$(mktemp -d)
trap 'rm -rf "$TMP" "$FAKEBIN"' EXIT

mkdir -p "$TMP/helpers" "$TMP/hooks/lib" "$TMP/.juvant"
cp "$REPO/helpers/drain-audit-spool.sh" "$TMP/helpers/"
cp "$REPO/hooks/lib/db.sh" "$TMP/hooks/lib/"
cp "$FAKETURSO" "$FAKEBIN/turso"; chmod +x "$FAKEBIN/turso"
# G6 (decisions#303): writes go over libsql HTTP since #276 — fake BOTH transports.
cp "$REPO/tests/hooks/fake-libsql-curl.sh" "$FAKEBIN/curl"; chmod +x "$FAKEBIN/curl"

DBFILE="$TMP/.juvant/state.db"
SCHEMA="$REPO/scripts/schema.sql"
SPOOL="$TMP/.juvant/audit-spool.sql"
BACKUP_DIR="$TMP/.juvant/backups"

fresh() {
  rm -f "$DBFILE" "$SPOOL" "$SPOOL".draining.* "$SPOOL".merge.*
  rm -rf "$BACKUP_DIR"
  sqlite3 "$DBFILE" < "$SCHEMA"
  jq -n --arg u "file:$DBFILE" '{db:{provider:"local",url:$u}}' > "$TMP/.juvant/config.json"
}

H() { printf '%064x' "$1"; }
# Row with an explicit started_at (shape written by pre-tool-use.sh since #298).
row_new() { # n ts
  printf "INSERT INTO agent_actions_log (session_id, agent, tool_name, args_hash, status, deny_reason, input_summary, started_at) VALUES ('sess-1', 'cos', 'Bash', '%s', 'pending', NULL, 'cmd %s', '%s');\n" "$(H "$1")" "$1" "$2"
}
# Legacy row: no started_at column (shape written before #298).
row_old() { # n
  printf "INSERT INTO agent_actions_log (session_id, agent, tool_name, args_hash, status, deny_reason, input_summary) VALUES ('sess-1', 'cos', 'Bash', '%s', 'pending', NULL, 'cmd %s');\n" "$(H "$1")" "$1"
}
count() { sqlite3 "$DBFILE" "SELECT COUNT(*) FROM agent_actions_log;"; }

# A pid that is guaranteed dead.
DEADPID=$( (sleep 0 & echo $!) ); wait 2>/dev/null
while kill -0 "$DEADPID" 2>/dev/null; do DEADPID=$(( DEADPID + 7919 )); done

run() {
  JUVANT_SPOOL="$SPOOL" JUVANT_BACKUP_DIR="$BACKUP_DIR" JUVANT_TEST_DB_FILE="$DBFILE" \
    PATH="$FAKEBIN:$PATH" bash "$TMP/helpers/drain-audit-spool.sh" 2>&1
}

echo "=== 1: stranded .draining.<deadpid> is re-claimed ==="
fresh
{ row_new 1 "2026-07-28 10:00:00"; row_new 2 "2026-07-28 10:00:01"; row_new 3 "2026-07-28 10:00:02"; } > "$SPOOL.draining.$DEADPID"
out=$(run); rc=$?
eq "exit 0" "$rc" "0"
eq "3 rows applied" "$(count)" "3"
[[ ! -e "$SPOOL.draining.$DEADPID" ]] && ok "stranded file removed" || no "stranded file still present"
has "WARN names the stranded batch" "$out" "re-claiming stranded batch audit-spool.sql.draining.$DEADPID"
n=$(ls "$BACKUP_DIR"/audit-stale.*.sql 2>/dev/null | wc -l | tr -d ' ')
eq "original preserved in backups/" "$n" "1"

echo "=== 2: partially-applied batch (new format) -> no duplicates ==="
fresh
{ row_new 1 "2026-07-28 10:00:00"; row_new 2 "2026-07-28 10:00:01"; row_new 3 "2026-07-28 10:00:02"; } > "$SPOOL.draining.$DEADPID"
row_new 1 "2026-07-28 10:00:00" | sqlite3 "$DBFILE"   # the dead drain got this far
out=$(run)
eq "3 rows total (row 1 not duplicated)" "$(count)" "3"

echo "=== 3: partially-applied batch (legacy rows) -> no duplicates ==="
fresh
{ row_old 1; row_old 2; } > "$SPOOL.draining.$DEADPID"
row_old 1 | sqlite3 "$DBFILE"
out=$(run)
eq "2 rows total (legacy row 1 not duplicated)" "$(count)" "2"

echo "=== 4: stranded .merge.<deadpid> is re-claimed ==="
fresh
row_new 1 "2026-07-28 10:00:00" > "$SPOOL.merge.$DEADPID"
out=$(run)
eq "1 row applied" "$(count)" "1"
[[ ! -e "$SPOOL.merge.$DEADPID" ]] && ok "merge file removed" || no "merge file still present"

echo "=== 5: fresh file owned by a LIVE pid is untouched ==="
fresh
row_new 1 "2026-07-28 10:00:00" > "$SPOOL.draining.$$"      # $$ = this (live) test shell
out=$(run)
eq "no rows applied" "$(count)" "0"
[[ -e "$SPOOL.draining.$$" ]] && ok "live drain's file left alone" || no "live drain's file was taken"
rm -f "$SPOOL.draining.$$"

echo "=== 6: OLD file owned by a live pid is treated as stuck ==="
fresh
row_new 1 "2026-07-28 10:00:00" > "$SPOOL.draining.$$"
touch -t 202607281000 "$SPOOL.draining.$$"
out=$(run)
eq "row applied" "$(count)" "1"
[[ ! -e "$SPOOL.draining.$$" ]] && ok "stuck file reclaimed" || no "stuck file still present"

echo "=== 7: stale + live spool together; stale applied first ==="
fresh
row_new 1 "2026-07-28 10:00:00" > "$SPOOL.draining.$DEADPID"
row_new 2 "2026-10-28 10:00:00" > "$SPOOL"
out=$(run)
eq "2 rows applied" "$(count)" "2"
first=$(sqlite3 "$DBFILE" "SELECT input_summary FROM agent_actions_log ORDER BY id LIMIT 1;")
eq "stale (older) row got the lower id" "$first" "cmd 1"
[[ ! -e "$SPOOL" ]] && ok "live spool consumed" || no "live spool still present"

echo "=== 8: backend failure mid-reclaim -> tail re-queued, exit 1 ==="
fresh
# The failing statement must be an ALLOWLISTED shape (decisions#303 R3 — anything
# else is quarantined, not executed): a 'denied' row with an empty input_summary
# is rejected by the action_log_denied_requires_summary trigger.
row_fail() { printf "INSERT INTO agent_actions_log (session_id, agent, tool_name, args_hash, status, deny_reason, input_summary, started_at) VALUES ('sess-1', 'cos', 'Bash', '%s', 'denied', 'x', '', '2026-07-28 10:00:01');\n" "$(H 2)"; }
{ row_new 1 "2026-07-28 10:00:00"; row_fail; row_new 3 "2026-07-28 10:00:02"; } > "$SPOOL.draining.$DEADPID"
out=$(run); rc=$?
eq "exit 1" "$rc" "1"
eq "statement before the failure applied" "$(count)" "1"
[[ ! -e "$SPOOL.draining.$DEADPID" ]] && ok "stranded file removed (tail safely re-queued)" || no "stranded file still present"
eq "unapplied tail (2 statements) re-queued" "$(grep -c . "$SPOOL")" "2"
has "WARN reports re-queue" "$out" "re-queued"

echo "=== 9: explicit started_at is honoured, not replaced by drain time ==="
fresh
row_new 1 "2026-07-28 10:00:00" > "$SPOOL"
out=$(run)
eq "started_at is the action time" \
  "$(sqlite3 "$DBFILE" "SELECT started_at FROM agent_actions_log;")" "2026-07-28 10:00:00"

echo
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
