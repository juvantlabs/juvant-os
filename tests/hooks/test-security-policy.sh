#!/usr/bin/env bash
# tests/hooks/test-security-policy.sh
#
# decisions#305 (B1a) / ADR 0034 — the sensitive-space policy is read from the
# committed security/policy.json on refs/remotes/origin/main, never from the
# working tree, and fails closed when invalid or deleted.
#
# Builds a bare "remote" repo + an instance clone carrying the real hooks/,
# with a local SQLite DB behind the fake turso/curl shims. No network.
#
# Run:  bash tests/hooks/test-security-policy.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMPROOT=$(mktemp -d /tmp/juvant-security-policy-XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
t_assert() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); echo "  ok   $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL $1 (expected '$2', got '$3')"; fi
}
g() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

# ── fake DB ──
TEST_DB="$TMPROOT/test.db"
sqlite3 "$TEST_DB" < "$ROOT_DIR/scripts/schema.sql"
FAKE_BIN="$TMPROOT/bin"; mkdir -p "$FAKE_BIN"
cp "$SCRIPT_DIR/fake-turso.sh" "$FAKE_BIN/turso"; chmod +x "$FAKE_BIN/turso"
cp "$SCRIPT_DIR/fake-libsql-curl.sh" "$FAKE_BIN/curl"; chmod +x "$FAKE_BIN/curl"
export PATH="$FAKE_BIN:$PATH" JUVANT_TEST_DB_FILE="$TEST_DB" TURSO_URL="libsql://test.fake" TURSO_TOKEN="test-token"
export JUVANT_SPOOL="$TMPROOT/audit-spool.sql"
unset JUVANT_CONFIG JUVANT_POLICY_TEST JUVANT_POLICY_FILE
high_rows() { sqlite3 "$TEST_DB" "SELECT count(*) FROM security_audit_log WHERE severity='high' AND finding LIKE '%$1%';" 2>/dev/null; }

DRIVE="b!LEGALIP_synthetic_0123"
policy_json() { # $1 = allowlist JSON array, $2 = extra jq merge (optional)
  jq -n --arg d "$DRIVE" --argjson al "$1" '{version:1, space_access:[{space:"legal-ip", tool_prefix:"mcp__m365-graph__", drive_ids:[$d], path_patterns:["legal-ip"], allowlist:$al}]}' \
    | jq "${2:-.}"
}

# ── remote + instance ──
REMOTE="$TMPROOT/remote.git"; g init -q --bare "$REMOTE"
SEED="$TMPROOT/seed"; g clone -q "$REMOTE" "$SEED" 2>/dev/null
mkdir -p "$SEED/security"; policy_json '["clo","cso"]' > "$SEED/security/policy.json"
g -C "$SEED" add -A && g -C "$SEED" commit -qm "policy v1" && g -C "$SEED" push -q origin HEAD:main
INST="$TMPROOT/instance"; g clone -q -b main "$REMOTE" "$INST"
cp -R "$ROOT_DIR/hooks" "$INST/hooks"
mkdir -p "$INST/.juvant"
cat > "$INST/.juvant/config.json" <<JSON
{ "db": { "provider": "turso", "url": "libsql://test.fake" },
  "notifications": { "telegram_bot_token": "t0k", "telegram_chat_id": "42" } }
JSON
push_policy() { # $1 = file content ("" = delete), $2 = message
  if [[ -z "$1" ]]; then g -C "$SEED" rm -q security/policy.json
  else mkdir -p "$SEED/security"; printf '%s\n' "$1" > "$SEED/security/policy.json"; g -C "$SEED" add -A; fi
  g -C "$SEED" commit -qm "$2" && g -C "$SEED" push -q origin HEAD:main && g -C "$INST" fetch -q origin
}

# decide <agent> <tool> <args-json> → permissionDecision
decide() {
  jq -n --arg a "$1" --arg t "$2" --argjson x "$3" '{tool_name:$t, tool_input:$x, session_id:"s-pol", agent_type:$a}' \
    | (cd "$INST" && bash "$INST/hooks/pre-tool-use.sh" 2>/dev/null) | jq -r '.hookSpecificOutput.permissionDecision'
}
reason() {
  jq -n --arg a "$1" --arg t "$2" --argjson x "$3" '{tool_name:$t, tool_input:$x, session_id:"s-pol", agent_type:$a}' \
    | (cd "$INST" && bash "$INST/hooks/pre-tool-use.sh" 2>/dev/null) | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'
}
LEGAL=$(jq -cn --arg d "$DRIVE" '{drive_id:$d, path:"/docs"}')
OTHER='{"drive_id":"b!OTHER","path":"/x"}'
GET=mcp__m365-graph__get_file_content

