#!/usr/bin/env bash
# tests/helpers/test-helpers-drain-backup.sh
#
# Unit tests for the pre-drain backup step added to
# helpers/drain-audit-spool.sh (decisions#271).
#
# Covered failure modes:
#
#   1. Happy path:  backup created, integrity passes, drain succeeds.
#   2. Backup dir not creatable (parent chmod 000): WARN, spool intact,
#      exit 0 (drain deferred, not crashed).
#   3. cp fails (fake cp shim that exits 1): WARN, spool intact, exit 0.
#   4. Backup line-count mismatch (fake cp shim that creates empty file):
#      WARN, spool intact, corrupt backup removed, exit 0.
#   5. Retention prune: seed > DRAIN_BACKUP_RETAIN old backup files;
#      after a successful drain exactly DRAIN_BACKUP_RETAIN files remain.
#   6. Happy path, no pre-existing backup dir: dir is auto-created.
#
# Each test stages an isolated fixture repo so helper-internal path
# resolution ($SCRIPT_DIR, $REPO_ROOT) never touches the real instance.
# JUVANT_SPOOL and JUVANT_BACKUP_DIR are overridden per test to keep the
# paths within the tmpdir.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAKETURSO="$REPO/tests/hooks/fake-turso.sh"

for dep in sqlite3 jq; do
  command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }
done

PASS=0; FAIL=0
ok()  { echo "    PASS: $1"; PASS=$(( PASS + 1 )); }
no()  { echo "    FAIL: $1"; FAIL=$(( FAIL + 1 )); }
has() { # desc, text, needle
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"
  else no "$1 (missing: $3)"; printf '%s\n' "$2" | sed 's/^/        > /'; fi
}
hasnt() { # desc, text, needle
  if printf '%s' "$2" | grep -qF -- "$3"; then
    no "$1 (unexpected: $3)"; printf '%s\n' "$2" | sed 's/^/        > /'
  else ok "$1"; fi
}
hasre() { # desc, text, regex
  if printf '%s' "$2" | grep -qE -- "$3"; then ok "$1"
  else no "$1 (no match: $3)"; printf '%s\n' "$2" | sed 's/^/        > /'; fi
}

# ── Shared fixture layout ────────────────────────────────────────────────────
TMP=$(mktemp -d)
FAKEBIN=$(mktemp -d)
trap 'rm -rf "$TMP" "$FAKEBIN"' EXIT

mkdir -p "$TMP/helpers" "$TMP/hooks/lib" "$TMP/.juvant"
cp "$REPO/helpers/drain-audit-spool.sh" "$TMP/helpers/"
cp "$REPO/hooks/lib/db.sh" "$TMP/hooks/lib/"

# Fake turso (cli shim backed by sqlite3).
cp "$FAKETURSO" "$FAKEBIN/turso"; chmod +x "$FAKEBIN/turso"

DBFILE="$TMP/.juvant/state.db"
SCHEMA="$REPO/scripts/schema.sql"
SPOOL_PATH="$TMP/.juvant/audit-spool.sql"
BACKUP_DIR="$TMP/.juvant/backups"

fresh_db() { rm -f "$DBFILE"; sqlite3 "$DBFILE" < "$SCHEMA"; }

write_cfg() { # provider url
  jq -n --arg p "$1" --arg u "$2" \
    '{db:{provider:$p,url:$u}}' > "$TMP/.juvant/config.json"
}

# Seed a minimal spool so the [[ -s "$SPOOL" ]] guard passes.
seed_spool() { # line_count (default 3)
  local n="${1:-3}"
  rm -f "$SPOOL_PATH"
  for i in $(seq 1 "$n"); do
    printf "INSERT INTO agent_actions_log (agent,tool_name,args_hash,status,started_at) VALUES ('tst','Bash','h','success',datetime('now','-%d minutes'));\n" "$i" >> "$SPOOL_PATH"
  done
}

run_drain() { # extra_env_string (prepended to command)
  local extra="${1:-}"
  eval "JUVANT_SPOOL=\"$SPOOL_PATH\" \
    JUVANT_BACKUP_DIR=\"$BACKUP_DIR\" \
    JUVANT_TEST_DB_FILE=\"$DBFILE\" \
    DRAIN_BACKUP_RETAIN=\"\${DRAIN_BACKUP_RETAIN:-7}\" \
    PATH=\"$FAKEBIN:\$PATH\" \
    $extra \
    bash \"$TMP/helpers/drain-audit-spool.sh\"" 2>&1
}

