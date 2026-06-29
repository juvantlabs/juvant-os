#!/usr/bin/env bash
# tests/migrate/test-v07-to-v08-agents.sh
# Regression test for the v0.7→v0.8 agents-rename block in scripts/migrate.sh.
# Guards two bugs found in the main review:
#   1. statements referenced a nonexistent `agent` column (real col: `role`)
#      → the migration aborted with "no such column: agent" AFTER the
#      irreversible file renames had already run.
#   2. `role` is UNIQUE, so the project `cto`→`pca` rename must precede the
#      company `ca`→`cto` rename, else `ca`→`cto` collides with project `cto`.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
ck(){ if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1));
      else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

# Parse-gate (regression for the main-repo review): the script must be valid
# bash. shellcheck's parser does NOT catch an unbalanced single quote inside a
# $(cat <<SQL ...) heredoc — only `bash -n` / runtime does — and exactly that
# (a `migration's` apostrophe) shipped a migrate.sh that aborted at startup.
if bash -n "$ROOT/scripts/migrate.sh" 2>/dev/null; then
  ck "migrate.sh parses (bash -n)" "ok" "ok"
else
  ck "migrate.sh parses (bash -n)" "ok" "PARSE ERROR"
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
DB="$TMP/v07.db"
sqlite3 "$DB" < "$ROOT/scripts/schema.sql"

# Realistic v0.7-era agents inventory (distinct roles; UNIQUE satisfied).
sqlite3 "$DB" "INSERT INTO agents (role, scope, status) VALUES
  ('ca','company','active'), ('cto','dog-ai','active'),
  ('coo','dog-ai','active'), ('cdo','dog-ai','active'),
  ('cpo','dog-ai','active'), ('vpe','dog-ai','active');"

# Extract the ACTUAL rename SQL from migrate.sh so the test can never drift.
AGENTS_SQL=$(awk "/sql_agents=\\\$\\(cat <<'?SQL/{f=1;next} f&&/^SQL\$/{f=0} f" "$ROOT/scripts/migrate.sh")
[[ -n "$AGENTS_SQL" ]] || { echo "FAIL: could not extract sql_agents from migrate.sh"; exit 1; }

if echo "$AGENTS_SQL" | sqlite3 "$DB" 2>"$TMP/err"; then
  echo "  PASS: agents migration SQL applies without error"; PASS=$((PASS+1))
else
  echo "  FAIL: agents migration SQL errored:"; sed 's/^/    /' "$TMP/err"; FAIL=$((FAIL+1))
fi

ck "company ca → cto"          "cto"          "$(sqlite3 "$DB" "SELECT role FROM agents WHERE scope='company';")"
ck "project cto → pca"         "pca"          "$(sqlite3 "$DB" "SELECT role FROM agents WHERE scope='dog-ai' AND role='pca';")"
ck "coo → eng-lead"            "eng-lead"     "$(sqlite3 "$DB" "SELECT role FROM agents WHERE role='eng-lead';")"
ck "cdo → design-lead"         "design-lead"  "$(sqlite3 "$DB" "SELECT role FROM agents WHERE role='design-lead';")"
ck "cpo → product-lead"        "product-lead" "$(sqlite3 "$DB" "SELECT role FROM agents WHERE role='product-lead';")"
ck "project vpe → offboarded"  "offboarded"   "$(sqlite3 "$DB" "SELECT status FROM agents WHERE role='vpe';")"
ck "no stray v0.7 role names"  "0"            "$(sqlite3 "$DB" "SELECT COUNT(*) FROM agents WHERE role IN ('ca','coo','cdo','cpo');")"

echo "==============================="
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