echo "== policy read from origin/main =="
t_assert "cfo on legal-ip → deny (policy allowlist is clo,cso)" "deny" "$(decide cfo $GET "$LEGAL")"
t_assert "clo on legal-ip → allow" "allow" "$(decide clo $GET "$LEGAL")"
t_assert "cfo on another drive → allow" "allow" "$(decide cfo $GET "$OTHER")"

echo "== working tree / local history / shadow refs have no effect =="
policy_json '["clo","cso","cfo"]' > "$INST/security/policy.json"
t_assert "working-tree edit adding cfo → still deny" "deny" "$(decide cfo $GET "$LEGAL")"
g -C "$INST" commit -qam "local widen" >/dev/null
t_assert "local commit (not on origin) → still deny" "deny" "$(decide cfo $GET "$LEGAL")"
g -C "$INST" branch -q origin/main HEAD 2>/dev/null; g -C "$INST" tag -f origin/main HEAD >/dev/null 2>&1
t_assert "local branch + tag named origin/main → still deny (full ref read)" "deny" "$(decide cfo $GET "$LEGAL")"
_orig_blob=$(g -C "$INST" rev-parse refs/remotes/origin/main:security/policy.json)
_wide_blob=$(g -C "$INST" rev-parse HEAD:security/policy.json)
g -C "$INST" replace "$_orig_blob" "$_wide_blob" 2>/dev/null
t_assert "git replace of the policy blob → still deny (GIT_NO_REPLACE_OBJECTS)" "deny" "$(decide cfo $GET "$LEGAL")"
g -C "$INST" replace -d "$_orig_blob" >/dev/null 2>&1
LOOSE_CFG="$TMPROOT/loose-config.json"
jq '. + {security:{space_access:[]}}' "$INST/.juvant/config.json" > "$LOOSE_CFG"
t_assert "JUVANT_CONFIG override → ignored for the policy" "deny" \
  "$(JUVANT_CONFIG="$LOOSE_CFG" decide cfo $GET "$LEGAL")"

echo "== a reviewed change on origin/main does take effect =="
push_policy "$(policy_json '["clo","cso","cfo"]')" "widen via main"
t_assert "after merge + fetch, cfo → allow" "allow" "$(decide cfo $GET "$LEGAL")"

echo "== fail closed =="
sqlite3 "$TEST_DB" "DROP TRIGGER IF EXISTS security_audit_log_no_delete;" 2>/dev/null
sqlite3 "$TEST_DB" "DELETE FROM security_audit_log;"
push_policy '{"version":1,"space_access":[{"allowlist":["clo"]}]}' "broken policy"
t_assert "invalid policy → unrelated mcp__ call denied" "deny" "$(decide cfo mcp__github__list_issues '{}')"
t_assert "invalid policy → reason names FAIL-CLOSED" "yes" \
  "$([[ "$(reason cfo mcp__github__list_issues '{}')" == *"FAIL-CLOSED"* ]] && echo yes || echo no)"
t_assert "invalid policy → high policy-fail-closed row" "yes" "$([[ $(high_rows 'security policy invalid') -ge 1 ]] && echo yes || echo no)"
t_assert "invalid policy → non-MCP tools unaffected (Read)" "allow" "$(decide cfo Read '{"file_path":"README.md"}')"
push_policy "" "delete policy"
t_assert "deleted policy (history exists) → mcp__ denied" "deny" "$(decide clo $GET "$OTHER")"
t_assert "deleted policy → high row" "yes" "$([[ $(high_rows 'security policy deleted') -ge 1 ]] && echo yes || echo no)"

