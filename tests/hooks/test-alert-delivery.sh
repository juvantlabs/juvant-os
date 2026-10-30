#!/usr/bin/env bash
# tests/hooks/test-alert-delivery.sh
#
# BUG-087 (#190, instance finding #158): every security-alert attempt leaves a
# receipt (channel, time, HTTP status, alert id — never the text, URL or
# token), linked to its audit row via `alert=<id>`; a failed send also writes a
# high 'alert-delivery-failed' row.
# BUG-088 (#191, instance finding #159): alert destinations come from the gated
# secrets file — a chat id edited in .juvant/config.json has no effect, and a
# sensitive-space op fails closed when the gated destination is missing.
#
# Run:  bash tests/hooks/test-alert-delivery.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
for dep in sqlite3 jq; do command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }; done
TMPROOT=$(mktemp -d /tmp/juvant-alert-XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
t_assert() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); echo "  ok   $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL $1 (expected '$2', got '$3')"; fi
}
SF="secrets"".json"

# ── fixture: local-provider instance with a real schema ──
D="$TMPROOT/inst/.juvant"; mkdir -p "$D"
DB="$D/state.db"; CFG="$D/config.json"; SEC="$D/$SF"
python3 -I -c 'import sqlite3,sys; sqlite3.connect(sys.argv[1]).executescript(open(sys.argv[2]).read())' "$DB" "$ROOT_DIR/scripts/schema.sql"
jq -n --arg u "file:$DB" '{db:{provider:"local",url:$u}, notifications:{telegram_chat_id:"ATTACKER-CHAT"}}' > "$CFG"
jq -n '{notifications:{telegram_bot_token:"BOT-TOK-1", telegram_chat_id:"CEO-CHAT", teams_webhooks:{approvals:"https://hook.example/approvals"}}}' > "$SEC"
chmod 600 "$SEC"
RECEIPTS="$D/alert-receipts.jsonl"

# ── curl stub: records argv + the --config stdin, answers $STUB_HTTP ──
CAP="$TMPROOT/cap"; mkdir -p "$TMPROOT/bin" "$CAP"
cat > "$TMPROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
n=$(find "$CAPDIR" -name '*.argv' | wc -l | tr -d ' ')
printf '%s\n' "$@" > "$CAPDIR/$n.argv"
if [[ " $* " == *" --config - "* ]]; then cat > "$CAPDIR/$n.stdin"; fi
code="${STUB_HTTP:-200}"
[[ "$code" == "DOWN" ]] && exit 7
if [[ " $* " == *" -w "* ]]; then printf '%s' "$code"; fi
exit 0
STUB
chmod +x "$TMPROOT/bin/curl"
export PATH="$TMPROOT/bin:$PATH" CAPDIR="$CAP" JUVANT_CONFIG="$CFG" JUVANT_ALERT_SYNC=1
unset TURSO_URL TURSO_TOKEN

# shellcheck disable=SC1091
. "$ROOT_DIR/hooks/lib/db.sh"
# shellcheck disable=SC1091
. "$ROOT_DIR/hooks/lib/alert.sh"

echo "== receipts: 500 → failed, 200 → delivered, linked by alert id =="
ID1=$(juvant_alert_id)
STUB_HTTP=500 juvant_alert_send "[SECURITY ALERT] secret text 1" "$ID1" "unit"
t_assert "500: one receipt per channel (teams + telegram)" "2" "$(jq -s --arg i "$ID1" '[.[] | select(.alert_id == $i)] | length' "$RECEIPTS")"
t_assert "500: both receipts are 'failed' with http 500" "failed:500 failed:500" \
  "$(jq -r --arg i "$ID1" 'select(.alert_id == $i) | "\(.status):\(.http)"' "$RECEIPTS" | tr '\n' ' ' | sed 's/ $//')"
t_assert "500: a high alert-delivery-failed row per channel, naming the alert id" "2" \
  "$(sqlite3 "$DB" "SELECT count(*) FROM security_audit_log WHERE category='alert-delivery-failed' AND severity='high' AND finding LIKE '%alert=${ID1}%';")"
