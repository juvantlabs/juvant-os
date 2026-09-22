#!/usr/bin/env bash
# tests/hooks/fake-libsql-curl.sh
# Stand-in for `curl` used by tests that exercise the cloud (turso) DB path of
# hooks/lib/db.sh, which reads via the libsql HTTP /v2/pipeline API (BUG-065).
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

set -uo pipefail

[[ -n "${JUVANT_TEST_DB_FILE:-}" ]] || { echo "fake-libsql-curl: JUVANT_TEST_DB_FILE not set" >&2; exit 1; }

data=""; url=""; prev=""
for a in "$@"; do
  case "$prev" in --data|--data-raw|-d) data="$a" ;; esac
  [[ "$a" == http://* || "$a" == https://* ]] && url="$a"
  prev="$a"
done

if [[ "$url" != *"/v2/pipeline" ]]; then
  # Non-DB request (notification): capture the payload, succeed.
  [[ -n "$data" ]] && printf '%s' "$data" > "${CURL_CAPTURE:-/dev/null}"
  exit 0
fi

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
exit 0