echo "== absent / legacy =="
FRESH="$TMPROOT/fresh"; g init -q "$FRESH"; g -C "$FRESH" commit -q --allow-empty -m init
cp -R "$ROOT_DIR/hooks" "$FRESH/hooks"; mkdir -p "$FRESH/.juvant"
cp "$INST/.juvant/config.json" "$FRESH/.juvant/config.json"
fdecide() { jq -n --arg a "$1" --arg t "$2" --argjson x "$3" '{tool_name:$t, tool_input:$x, session_id:"s-pol", agent_type:$a}' \
  | (cd "$FRESH" && bash "$FRESH/hooks/pre-tool-use.sh" 2>"$TMPROOT/fresh.err") | jq -r '.hookSpecificOutput.permissionDecision'; }
t_assert "no policy, no legacy block → no-op (allow)" "allow" "$(fdecide cfo $GET "$LEGAL")"
jq --arg d "$DRIVE" '. + {security:{space_access:[{space:"legal-ip", tool_prefix:"mcp__m365-graph__", drive_ids:[$d], allowlist:["clo"]}]}}' \
  "$INST/.juvant/config.json" > "$FRESH/.juvant/config.json"
t_assert "legacy config rules honoured (one minor version) → cfo deny" "deny" "$(fdecide cfo $GET "$LEGAL")"
t_assert "legacy → deprecation warning on stderr" "yes" "$(grep -q 'DEPRECATED' "$TMPROOT/fresh.err" && echo yes || echo no)"

echo "== required alert channel without a secret =="
push_policy "$(policy_json '["clo","cso"]' '. + {alert_routing:{required:["teams"]}}')" "require teams"
t_assert "teams required, no webhook → op on legal-ip denied even for clo" "deny" "$(decide clo $GET "$LEGAL")"
t_assert "  …reason cites the missing channel" "yes" "$([[ "$(reason clo $GET "$LEGAL")" == *"alert channel(s) teams"* ]] && echo yes || echo no)"
t_assert "teams required, no webhook → op elsewhere unaffected" "allow" "$(decide clo $GET "$OTHER")"
jq '.notifications.teams_webhooks = {approvals:"https://example.invalid/hook"}' "$INST/.juvant/config.json" > "$INST/.juvant/c2" && mv "$INST/.juvant/c2" "$INST/.juvant/config.json"
# BUG-088: only the gated secrets file counts for a required channel.
t_assert "teams webhook only in config.json → still denied (gated file required)" "deny" "$(decide clo $GET "$LEGAL")"
_SECF="$INST/.juvant/secrets"".json"
jq -n '{notifications:{teams_webhooks:{approvals:"https://example.invalid/hook"}}}' > "$_SECF"
t_assert "teams webhook in the gated secrets file → clo allowed" "allow" "$(decide clo $GET "$LEGAL")"

echo "== test mode =="
TP="$TMPROOT/test-policy.json"; policy_json '["cfo"]' > "$TP"
t_assert "JUVANT_POLICY_TEST=1 + JUVANT_POLICY_FILE → test policy used" "allow" \
  "$(JUVANT_POLICY_TEST=1 JUVANT_POLICY_FILE="$TP" decide cfo $GET "$LEGAL")"

echo "== SessionStart =="
ss() { echo '{"session_id":"s-ss"}' | (cd "$INST" && JUVANT_FRAMEWORK_DEV=0 JUVANT_LAUNCHAGENTS_DIR="$TMPROOT/nola" bash "$INST/hooks/session-start.sh" 2>/dev/null); }
rm -f "$INST/.juvant/policy-blob-seen"
OUT1=$(ss)
t_assert "first session records the policy blob (no change notice)" "no" "$([[ "$OUT1" == *"changed since the last session"* ]] && echo yes || echo no)"
t_assert "  …blob marker written" "yes" "$([[ -s "$INST/.juvant/policy-blob-seen" ]] && echo yes || echo no)"
OUT2=$(ss)
t_assert "unchanged policy → no notice" "no" "$([[ "$OUT2" == *"changed since the last session"* ]] && echo yes || echo no)"
push_policy "$(policy_json '["clo"]' '. + {alert_routing:{required:["teams"]}}')" "narrow allowlist"
sqlite3 "$TEST_DB" "DELETE FROM security_audit_log;"
OUT3=$(ss)
t_assert "policy changed on origin/main → SECURITY NOTICE" "yes" "$([[ "$OUT3" == *"changed since the last session"* ]] && echo yes || echo no)"
t_assert "  …high policy-change row" "yes" "$([[ $(high_rows 'security policy changed') -ge 1 ]] && echo yes || echo no)"
push_policy "" "delete again"
OUT4=$(ss)
t_assert "deleted policy → SessionStart warns fail-closed" "yes" "$([[ "$OUT4" == *"is deleted"* ]] && echo yes || echo no)"

