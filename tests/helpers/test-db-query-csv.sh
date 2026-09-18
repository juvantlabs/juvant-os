#!/usr/bin/env bash
# tests/helpers/test-db-query-csv.sh
#
# BUG-065: hooks/lib/db.sh juvant_db_query_csv on the cloud (turso) provider must
# read via the libsql HTTP /v2/pipeline API (the turso CLI has no CSV mode), must
# produce the SAME header-less CSV as the local sqlite3 -csv path, and must
# SURFACE errors + return non-zero (not silently return empty).

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for dep in sqlite3 jq; do
  command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }
done

PASS=0; FAIL=0
ok(){ echo "    PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1"; printf '        want|%s|\n        got |%s|\n' "$2" "$3"; fi; }
has(){ if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing: $3)"; fi; }

TMP=$(mktemp -d); FAKEBIN=$(mktemp -d)
trap 'rm -rf "$TMP" "$FAKEBIN"' EXIT

DB="$TMP/state.db"
sqlite3 "$DB" "CREATE TABLE t(a TEXT, b INTEGER); INSERT INTO t VALUES ('x',1),('y',2),('p,q',9);"
cp "$REPO/tests/hooks/fake-libsql-curl.sh" "$FAKEBIN/curl"; chmod +x "$FAKEBIN/curl"

# shellcheck disable=SC1091
source "$REPO/hooks/lib/db.sh"
juvant_db_resolve() { :; }   # keep the env we set below

export JUVANT_TEST_DB_FILE="$DB" JUVANT_DB_TIMEOUT=15
SQL="SELECT a,b FROM t ORDER BY b;"

# Ground truth: the local sqlite3 -csv path.
export JUVANT_DB_PROVIDER=local JUVANT_DB_PATH="$DB" JUVANT_DB_URL="" JUVANT_DB_TOKEN=""
LOCAL_CSV=$(juvant_db_query_csv "$SQL"); rc=$?
eq "local path returns rc 0" "0" "$rc"
eq "local sqlite3 -csv output (header-less, quote-when-needed)" $'x,1\ny,2\n"p,q",9' "$LOCAL_CSV"

# Cloud path via the fake libsql HTTP endpoint — must MATCH the local output.
export JUVANT_DB_PROVIDER=turso JUVANT_DB_URL="http://fake.local/db" JUVANT_DB_PATH="" JUVANT_DB_TOKEN=""
TURSO_CSV=$(PATH="$FAKEBIN:$PATH" juvant_db_query_csv "$SQL"); rc=$?
eq "cloud path returns rc 0" "0" "$rc"
eq "cloud CSV == local CSV (provider-consistent, no header, comma-value quoted)" "$LOCAL_CSV" "$TURSO_CSV"

# 25-row ground truth (the live symptom was 0-for-25).
sqlite3 "$DB" "DELETE FROM t; WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<25) INSERT INTO t SELECT 'r'||i, i FROM n;"
CNT=$(PATH="$FAKEBIN:$PATH" juvant_db_query_csv "SELECT a,b FROM t;" | grep -c .)
eq "cloud path returns all 25 rows (not 0)" "25" "$CNT"

# Error surfacing: a bad query must NOT return an empty success — it must fail loud.
err_out=$(PATH="$FAKEBIN:$PATH" juvant_db_query_csv "SELECT nonexistent_col FROM t;" 2>"$TMP/err"); rc=$?
eq "cloud path: SQL error returns non-zero (not silent empty)" "1" "$rc"
eq "cloud path: SQL error yields no stdout rows" "" "$err_out"
has "cloud path: the DB error is surfaced on stderr" "$(cat "$TMP/err")" "DB error"

# Network failure must also surface + fail, not silently empty.
netrc=0
PATH="/usr/bin:/bin" JUVANT_DB_URL="http://127.0.0.1:1/db" juvant_db_query_csv "SELECT 1;" >/dev/null 2>"$TMP/err2" || netrc=$?
eq "cloud path: network failure returns non-zero" "1" "$netrc"

echo "───────────────────────────────────"
echo "  db-query-csv: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
