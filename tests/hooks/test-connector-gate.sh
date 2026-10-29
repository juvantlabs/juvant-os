#!/usr/bin/env bash
# tests/hooks/test-connector-gate.sh
#
# Canary for the connector document-surface gate (decisions#306,
# security_audit_log#156): the claude.ai Microsoft 365 connector is
# vendor-hosted and unversioned — its tool set can change without a version
# bump — so this canary re-runs on every framework change AND on every adopter
# upstream sync (JUVANT_OS.md "Upstream sync" smoke tests).
#
# Part 1 runs against a synthetic policy (test mode). Part 2 re-runs the deny
# cases against the instance's REAL policy on origin/main when it defines a
# connector_tool_allowlist (skipped upstream, where there is none).
#
# Run:  bash tests/hooks/test-connector-gate.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMPROOT=$(mktemp -d /tmp/juvant-connector-gate-XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
t_assert() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); echo "  ok   $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL $1 (expected '$2', got '$3')"; fi
}

TEST_DB="$TMPROOT/test.db"
sqlite3 "$TEST_DB" < "$ROOT_DIR/scripts/schema.sql"
FAKE_BIN="$TMPROOT/bin"; mkdir -p "$FAKE_BIN"
cp "$SCRIPT_DIR/fake-turso.sh" "$FAKE_BIN/turso"; chmod +x "$FAKE_BIN/turso"
cp "$SCRIPT_DIR/fake-libsql-curl.sh" "$FAKE_BIN/curl"; chmod +x "$FAKE_BIN/curl"
export PATH="$FAKE_BIN:$PATH" JUVANT_TEST_DB_FILE="$TEST_DB" TURSO_URL="libsql://test.fake" TURSO_TOKEN="test-token"
export JUVANT_SPOOL="$TMPROOT/audit-spool.sql"
export JUVANT_CONFIG="$TMPROOT/config.json"
echo '{"db":{"provider":"turso","url":"libsql://test.fake"}}' > "$JUVANT_CONFIG"

P="mcp__claude_ai_Microsoft_365__"
POLICY="$TMPROOT/policy.json"
jq -n --arg p "$P" '{version:1,
  space_access:[{space:"legal-ip", tool_prefix:"mcp__m365-graph__", drive_ids:["b!LEGALIP_synthetic"], path_patterns:["legal-ip","/IP/"], allowlist:["clo","cso"]}],
  connector_tool_allowlist:{tool_prefix:$p,
    allow:["outlook_email_search","outlook_calendar_search","get_me","read_resource"],
    read_resource_uri_prefixes:["mail://"],
    detect_patterns:["juvant-legal"]}}' > "$POLICY"

# decide <policy-file> <agent_type|""> <tool-suffix> <args-json>
decide() {
  jq -n --arg a "$2" --arg t "$P$3" --argjson x "$4" '{tool_name:$t, tool_input:$x, session_id:"s-conn"} + (if $a == "" then {} else {agent_type:$a} end)' \
    | JUVANT_POLICY_TEST=1 JUVANT_POLICY_FILE="$1" bash "$ROOT_DIR/hooks/pre-tool-use.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.permissionDecision'
}
high_rows() { sqlite3 "$TEST_DB" "SELECT count(*) FROM security_audit_log WHERE severity='high' AND finding LIKE 'connector call naming a sensitive space%';"; }

echo "== Part 1: synthetic policy =="
for role in "" cos clo cso cfo; do
  label="${role:-main-thread}"
  t_assert "$label: sharepoint_search → deny" "deny" "$(decide "$POLICY" "$role" sharepoint_search '{"query":"contract"}')"
  t_assert "$label: sharepoint_folder_search → deny" "deny" "$(decide "$POLICY" "$role" sharepoint_folder_search '{"name":"IP"}')"
  t_assert "$label: read_resource file:// → deny" "deny" "$(decide "$POLICY" "$role" read_resource '{"uri":"file:///b!x/doc.pdf"}')"