ID2=$(juvant_alert_id)
STUB_HTTP=200 juvant_alert_send "[SECURITY ALERT] secret text 2" "$ID2" "unit"
t_assert "200: both receipts 'delivered'" "delivered delivered" \
  "$(jq -r --arg i "$ID2" 'select(.alert_id == $i) | .status' "$RECEIPTS" | tr '\n' ' ' | sed 's/ $//')"
t_assert "200: no failure row" "0" "$(sqlite3 "$DB" "SELECT count(*) FROM security_audit_log WHERE finding LIKE '%alert=${ID2}%';")"
ID3=$(juvant_alert_id)
STUB_HTTP=DOWN juvant_alert_send "x" "$ID3" "unit"
t_assert "network down (curl rc 7): failed receipt with curl_rc" "failed:7" \
  "$(jq -r --arg i "$ID3" 'select(.alert_id == $i and .channel == "telegram") | "\(.status):\(.curl_rc)"' "$RECEIPTS")"
t_assert "receipts never hold the text, the URL or the token" "no" \
  "$(grep -qE 'secret text|hook\.example|BOT-TOK-1' "$RECEIPTS" && echo yes || echo no)"
t_assert "receipts file mode 600" "600" "$(stat -c '%a' "$RECEIPTS" 2>/dev/null || stat -f '%Lp' "$RECEIPTS")"
t_assert "the bot token never appears in a curl argv" "0" "$(cat "$CAP"/*.argv | grep -c 'BOT-TOK-1' || true)"
t_assert "...it travels on stdin (--config -)" "yes" "$(grep -lq 'BOT-TOK-1' "$CAP"/*.stdin 2>/dev/null && echo yes || echo no)"

echo "== destinations come from the gated file (BUG-088) =="
t_assert "telegram sent to the gated chat id, not the config.json one" "yes|0" \
  "$(grep -qx -- 'chat_id=CEO-CHAT' "$CAP"/*.argv && echo yes || echo no)|$(cat "$CAP"/*.argv | grep -c 'ATTACKER-CHAT' || true)"
t_assert "channel_ready telegram (token + chat in the gated file)" "0" "$(juvant_alert_channel_ready telegram "$CFG"; echo $?)"
jq 'del(.notifications.telegram_chat_id)' "$SEC" > "$SEC.t" && mv "$SEC.t" "$SEC"
t_assert "chat id only in config.json → telegram NOT ready (fail closed)" "1" "$(juvant_alert_channel_ready telegram "$CFG"; echo $?)"
t_assert "chat id is a secret path (migrate-secrets moves it)" "yes" \
  "$(juvant_secret_paths_in "$CFG" | grep -qx '\["notifications","telegram_chat_id"\]' && echo yes || echo no)"

echo "== Track 2e end to end: required channel, receipt ↔ audit row =="
POL="$TMPROOT/policy.json"
jq -n '{version:1, space_access:[{space:"legal-ip", tool_prefix:"mcp__m365-graph__", path_patterns:["legal-ip"], allowlist:["clo"]}], alert_routing:{required:["telegram"]}}' > "$POL"
hook() { jq -n --arg a "$1" '{tool_name:"mcp__m365-graph__get_file_content", tool_input:{path:"/legal-ip/contract.docx"}, session_id:"s-al", agent_type:$a}' \
  | JUVANT_POLICY_TEST=1 JUVANT_POLICY_FILE="$POL" bash "$ROOT_DIR/hooks/pre-tool-use.sh" 2>/dev/null; }
OUT=$(hook clo)
t_assert "gated chat id missing → allowlisted op DENIED (fail closed)" "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$OUT")"
t_assert "...reason says the config.json value does not count" "yes" \
  "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$OUT" | grep -q 'does not count' && echo yes || echo no)"
jq '.notifications.telegram_chat_id = "CEO-CHAT"' "$SEC" > "$SEC.t" && mv "$SEC.t" "$SEC"
: > "$RECEIPTS"
OUT=$(STUB_HTTP=200 hook clo)
t_assert "gated destination present → allowlisted op allowed" "allow" "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$OUT")"
for _i in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$RECEIPTS" ]] && break; sleep 0.5; done
RID=$(jq -r 'select(.source == "pre-tool-use") | .alert_id' "$RECEIPTS" 2>/dev/null | head -1)
t_assert "a receipt was written for the space-access alert" "yes" "$([[ -n "$RID" ]] && echo yes || echo no)"
t_assert "...and the audit row carries the same alert id" "1" \
  "$(sqlite3 "$DB" "SELECT count(*) FROM security_audit_log WHERE finding LIKE 'space-access%alert=${RID}%';")"

