#!/usr/bin/env bash
# tests/helpers/test-db-exec-durability.sh
#
# decisions#276 (PR-A): hooks/lib/db.sh juvant_db_exec cloud writes must use the
# libsql HTTP /v2/pipeline path (not the turso CLI), must surface transport
# failures explicitly, and must spool the statement to audit-spool.sql on
# transport failure so drain-audit-spool.sh can retry it out of band.
# DB-level errors (constraint, syntax) must fail loud and NOT be spooled.
#
# 6 cases:
#   (i)   Cloud HTTP 200  → rc 0, no spool row.
#   (ii)  Cloud HTTP 500  → rc non-zero, stderr, statement spooled.
#   (iii) Cloud network   → rc non-zero, stderr, statement spooled.
#   (iv)  Cloud HTTP 401  → rc non-zero, stderr has "transport failure" + "401",
#                           statement spooled; subsequent 200 call succeeds (rc 0).
#   (v)   Cloud DB error  → rc non-zero, stderr has "DB error", NOT spooled.
#   (vi)  Local sqlite3 SQL error → rc non-zero, sqlite3 error on stderr
#                                   (no 2>/dev/null: BUG-065 symmetry).

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for dep in sqlite3 jq; do
  command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }
done

PASS=0; FAIL=0
ok()  { echo "    PASS: $1"; PASS=$((PASS+1)); }
no()  { echo "    FAIL: $1"; FAIL=$((FAIL+1)); }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1"; printf '        want|%s|\n        got |%s|\n' "$2" "$3"; fi; }
ne()  { if [[ "$2" != "$3" ]]; then ok "$1"; else no "$1 (expected non-equal, both were: $2)"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing: $3)"; fi; }
not() { if ! printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (unexpectedly found: $3)"; fi; }

TMP=$(mktemp -d); FAKEBIN=$(mktemp -d)
trap 'rm -rf "$TMP" "$FAKEBIN"' EXIT

DB="$TMP/state.db"
sqlite3 "$DB" "CREATE TABLE audit_log(id INTEGER PRIMARY KEY, msg TEXT);"

cp "$REPO/tests/hooks/fake-libsql-curl.sh" "$FAKEBIN/curl"; chmod +x "$FAKEBIN/curl"

# shellcheck disable=SC1091
source "$REPO/hooks/lib/db.sh"
# Override juvant_db_resolve so tests drive provider via env.
juvant_db_resolve() { :; }

export JUVANT_TEST_DB_FILE="$DB" JUVANT_DB_TIMEOUT=5

# Helper: count lines in spool that contain the given substring.
# Uses a subshell to absorb grep's exit-1-on-zero-matches without triggering ||.
spool_count() {
  local spool="$1" needle="$2" cnt
  cnt=$(grep -cF "$needle" "$spool" 2>/dev/null) || cnt=0
  printf '%s' "$cnt"
}

# ─────────────────────────────────────────────────────────────────────────────
echo "--- (i) Cloud HTTP 200: rc 0, no spool row written ---"
SPOOL_I="$TMP/spool-i.sql"; touch "$SPOOL_I"
SQL_I="INSERT INTO audit_log(msg) VALUES ('case-i');"
export JUVANT_DB_PROVIDER=turso JUVANT_DB_URL="http://fake.local/db" \
       JUVANT_DB_TOKEN="" JUVANT_SPOOL="$SPOOL_I"
rc_i=0
PATH="$FAKEBIN:$PATH" FAKE_CURL_MODE=200 juvant_db_exec "$SQL_I" 2>"$TMP/err-i" || rc_i=$?
eq  "(i) rc == 0 on HTTP 200 success"    "0" "$rc_i"
eq  "(i) spool is empty after success"   "0" "$(spool_count "$SPOOL_I" "case-i")"
# Verify the row actually landed in the DB.
rows_i=$(sqlite3 "$DB" "SELECT COUNT(*) FROM audit_log WHERE msg='case-i';")
eq  "(i) row written to DB directly"     "1" "$rows_i"

# ─────────────────────────────────────────────────────────────────────────────
echo "--- (ii) Cloud HTTP 500: rc non-zero, stderr, statement spooled ---"
SPOOL_II="$TMP/spool-ii.sql"; touch "$SPOOL_II"
SQL_II="INSERT INTO audit_log(msg) VALUES ('case-ii');"
export JUVANT_SPOOL="$SPOOL_II"
rc_ii=0
PATH="$FAKEBIN:$PATH" FAKE_CURL_MODE=500 juvant_db_exec "$SQL_II" 2>"$TMP/err-ii" || rc_ii=$?
ne  "(ii) rc != 0 on HTTP 500"           "0" "$rc_ii"
has "(ii) stderr has 'transport failure'"  "$(cat "$TMP/err-ii")" "transport failure"
eq  "(ii) statement written to spool"    "1" "$(spool_count "$SPOOL_II" "case-ii")"

# ─────────────────────────────────────────────────────────────────────────────
echo "--- (iii) Cloud network failure: rc non-zero, stderr, statement spooled ---"
SPOOL_III="$TMP/spool-iii.sql"; touch "$SPOOL_III"
SQL_III="INSERT INTO audit_log(msg) VALUES ('case-iii');"
export JUVANT_SPOOL="$SPOOL_III"
rc_iii=0
PATH="$FAKEBIN:$PATH" FAKE_CURL_MODE=network juvant_db_exec "$SQL_III" 2>"$TMP/err-iii" || rc_iii=$?
ne  "(iii) rc != 0 on network failure"   "0" "$rc_iii"
has "(iii) stderr has 'transport failure'" "$(cat "$TMP/err-iii")" "transport failure"
eq  "(iii) statement written to spool"   "1" "$(spool_count "$SPOOL_III" "case-iii")"

# ─────────────────────────────────────────────────────────────────────────────
echo "--- (iv) Cloud HTTP 401: surfaces auth error, spools, subsequent 200 succeeds ---"
SPOOL_IV="$TMP/spool-iv.sql"; touch "$SPOOL_IV"
SQL_IV_A="INSERT INTO audit_log(msg) VALUES ('case-iv-a');"
SQL_IV_B="INSERT INTO audit_log(msg) VALUES ('case-iv-b');"
export JUVANT_SPOOL="$SPOOL_IV"

# First call: 401 (expired credential).
rc_iv_a=0
PATH="$FAKEBIN:$PATH" FAKE_CURL_MODE=401 juvant_db_exec "$SQL_IV_A" 2>"$TMP/err-iv-a" || rc_iv_a=$?
ne  "(iv-a) rc != 0 on HTTP 401"         "0"  "$rc_iv_a"
has "(iv-a) stderr: 'transport failure'" "$(cat "$TMP/err-iv-a")" "transport failure"
has "(iv-a) stderr: HTTP code '401'"     "$(cat "$TMP/err-iv-a")" "401"
eq  "(iv-a) statement written to spool"  "1"  "$(spool_count "$SPOOL_IV" "case-iv-a")"

# Second call: credential restored (mode 200), writes directly.
rc_iv_b=0
PATH="$FAKEBIN:$PATH" FAKE_CURL_MODE=200 juvant_db_exec "$SQL_IV_B" 2>"$TMP/err-iv-b" || rc_iv_b=$?
eq  "(iv-b) rc == 0 after credential restored" "0" "$rc_iv_b"
# The spool still holds the first statement (drain hasn't run); second went direct.
eq  "(iv-b) spool still has one entry (first statement pending drain)" \
    "1" "$(spool_count "$SPOOL_IV" "case-iv-a")"
rows_iv=$(sqlite3 "$DB" "SELECT COUNT(*) FROM audit_log WHERE msg='case-iv-b';")
eq  "(iv-b) second statement landed directly in DB" "1" "$rows_iv"

# ─────────────────────────────────────────────────────────────────────────────
echo "--- (v) Cloud DB error: rc non-zero, 'DB error' on stderr, NOT spooled ---"
SPOOL_V="$TMP/spool-v.sql"; touch "$SPOOL_V"
SQL_V="INSERT INTO nonexistent_table(msg) VALUES ('case-v');"
export JUVANT_SPOOL="$SPOOL_V"
rc_v=0
PATH="$FAKEBIN:$PATH" FAKE_CURL_MODE=db-error juvant_db_exec "$SQL_V" 2>"$TMP/err-v" || rc_v=$?
ne  "(v) rc != 0 on DB error"            "0" "$rc_v"
has "(v) stderr has 'DB error'"          "$(cat "$TMP/err-v")" "DB error"
eq  "(v) statement NOT written to spool" "0" "$(spool_count "$SPOOL_V" "case-v")"

# ─────────────────────────────────────────────────────────────────────────────
echo "--- (vi) Local sqlite3 SQL error: rc non-zero, error on stderr (no 2>/dev/null) ---"
SQL_VI="INSERT INTO nonexistent_table(msg) VALUES ('case-vi');"
export JUVANT_DB_PROVIDER=local JUVANT_DB_PATH="$DB" JUVANT_DB_URL="" JUVANT_DB_TOKEN="" \
       JUVANT_DB_DEBUG=0
rc_vi=0
juvant_db_exec "$SQL_VI" 2>"$TMP/err-vi" || rc_vi=$?
ne  "(vi) rc != 0 on sqlite3 SQL error"  "0" "$rc_vi"
ne  "(vi) sqlite3 error on stderr (non-empty)" "" "$(cat "$TMP/err-vi")"

# ─────────────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────"
echo "  db-exec-durability: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
