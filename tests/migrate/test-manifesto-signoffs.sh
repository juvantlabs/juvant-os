#!/usr/bin/env bash
# tests/migrate/test-manifesto-signoffs.sh
# BUG-079 / ADR 0037 — sign-offs are decisions rows: an old-shape DB accepts the
# categories after migrate.sh, the gate counts distinct approved signers on one
# manifests row, and a sign-off can't be rewritten or carried to a new cycle.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for dep in sqlite3 jq; do
  command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }
done

PASS=0; FAIL=0
ok(){ echo "    PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$2' got '$3')"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
R="$TMP/inst"; DB="$R/.juvant/state.db"
mkdir -p "$R/scripts" "$R/.juvant"
cp "$REPO/scripts/migrate.sh" "$REPO/scripts/schema.sql" "$R/scripts/"
jq -n --arg u "file:$DB" '{db:{provider:"local",url:$u}}' > "$R/.juvant/config.json"

sign() { # <signer> <tier> <manifest id> <status>
  local who="$1" by="NULL" at="NULL"
  if [[ "$4" == "approved" ]]; then by="'$who'"; at="CURRENT_TIMESTAMP"; fi
  sqlite3 "$DB" "INSERT INTO decisions (agent,title,category,rationale,source_ref,status,approved_by,approved_at)
    VALUES ('$who','sign-off','manifesto-tier$2','reason','manifests:$3','$4',$by,$at);"
}
signers() { # <tier> <manifest id>
  sqlite3 "$DB" "SELECT COUNT(DISTINCT agent) FROM decisions_current
    WHERE category='manifesto-tier$1' AND source_ref='manifests:$2'
      AND current_status='approved' AND is_test_artifact=0;"
}

echo "== migrated DB =="
bash "$R/scripts/migrate.sh" >/dev/null 2>&1; eq "exit 0" "0" "$?"
# The older trigger, without the categories: migrate.sh must replace it.
sqlite3 "$DB" "DROP TRIGGER decisions_category_check_ins;
  CREATE TRIGGER decisions_category_check_ins BEFORE INSERT ON decisions
  WHEN NEW.category IS NOT NULL BEGIN
    SELECT RAISE(ABORT,'decisions.category value not in canonical list')
    WHERE NEW.category NOT IN ('manifesto');
  END;"
if sign chro 1 0 approved 2>/dev/null; then no "old trigger rejects the category"; else ok "old trigger rejects the category"; fi
bash "$R/scripts/migrate.sh" >/dev/null 2>&1; eq "re-run exit 0" "0" "$?"

sqlite3 "$DB" "INSERT INTO manifests (id,agent,content,status,tier) VALUES (1,'cfo','m','pending',1);"

echo "== Tier 1 gate =="
if sign chro 1 1 approved 2>/dev/null; then ok "migrated trigger accepts manifesto-tier1"; else no "migrated trigger accepts manifesto-tier1"; fi
eq "one signer is not enough" "1" "$(signers 1 1)"
sign chro 1 1 approved
eq "same signer twice counts once" "1" "$(signers 1 1)"
sign cto 1 1 rejected
eq "a rejection doesn't count" "1" "$(signers 1 1)"
sign cto 1 1 approved
eq "both signers" "2" "$(signers 1 1)"
eq "Tier 2 is counted apart" "0" "$(signers 2 1)"

echo "== sign-off integrity =="
if sqlite3 "$DB" "UPDATE decisions SET rationale='x' WHERE source_ref='manifests:1';" 2>/dev/null; then
  no "rationale is immutable"; else ok "rationale is immutable"; fi
if sqlite3 "$DB" "DELETE FROM decisions WHERE source_ref='manifests:1';" 2>/dev/null; then
  no "a sign-off can't be deleted"; else ok "a sign-off can't be deleted"; fi
if sqlite3 "$DB" "INSERT INTO decisions (agent,title,category,source_ref,status)
    VALUES ('chro','x','manifesto-tier1','manifests:1','approved');" 2>/dev/null; then
  no "approved needs an approver"; else ok "approved needs an approver"; fi

echo "== new review cycle =="
sqlite3 "$DB" "UPDATE manifests SET status='superseded' WHERE id=1;
  INSERT INTO manifests (id,agent,content,status,tier) VALUES (2,'cfo','m2','pending',1);"
eq "earlier sign-offs don't carry over" "0" "$(signers 1 2)"

echo ""
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