echo "== #172: connector deny row ↔ receipt =="
CP="mcp__claude_ai_Microsoft_365__"
jq --arg p "$CP" '. + {connector_tool_allowlist:{tool_prefix:$p, allow:["get_me"], detect_patterns:["legal-ip"]}}' "$POL" > "$POL.t" && mv "$POL.t" "$POL"
: > "$RECEIPTS"
OUT=$(jq -n --arg t "${CP}sharepoint_search" '{tool_name:$t, tool_input:{query:"legal-ip patents"}, session_id:"s-al", agent_type:"cos"}' \
  | STUB_HTTP=200 JUVANT_POLICY_TEST=1 JUVANT_POLICY_FILE="$POL" bash "$ROOT_DIR/hooks/pre-tool-use.sh" 2>/dev/null)
t_assert "connector call naming legal-ip → deny" "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$OUT")"
for _i in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$RECEIPTS" ]] && break; sleep 0.5; done
CID=$(jq -r 'select(.source == "pre-tool-use") | .alert_id' "$RECEIPTS" 2>/dev/null | head -1)
t_assert "a receipt was written for the connector alert" "yes" "$([[ -n "$CID" ]] && echo yes || echo no)"
t_assert "...and the connector audit row carries the same alert id" "1" \
  "$(sqlite3 "$DB" "SELECT count(*) FROM security_audit_log WHERE finding LIKE 'connector call naming a sensitive space%alert=${CID}%';")"

echo "== #172: notification destinations fail closed once the gated file exists =="
jq '.notifications.teams_webhooks.ops = "https://attacker.example/ops" | .projects.p1.notifications.teams_webhooks.approvals = "https://attacker.example/p1"' "$CFG" > "$CFG.t" && mv "$CFG.t" "$CFG"
t_assert "company webhook only in config.json → not used" "" "$(juvant_secret_get '.notifications.teams_webhooks.ops' "$CFG" 2>/dev/null)"
t_assert "...and the operator is told why" "yes" \
  "$(juvant_secret_get '.notifications.teams_webhooks.ops' "$CFG" 2>&1 >/dev/null | grep -q 'IGNORED' && echo yes || echo no)"
t_assert "project webhook only in config.json → not used" "" \
  "$(juvant_secret_get '.projects["p1"].notifications.teams_webhooks["approvals"]' "$CFG" 2>/dev/null)"
t_assert "gated value still wins" "https://hook.example/approvals" "$(juvant_secret_get '.notifications.teams_webhooks.approvals' "$CFG" 2>/dev/null)"
PRE="$TMPROOT/pre/.juvant"; mkdir -p "$PRE"
jq -n '{notifications:{teams_webhooks:{ops:"https://legacy.example/ops"}}}' > "$PRE/config.json"
t_assert "pre-migration (no gated file) → legacy fallback kept" "https://legacy.example/ops" \
  "$(JUVANT_SECRETS_QUIET=1 juvant_secret_get '.notifications.teams_webhooks.ops' "$PRE/config.json")"

echo "== #172: notification.sh keeps the bot token and webhook off curl's argv =="
rm -f "$CAP"/*
jq -n '{message:"waiting"}' | JUVANT_CONFIG="$CFG" bash "$ROOT_DIR/hooks/notification.sh" >/dev/null 2>&1
t_assert "notification.sh sent telegram + teams" "2" "$(find "$CAP" -name '*.argv' | wc -l | tr -d ' ')"
t_assert "no bot token or webhook URL in any argv" "0" "$(cat "$CAP"/*.argv | grep -cE 'BOT-TOK-1|hook\.example' || true)"
t_assert "...both travel on stdin (--config -)" "2" "$(cat "$CAP"/*.stdin 2>/dev/null | grep -cE 'botBOT-TOK-1/sendMessage|hook\.example/approvals' || true)"

echo ""
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