echo "== validator --ref against another repo =="
V="$ROOT_DIR/scripts/validate-security-policy.sh"
push_policy "$(policy_json '["clo","cso"]')" "valid again for the validator"
OUT=$(bash "$V" --repo "$INST" --ref origin/main 2>&1); RC=$?
t_assert "--repo <instance> --ref origin/main → validates the INSTANCE policy" "0|yes" \
  "$RC|$([[ "$OUT" == *"$INST@refs/remotes/origin/main"* ]] && echo yes || echo no)"
OUT=$(cd "$INST" && bash "$V" --ref origin/main 2>&1); RC=$?
t_assert "run from inside the instance (script elsewhere) → instance repo used" "0" "$RC"
OUT=$(cd "$TMPROOT" && bash "$V" --repo "$FRESH" --ref origin/main 2>&1); RC=$?
t_assert "repo without a policy → exit 2, names the repo" "2|yes" "$RC|$([[ "$OUT" == *"$FRESH"* ]] && echo yes || echo no)"
g -C "$INST" branch -q -f origin/main "$(g -C "$INST" rev-parse HEAD)" 2>/dev/null
OUT=$(bash "$V" --repo "$INST" --ref origin/main 2>&1); RC=$?
t_assert "validator reads refs/remotes/origin/main, not a shadowing local branch" "0" "$RC"
push_policy '{"version":1,"space_access":[{"allowlist":["clo"]}]}' "broken for the validator"
OUT=$(bash "$V" --repo "$INST" --ref origin/main 2>&1); RC=$?
t_assert "invalid policy on origin/main → exit 1" "1" "$RC"

echo "== shared_mailboxes in the policy (BUG-083) =="
# shellcheck disable=SC1091
. "$ROOT_DIR/hooks/lib/security-policy.sh"
_v() { juvant_policy_validate "$1" >/dev/null 2>&1 && echo valid || echo invalid; }
t_assert "valid shared_mailboxes block" "valid" \
  "$(_v '{"version":1,"shared_mailboxes":{"main_thread":"ceo_present_read","by_agent":{"cfo":[{"upn":"finance@x.test","scope":"read"}],"cco":[]},"own_mailbox":{"main_thread":"readwrite","agents":"read"}}}')"
for bad in '{"shared_mailboxes":[]}' '{"shared_mailboxes":{}}' '{"shared_mailboxes":{"by_agent":{"cfo":{}}}}' \
           '{"shared_mailboxes":{"by_agent":{"cfo":[{"scope":"read"}]}}}' '{"shared_mailboxes":{"by_agent":{"cfo":[{"upn":"a@b","scope":"admin"}]}}}' \
           '{"shared_mailboxes":{"by_agent":{},"main_thread":"open"}}' '{"shared_mailboxes":{"by_agent":{},"tool_prefix":""}}' \
           '{"shared_mailboxes":{"by_agent":{},"own_mailbox":{"agents":"write"}}}'; do
  t_assert "invalid shared_mailboxes rejected: $bad" "invalid" "$(_v "$bad")"
done

echo "== settings env override is an integrity finding =="
# shellcheck disable=SC1091
. "$ROOT_DIR/hooks/lib/hooks-integrity.sh"
mkdir -p "$INST/.claude"; echo '{"env":{"JUVANT_FRAMEWORK_DEV":"1"}}' > "$INST/.claude/settings.local.json"
HI=$(JUVANT_FRAMEWORK_DEV=0 JUVANT_LAUNCHAGENTS_DIR="$TMPROOT/nola" juvant_hooks_integrity_check "$INST"); RC=$?
t_assert "settings.local.json env JUVANT_FRAMEWORK_DEV → finding" "1|yes" \
  "$RC|$([[ "$HI" == *"settings-env-override: .claude/settings.local.json sets JUVANT_FRAMEWORK_DEV"* ]] && echo yes || echo no)"

echo ""
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