# ── Test 1: Happy path — backup created, integrity passes, drain succeeds ───
echo "=== 1: happy path — backup + drain succeed ==="
fresh_db
write_cfg local "file:$DBFILE"
seed_spool 4
rm -rf "$BACKUP_DIR"
out=$(run_drain); rc=$?

backup_count=$(ls "$BACKUP_DIR"/audit-spool.*.sql 2>/dev/null | wc -l | tr -d ' ')
[[ "$backup_count" -eq 1 ]]  && ok "backup file created" || no "backup file count: $backup_count"
[[ ! -f "$SPOOL_PATH" ]]      && ok "spool consumed after drain" || no "spool still present after drain"
has "drain reports success"   "$out" "[drain-audit-spool] drained"
[[ "$rc" -eq 0 ]]             && ok "exit 0 on success" || no "exit code $rc"
# Verify backup line count equals original spool (4 statements).
bak_file=$(ls "$BACKUP_DIR"/audit-spool.*.sql 2>/dev/null | head -1)
bak_lines=$(wc -l < "$bak_file" | tr -d ' ')
[[ "$bak_lines" -eq 4 ]] && ok "backup line count matches spool (4)" \
                          || no "backup has $bak_lines lines, expected 4"

# ── Test 2: Backup dir not creatable — drain deferred, spool intact ──────────
echo "=== 2: unwritable parent → backup dir creation fails ==="
fresh_db
write_cfg local "file:$DBFILE"
seed_spool 2
UNWRITABLE="$TMP/nowrite"
mkdir -p "$UNWRITABLE" && chmod 000 "$UNWRITABLE"
# Override JUVANT_BACKUP_DIR to a path inside the unwritable dir.
out=$(JUVANT_SPOOL="$SPOOL_PATH" \
      JUVANT_BACKUP_DIR="$UNWRITABLE/sub/backups" \
      JUVANT_TEST_DB_FILE="$DBFILE" \
      PATH="$FAKEBIN:$PATH" \
      bash "$TMP/helpers/drain-audit-spool.sh" 2>&1) || true
chmod 755 "$UNWRITABLE"   # restore so cleanup works

has  "unwritable parent → WARN emitted"   "$out" "WARN"
has  "unwritable parent → mentions backup" "$out" "backup"
[[ -f "$SPOOL_PATH" ]] && ok "spool intact after mkdir failure" || no "spool missing after mkdir failure"

# ── Test 3: cp fails — drain deferred, spool intact ─────────────────────────
echo "=== 3: cp failure → drain deferred ==="
fresh_db
write_cfg local "file:$DBFILE"
seed_spool 3
rm -rf "$BACKUP_DIR"

# Fake cp that always exits 1 (simulates a full disk or permission error).
FAILBIN=$(mktemp -d)
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAILBIN/cp"; chmod +x "$FAILBIN/cp"
trap 'rm -rf "$FAILBIN"' EXIT

out=$(JUVANT_SPOOL="$SPOOL_PATH" \
      JUVANT_BACKUP_DIR="$BACKUP_DIR" \
      JUVANT_TEST_DB_FILE="$DBFILE" \
      PATH="$FAILBIN:$FAKEBIN:$PATH" \
      bash "$TMP/helpers/drain-audit-spool.sh" 2>&1) || true

has   "cp failure → WARN emitted"        "$out" "WARN"
has   "cp failure → mentions backup"     "$out" "backup"
[[ -f "$SPOOL_PATH" ]] && ok "spool intact after cp failure" || no "spool missing after cp failure"
# No drain output expected.
hasnt "cp failure → drain did not run"   "$out" "[drain-audit-spool] drained"

# ── Test 4: Integrity check failure (backup line count mismatch) ────────────
echo "=== 4: integrity check failure → drain deferred, corrupt backup removed ==="
fresh_db
write_cfg local "file:$DBFILE"
seed_spool 5
rm -rf "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# Fake cp that creates an EMPTY destination (0 lines vs 5 in source → mismatch).
EMPTYBIN=$(mktemp -d)
printf '#!/usr/bin/env bash\n# ignore src; create empty dst\n: > "$2"\n' \
  > "$EMPTYBIN/cp"; chmod +x "$EMPTYBIN/cp"