done
t_assert "read_resource drive:// → deny" "deny" "$(decide "$POLICY" cfo read_resource '{"uri":"drive://b!x/root"}')"
t_assert "read_resource site:// → deny" "deny" "$(decide "$POLICY" cfo read_resource '{"uri":"site://juvant/x"}')"
t_assert "read_resource https:// → deny" "deny" "$(decide "$POLICY" cfo read_resource '{"uri":"https://juvant.sharepoint.com/x"}')"
t_assert "read_resource mail:// → allow" "allow" "$(decide "$POLICY" cfo read_resource '{"uri":"mail://messages/AAMk123"}')"
t_assert "outlook_email_search → allow" "allow" "$(decide "$POLICY" cfo outlook_email_search '{"query":"invoice"}')"
t_assert "outlook_calendar_search → allow" "allow" "$(decide "$POLICY" "" outlook_calendar_search '{"query":"board"}')"
t_assert "get_me → allow" "allow" "$(decide "$POLICY" cos get_me '{}')"
t_assert "other existing tool (sharepoint_upload_file) → deny" "deny" "$(decide "$POLICY" cos sharepoint_upload_file '{"path":"/x"}')"
t_assert "outlook_send_mail (not listed) → deny" "deny" "$(decide "$POLICY" cos outlook_send_mail '{"to":"x"}')"
t_assert "unknown NEW vendor tool → deny (deny-by-default)" "deny" "$(decide "$POLICY" cos onedrive_magic_export '{}')"
t_assert "other MCP servers untouched" "allow" \
  "$(jq -n '{tool_name:"mcp__github__list_issues", tool_input:{}, session_id:"s", agent_type:"cos"}' \
      | JUVANT_POLICY_TEST=1 JUVANT_POLICY_FILE="$POLICY" bash "$ROOT_DIR/hooks/pre-tool-use.sh" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')"

echo "== detection on legal-ip-named calls =="
sqlite3 "$TEST_DB" "DROP TRIGGER IF EXISTS security_audit_log_no_delete;" 2>/dev/null
sqlite3 "$TEST_DB" "DELETE FROM security_audit_log;"
decide "$POLICY" cfo sharepoint_search '{"query":"legal-ip patent filings"}' >/dev/null
t_assert "search naming legal-ip → high row (written synchronously)" "1" "$(high_rows)"
decide "$POLICY" cos read_resource '{"uri":"file:///b!LEGALIP_synthetic/x.pdf"}' >/dev/null
t_assert "read_resource on the legal-ip drive → high row" "2" "$(high_rows)"
decide "$POLICY" cos sharepoint_folder_search '{"name":"juvant-legal"}' >/dev/null
t_assert "site name in detect_patterns → high row" "3" "$(high_rows)"
decide "$POLICY" cos sharepoint_search '{"query":"marketing plan"}' >/dev/null
t_assert "denied call naming nothing sensitive → no incident row" "3" "$(high_rows)"

echo "== no connector_tool_allowlist in the policy → gate off =="
jq 'del(.connector_tool_allowlist)' "$POLICY" > "$TMPROOT/p2.json"
t_assert "policy without connector allowlist → sharepoint_search not gated here" "allow" \
  "$(decide "$TMPROOT/p2.json" cos sharepoint_search '{"query":"x"}')"

echo "== Part 2: the instance's real policy (origin/main) =="
REAL=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$ROOT_DIR" cat-file -p refs/remotes/origin/main:security/policy.json 2>/dev/null || echo "")
if [[ -n "$REAL" ]] && printf '%s' "$REAL" | jq -e '.connector_tool_allowlist.tool_prefix' >/dev/null 2>&1; then
  printf '%s' "$REAL" > "$TMPROOT/real.json"
  P=$(jq -r '.connector_tool_allowlist.tool_prefix' "$TMPROOT/real.json")
  for t in sharepoint_search sharepoint_folder_search; do
    t_assert "instance policy: $t → deny (main thread)" "deny" "$(decide "$TMPROOT/real.json" "" "$t" '{"query":"x"}')"
  done
  t_assert "instance policy: read_resource file:// → deny" "deny" "$(decide "$TMPROOT/real.json" cos read_resource '{"uri":"file:///x"}')"
  t_assert "instance policy: unknown new tool → deny" "deny" "$(decide "$TMPROOT/real.json" cos zz_new_tool '{}')"
else
  echo "  skip: no connector_tool_allowlist in security/policy.json on origin/main"
fi

echo ""
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
