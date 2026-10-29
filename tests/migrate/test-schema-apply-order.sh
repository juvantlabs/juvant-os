#!/usr/bin/env bash
# tests/migrate/test-schema-apply-order.sh
#
# BUG-080 #1 + #2 (juvant-os-pm#182):
#   1. On an old-shape DB, the ADD COLUMN patches must land BEFORE schema.sql
#      creates triggers that name those columns — otherwise, between the two
#      steps (and forever, if the run aborts there under set -e), every write to
#      security_audit_log fails with "no such column".
#   2. migrate.sh must not report success when the DB CLI exited 0 without
#      applying anything (expired turso auth): it reads back every object.
#
# migrate.sh resolves its config/schema from $SCRIPT_DIR/.., so it is staged
# into a temp ROOT (as in test-dry-run-no-write.sh).

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for dep in sqlite3 jq; do
  command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }
done

PASS=0; FAIL=0
ok(){ echo "    PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$2' got '$3')"; fi; }
has(){ if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing: $3)"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then no "$1 (unexpectedly present: $3)"; else ok "$1"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
stage() { # <dir> — a staged ROOT with a local-provider config
  mkdir -p "$1/scripts" "$1/.juvant"
  cp "$REPO/scripts/migrate.sh" "$REPO/scripts/schema.sql" "$1/scripts/"
  jq -n --arg u "file:$1/.juvant/state.db" '{db:{provider:"local",url:$u}}' > "$1/.juvant/config.json"
}
col_exists() { sqlite3 "$1" "SELECT COUNT(*) FROM pragma_table_info('$2') WHERE name='$3';"; }

echo "== fresh DB =="
R="$TMP/fresh"; stage "$R"
out=$(bash "$R/scripts/migrate.sh" 2>&1); rc=$?
eq  "fresh apply exits 0" "0" "$rc"
has "fresh apply verifies the read-back" "$out" "Verified:"
has "fresh apply reports success" "$out" "applied successfully"
out=$(bash "$R/scripts/migrate.sh" 2>&1); rc=$?
eq  "re-run is idempotent (exit 0)" "0" "$rc"
hasnt "re-run raises no non-benign patch warning" "$out" "non-benign"

echo "== old-shape DB: columns land before schema.sql's triggers =="
R="$TMP/old"; stage "$R"; DB="$R/.juvant/state.db"
sqlite3 "$DB" "CREATE TABLE security_audit_log (id INTEGER PRIMARY KEY AUTOINCREMENT, auditor TEXT NOT NULL, scope TEXT NOT NULL, audit_type TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);"
# Make schema.sql abort the run part-way (set -e), AFTER it has created its
# triggers: the state an interrupted migration leaves behind.
printf '\nTHIS IS NOT SQL;\n' >> "$R/scripts/schema.sql"
out=$(bash "$R/scripts/migrate.sh" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "interrupted run exits non-zero" || no "interrupted run exited 0"
hasnt "interrupted run does not claim success" "$out" "applied successfully"
eq  "security_audit_log.session_id exists despite the abort" "1" "$(col_exists "$DB" security_audit_log session_id)"
err=$(sqlite3 "$DB" "INSERT INTO security_audit_log (auditor, scope, audit_type) VALUES ('cso','company','unit');" 2>&1); rc=$?
eq  "security_audit_log still accepts writes after the abort (no 'no such column')" "0|" "$rc|$err"
cp "$REPO/scripts/schema.sql" "$R/scripts/schema.sql"
out=$(bash "$R/scripts/migrate.sh" 2>&1); rc=$?
eq  "completing the migration exits 0" "0" "$rc"
has "completed migration verifies" "$out" "Verified:"

echo "== a DB CLI that exits 0 without applying =="
R="$TMP/turso"; stage "$R"; mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/turso"; chmod +x "$TMP/bin/turso"
jq -n '{db:{provider:"turso",url:"libsql://unit.example",auth_token:"T"}}' > "$R/.juvant/config.json"
out=$(PATH="$TMP/bin:$PATH" bash "$R/scripts/migrate.sh" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "silent no-op CLI → migrate exits non-zero" || no "silent no-op CLI → migrate exited 0"
hasnt "silent no-op CLI → no success message" "$out" "applied successfully"
has "silent no-op CLI → verification failure reported" "$out" "schema verification failed"
has "silent no-op CLI → turso auth hint" "$out" "turso auth"

echo "───────────────────────────────────"
echo "  migrate apply-order/verify: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