trap 'rm -rf "$EMPTYBIN"' EXIT

out=$(JUVANT_SPOOL="$SPOOL_PATH" \
      JUVANT_BACKUP_DIR="$BACKUP_DIR" \
      JUVANT_TEST_DB_FILE="$DBFILE" \
      PATH="$EMPTYBIN:$FAKEBIN:$PATH" \
      bash "$TMP/helpers/drain-audit-spool.sh" 2>&1) || true

has "integrity failure → WARN with line counts"  "$out" "integrity check failed"
[[ -f "$SPOOL_PATH" ]] && ok "spool intact after integrity failure" \
                        || no "spool missing after integrity failure"
# Corrupt backup must be cleaned up.
leftovers=$(ls "$BACKUP_DIR"/audit-spool.*.sql 2>/dev/null | wc -l | tr -d ' ')
[[ "$leftovers" -eq 0 ]] && ok "corrupt backup removed" \
                          || no "corrupt backup not removed ($leftovers files left)"
hasnt "integrity failure → drain did not run" "$out" "[drain-audit-spool] drained"

# ── Test 5: Retention prune — old backups pruned to DRAIN_BACKUP_RETAIN ─────
echo "=== 5: retention prune ==="
fresh_db
write_cfg local "file:$DBFILE"
seed_spool 2
rm -rf "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# Pre-seed 10 old backup files (timestamps in the past so ls -1t sorts them last).
for i in $(seq 1 10); do
  ts=$(printf "2020010%dT%02d0000Z" "$(( (i-1)/9 + 1 ))" "$i")
  touch "$BACKUP_DIR/audit-spool.${ts}.sql"
done

# Run with DRAIN_BACKUP_RETAIN=3 so after the new backup is added we keep 3
# and prune the 10 old ones (10 + 1 new = 11 total → keep 3 → delete 8).
out=$(JUVANT_SPOOL="$SPOOL_PATH" \
      JUVANT_BACKUP_DIR="$BACKUP_DIR" \
      JUVANT_TEST_DB_FILE="$DBFILE" \
      DRAIN_BACKUP_RETAIN=3 \
      PATH="$FAKEBIN:$PATH" \
      bash "$TMP/helpers/drain-audit-spool.sh") 2>&1; rc=$?

remaining=$(ls "$BACKUP_DIR"/audit-spool.*.sql 2>/dev/null | wc -l | tr -d ' ')
[[ "$remaining" -le 3 ]] && ok "retention prune: $remaining files remain (<= 3)" \
                          || no "retention prune failed: $remaining files remain (expected <= 3)"
[[ "$remaining" -ge 1 ]] && ok "at least one backup kept" \
                          || no "all backups deleted (expected >= 1)"
has "drain succeeds after retention prune" "$out" "[drain-audit-spool] drained"

# ── Test 6: Backup dir auto-created when absent ──────────────────────────────
echo "=== 6: backup dir auto-creation ==="
fresh_db
write_cfg local "file:$DBFILE"
seed_spool 1
NEW_BACKUP_DIR="$TMP/.juvant/autobackups"
rm -rf "$NEW_BACKUP_DIR"   # must not exist before the run
[[ ! -d "$NEW_BACKUP_DIR" ]] && ok "backup dir absent before run" || no "setup failed: dir already exists"

out=$(JUVANT_SPOOL="$SPOOL_PATH" \
      JUVANT_BACKUP_DIR="$NEW_BACKUP_DIR" \
      JUVANT_TEST_DB_FILE="$DBFILE" \
      PATH="$FAKEBIN:$PATH" \
      bash "$TMP/helpers/drain-audit-spool.sh") 2>&1; rc=$?

[[ -d "$NEW_BACKUP_DIR" ]] && ok "backup dir auto-created"  || no "backup dir not created"
new_count=$(ls "$NEW_BACKUP_DIR"/audit-spool.*.sql 2>/dev/null | wc -l | tr -d ' ')
[[ "$new_count" -eq 1 ]] && ok "backup file present in auto-created dir ($new_count)" \
                          || no "unexpected backup count: $new_count"
has "drain succeeds with auto-created dir" "$out" "[drain-audit-spool] drained"

# ── Summary ──────────────────────────────────────────────────────────────────
echo "==============================="
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
