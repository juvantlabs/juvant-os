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

# Hrana `batch` request (migrate.sh --rebuild-defaults, H23 / BUG-091): run the
# steps on ONE connection — like the libsql server's stream — honouring each
# step's condition (ok / not / and / or) so BEGIN … COMMIT / ROLLBACK is a real
# transaction. FAKE_BATCH_FAIL_AT=<substring>: the first step whose SQL
# contains it fails (fault injection between the copy and the rename).
if [[ "$(printf '%s' "$data" | jq -r '.requests[0].type // ""' 2>/dev/null)" == "batch" ]]; then
  # shellcheck disable=SC2016
  _fake_batch_py='
import json, os, sqlite3, sys
req = json.load(sys.stdin)["requests"][0]["batch"]["steps"]
con = sqlite3.connect(os.environ["JUVANT_TEST_DB_FILE"], isolation_level=None)
fail_at = os.environ.get("FAKE_BATCH_FAIL_AT", "")
results, errors = [], []
def holds(c):
    if c is None: return True
    t = c["type"]
    if t == "ok": return results[c["step"]] is not None
    if t == "error": return errors[c["step"]] is not None
    if t == "not": return not holds(c["cond"])
    if t == "and": return all(holds(x) for x in c["conds"])
    if t == "or": return any(holds(x) for x in c["conds"])
    raise ValueError(t)
for st in req:
    if not holds(st.get("condition")):
        results.append(None); errors.append(None); continue
    sql = st["stmt"]["sql"]
    try:
        if fail_at and fail_at in sql:
            fail_at = ""
            raise sqlite3.OperationalError("injected failure (FAKE_BATCH_FAIL_AT)")
        cur = con.execute(sql)
        rows = cur.fetchall() if cur.description else []
        results.append({"cols": [], "rows": [[{"value": None if v is None else str(v)} for v in r] for r in rows]})
        errors.append(None)
    except sqlite3.Error as e:
        results.append(None); errors.append({"message": str(e)})
print(json.dumps({"results": [{"type": "ok", "response": {"type": "batch",
      "result": {"step_results": results, "step_errors": errors}}}, {"type": "ok", "response": {"type": "close"}}]}))
'
  printf '%s' "$data" | python3 -I -c "$_fake_batch_py"
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
