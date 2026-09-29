#!/usr/bin/env bash
# tests/hooks/fake-libsql-curl.sh
# Stand-in for `curl` used by tests that exercise the cloud (turso) DB path of
# hooks/lib/db.sh, which reads/writes via the libsql HTTP /v2/pipeline API.
# Drop on PATH in front of the real curl.
#
# Dual role, matching how the real curl is used in a Juvant OS instance:
#   • A request to a `…/v2/pipeline` URL → act as the libsql server: extract the
#     SQL from the JSON body, run it against JUVANT_TEST_DB_FILE, and reply with
#     pipeline-shaped JSON (or a pipeline error object on a bad query).
#   • Any other request (e.g. a Teams/Telegram webhook) → capture the `-d/--data`
#     payload to $CURL_CAPTURE (if set) and exit 0, like a notification stub.
#
# Required env: JUVANT_TEST_DB_FILE (SQLite path).
#
# FAKE_CURL_MODE (decisions#276 — exec durability tests):
#   Unset / "200": execute the SQL for real; output <pipeline-json>\n<http_code>
#                  when called from juvant_db_exec (which passes -w "\n%{http_code}"),
#                  or just <pipeline-json> for the legacy juvant_db_query_csv caller
#                  (backward compat: detect -w flag presence).
#   "500": output a plain body + "\n500" — simulates a 5xx transport failure.
#   "401": output a plain body + "\n401" — simulates expired-credential auth failure.
#   "network": exit 1 with no output — simulates a network-level failure.
#   "db-error": output HTTP 200 with a pipeline error payload — simulates a DB-level
#               error that must NOT be spooled (constraint / missing table).

set -uo pipefail

[[ -n "${JUVANT_TEST_DB_FILE:-}" ]] || { echo "fake-libsql-curl: JUVANT_TEST_DB_FILE not set" >&2; exit 1; }

# Detect whether caller passed -w (juvant_db_exec uses -w "\n%{http_code}").
has_w=0
data=""; url=""; prev=""
for a in "$@"; do
  [[ "$a" == "-w" ]] && has_w=1
  case "$prev" in --data|--data-raw|-d) data="$a" ;; esac
  [[ "$a" == http://* || "$a" == https://* ]] && url="$a"
  prev="$a"
done

MODE="${FAKE_CURL_MODE:-}"

# Network failure: exit immediately with no output.
if [[ "$MODE" == "network" ]]; then
  exit 1
fi

if [[ "$url" != *"/v2/pipeline" ]]; then
  # Non-DB request (notification): capture the payload, succeed.
  [[ -n "$data" ]] && printf '%s' "$data" > "${CURL_CAPTURE:-/dev/null}"
  [[ "$has_w" -eq 1 ]] && printf '\n200'
  exit 0
fi

# HTTP-level failures (non-200 codes requested by test mode).
if [[ "$MODE" == "500" ]]; then
  printf 'Internal Server Error'
  [[ "$has_w" -eq 1 ]] && printf '\n500'
  exit 0
fi
if [[ "$MODE" == "401" ]]; then
  printf '{"message":"Unauthorized"}'
  [[ "$has_w" -eq 1 ]] && printf '\n401'
  exit 0
fi

# DB-level error response (HTTP 200 but pipeline error payload).
if [[ "$MODE" == "db-error" ]]; then
  body='{"results":[{"type":"error","error":{"message":"no such table: nonexistent"}}]}'
  printf '%s' "$body"
  [[ "$has_w" -eq 1 ]] && printf '\n200'
  exit 0
fi

# Default (MODE="" or MODE="200"): execute the SQL for real.
sql=$(printf '%s' "$data" | jq -r '.requests[0].stmt.sql // ""' 2>/dev/null)
if out=$(sqlite3 -json "$JUVANT_TEST_DB_FILE" "$sql" 2>&1); then
  # -json prints nothing for an empty result set — normalise to [].
  [[ -n "$out" ]] || out="[]"
  printf '%s' "$out" | jq -c '
    {results:[{type:"ok",response:{type:"execute",result:{
      rows: [ .[] | [ .[] | {value: (if . == null then null else (. | tostring) end)} ] ]
    }}}]}'
else
  printf '%s' "$out" | jq -cRs '{results:[{type:"error",error:{message:.}}]}'
fi
[[ "$has_w" -eq 1 ]] && printf '\n200'
exit 0
