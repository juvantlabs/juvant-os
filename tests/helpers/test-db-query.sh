#!/usr/bin/env bash
# tests/helpers/test-db-query.sh
#
# BUG-071: hooks/lib/db.sh juvant_db_query on the cloud (turso) provider must
# read via the libsql HTTP /v2/pipeline API and return the SAME shape as the
# local sqlite3 path — no header row, '|'-joined columns, intra-value
# whitespace intact — and must distinguish an empty result set (rc 0, empty
# stdout) from a failed read (rc 1 + stderr).
#
# The pre-fix cloud branch was
#   `turso db shell <url> <sql> | tr -d ' \t' | grep -v '^$'`
# and every assertion below fails against it.

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
sqlite3 "$DB" "CREATE TABLE t(a TEXT, b INTEGER);
               INSERT INTO t VALUES ('Upstream sync to v1.11', 1),('plain', 2),(NULL, 3);"
cp "$REPO/tests/hooks/fake-libsql-curl.sh" "$FAKEBIN/curl"; chmod +x "$FAKEBIN/curl"

# shellcheck disable=SC1091
source "$REPO/hooks/lib/db.sh"
juvant_db_resolve() { :; }   # keep the env we set below

export JUVANT_TEST_DB_FILE="$DB" JUVANT_DB_TIMEOUT=15
SQL="SELECT a,b FROM t ORDER BY b;"

# Ground truth: the local sqlite3 path (default list mode).
export JUVANT_DB_PROVIDER=local JUVANT_DB_PATH="$DB" JUVANT_DB_URL="" JUVANT_DB_TOKEN=""
LOCAL_OUT=$(juvant_db_query "$SQL"); rc=$?
eq "local path returns rc 0" "0" "$rc"
eq "local sqlite3 list output ('|'-joined, no header, NULL empty)" \
   $'Upstream sync to v1.11|1\nplain|2\n|3' "$LOCAL_OUT"

# Cloud path via the fake libsql HTTP endpoint — must MATCH the local output.
export JUVANT_DB_PROVIDER=turso JUVANT_DB_URL="http://fake.local/db" JUVANT_DB_PATH="" JUVANT_DB_TOKEN=""
CLOUD_OUT=$(PATH="$FAKEBIN:$PATH" juvant_db_query "$SQL"); rc=$?
eq "cloud path returns rc 0" "0" "$rc"
eq "cloud output == local output (provider-consistent)" "$LOCAL_OUT" "$CLOUD_OUT"

# (1) No header row: a scalar read is exactly the scalar, comparable with ==.
CNT=$(PATH="$FAKEBIN:$PATH" juvant_db_query "SELECT COUNT(*) FROM t;")
eq "scalar COUNT(*) is the bare value (no header line)" "3" "$CNT"
if [[ "$CNT" -gt 0 ]] 2>/dev/null; then ok "scalar result is usable in an integer test"
else no "scalar result is usable in an integer test"; fi

# (2) An empty result set is EMPTY, not the header — and still rc 0.
EMPTY=$(PATH="$FAKEBIN:$PATH" juvant_db_query "SELECT a FROM t WHERE 1=0;"); rc=$?
eq "empty result set returns rc 0 (not a failure)" "0" "$rc"
eq "empty result set returns empty stdout (not a header row)" "" "$EMPTY"
if [[ -z "$EMPTY" ]]; then ok "[[ -z ]] correctly detects zero rows"
else no "[[ -z ]] correctly detects zero rows"; fi

# (3) Intra-value whitespace survives the round trip.
TITLE=$(PATH="$FAKEBIN:$PATH" juvant_db_query "SELECT a FROM t WHERE b=1;")
eq "text column keeps its internal spaces" "Upstream sync to v1.11" "$TITLE"

# (4) Multi-row reads carry no phantom header row (while-read consumers).
ROWS=$(PATH="$FAKEBIN:$PATH" juvant_db_query "SELECT b FROM t ORDER BY b;" | grep -c .)
eq "multi-row read returns exactly the data rows" "3" "$ROWS"

# A DB-level error must fail loud, not return an empty success.
err_out=$(PATH="$FAKEBIN:$PATH" juvant_db_query "SELECT nonexistent_col FROM t;" 2>"$TMP/err"); rc=$?
eq "cloud path: SQL error returns non-zero (not silent empty)" "1" "$rc"
eq "cloud path: SQL error yields no stdout rows" "" "$err_out"
has "cloud path: the DB error is surfaced on stderr" "$(cat "$TMP/err")" "DB error"

# A network failure must surface + fail, and must NOT look like an empty result.
netrc=0
PATH="/usr/bin:/bin" JUVANT_DB_URL="http://127.0.0.1:1/db" juvant_db_query "SELECT 1;" \
  >/dev/null 2>"$TMP/err2" || netrc=$?
eq "cloud path: network failure returns non-zero" "1" "$netrc"

echo "───────────────────────────────────"
echo "  db-query: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
