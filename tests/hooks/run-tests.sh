#!/usr/bin/env bash
# tests/hooks/run-tests.sh
# Bash test runner for the lifecycle hooks.
# Uses local SQLite (no Turso) via tests/hooks/fake-turso.sh on PATH.
#
# Run: bash tests/hooks/run-tests.sh
# Exit code: 0 on all-pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOKS_DIR="$ROOT_DIR/hooks"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

# ─────────────────────────────────────────────
# Setup: temp SQLite + fake-turso on PATH
# ─────────────────────────────────────────────
TMPROOT=$(mktemp -d /tmp/juvant-hook-tests-XXXXXX)
trap "rm -rf $TMPROOT" EXIT

TEST_DB="$TMPROOT/test.db"
sqlite3 "$TEST_DB" < "$ROOT_DIR/scripts/schema.sql"

FAKE_BIN="$TMPROOT/bin"
mkdir -p "$FAKE_BIN"
cp "$SCRIPT_DIR/fake-turso.sh" "$FAKE_BIN/turso"
chmod +x "$FAKE_BIN/turso"

export PATH="$FAKE_BIN:$PATH"
export JUVANT_TEST_DB_FILE="$TEST_DB"
export TURSO_URL="libsql://test.fake"
export TURSO_TOKEN="test-token"

# ─────────────────────────────────────────────
# Test plumbing
# ─────────────────────────────────────────────
PASS=0
FAIL=0
CURRENT_SUITE=""

suite() {
  CURRENT_SUITE="$1"
  echo
  echo "=== $CURRENT_SUITE ==="
}

t_assert() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $name"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $name"
    echo "    expected: [$expected]"
    echo "    actual:   [$actual]"
    FAIL=$((FAIL+1))
  fi
}

t_db() {
  sqlite3 "$TEST_DB" "$1"
}

t_reset_agents() {
  t_db "DELETE FROM agents;"
}

t_seed_agent() {
  t_db "INSERT INTO agents (role, status) VALUES ('$1', '${2:-inactive}');"
}

# ─────────────────────────────────────────────
# session-start.sh
# ─────────────────────────────────────────────
suite "session-start.sh"

t_reset_agents
t_seed_agent "cos" "inactive"
echo '{"session_id":"sess-1"}' | AGENT_ROLE=cos bash "$HOOKS_DIR/session-start.sh"
status=$(t_db "SELECT status FROM agents WHERE role='cos';")
t_assert "sets agents.status=active" "active" "$status"
sid=$(t_db "SELECT session_id FROM agents WHERE role='cos';")
t_assert "writes session_id from event" "sess-1" "$sid"

# Fail-soft when no Turso creds.
unset TURSO_URL TURSO_TOKEN
echo '{}' | AGENT_ROLE=cos bash "$HOOKS_DIR/session-start.sh" 2>/dev/null
exit_code=$?
t_assert "fail-soft on no creds (exit 0)" "0" "$exit_code"
export TURSO_URL="libsql://test.fake" TURSO_TOKEN="test-token"

# ─────────────────────────────────────────────
# session-end.sh
# ─────────────────────────────────────────────
suite "session-end.sh"

t_reset_agents
t_seed_agent "cos" "active"
echo '{"session_id":"sess-end-1"}' | AGENT_ROLE=cos bash "$HOOKS_DIR/session-end.sh" 2>/dev/null
status=$(t_db "SELECT status FROM agents WHERE role='cos';")
t_assert "sets agents.status=inactive" "inactive" "$status"

# Token tracking finalization with transcript.
t_db "DELETE FROM agent_token_usage;"
event_json=$(jq -n --arg tp "$FIXTURES_DIR/transcript-sample.jsonl" \
  --arg sid "sess-finalize-1" \
  '{transcript_path:$tp, session_id:$sid}')
echo "$event_json" | AGENT_ROLE=cos bash "$HOOKS_DIR/session-end.sh" 2>/dev/null
rows=$(t_db "SELECT COUNT(*) FROM agent_token_usage WHERE session_id='sess-finalize-1';")
t_assert "writes agent_token_usage row from transcript" "1" "$rows"
ended=$(t_db "SELECT ended_at FROM agent_token_usage WHERE session_id='sess-finalize-1';")
t_assert "ended_at populated" "true" "$([[ -n "$ended" ]] && echo true || echo false)"

# ─────────────────────────────────────────────
# stop.sh — UPSERT idempotency
# ─────────────────────────────────────────────
suite "stop.sh"

t_db "DELETE FROM agent_token_usage;"
event_json=$(jq -n --arg tp "$FIXTURES_DIR/transcript-sample.jsonl" \
  --arg sid "sess-stop-1" \
  '{transcript_path:$tp, session_id:$sid}')
# First call.
echo "$event_json" | AGENT_ROLE=cos bash "$HOOKS_DIR/stop.sh" 2>/dev/null
# Second call — should UPSERT, not duplicate.
echo "$event_json" | AGENT_ROLE=cos bash "$HOOKS_DIR/stop.sh" 2>/dev/null
rows=$(t_db "SELECT COUNT(*) FROM agent_token_usage WHERE session_id='sess-stop-1';")
t_assert "two stop calls → one row (UPSERT idempotent)" "1" "$rows"

# ─────────────────────────────────────────────
# subagent-stop.sh
# ─────────────────────────────────────────────
suite "subagent-stop.sh"

t_reset_agents
t_seed_agent "cco" "active"
t_db "DELETE FROM agent_token_usage;"
event_json=$(jq -n --arg tp "$FIXTURES_DIR/transcript-sample.jsonl" \
  --arg sid "sess-sub-parent" \
  --arg at "cco" \
  '{transcript_path:$tp, session_id:$sid, agent_type:$at}')
echo "$event_json" | bash "$HOOKS_DIR/subagent-stop.sh" 2>/dev/null
status=$(t_db "SELECT status FROM agents WHERE role='cco';")
t_assert "sets cco.status=inactive" "inactive" "$status"
parent=$(t_db "SELECT parent_session_id FROM agent_token_usage WHERE agent_name='cco' LIMIT 1;")
t_assert "writes parent_session_id link" "sess-sub-parent" "$parent"

# ─────────────────────────────────────────────
# pre-tool-use.sh — Track 2 + Track 3 + escalation
# ─────────────────────────────────────────────
suite "pre-tool-use.sh"

t_reset_agents
t_seed_agent "cco" "active"
t_seed_agent "eng-frontend" "active"
t_db "DELETE FROM agent_actions_log;"
t_db "DELETE FROM messages;"
t_db "DELETE FROM bash_oneshot_grants;"

# 1. Universal deny (rm -rf /).
event_json='{"tool_name":"Bash","session_id":"sess-pt-1","tool_input":{"command":"rm -rf /"}}'
out=$(echo "$event_json" | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.permissionDecision')
reason_prefix=$(echo "$out" | jq -r '.permissionDecisionReason' | cut -d: -f1-2)
t_assert "universal deny → permissionDecision=deny" "deny" "$decision"
t_assert "universal deny → reason prefix deny:universal" "deny:universal" "$reason_prefix"

# 2. Allow-list hit (cos → git).
event_json='{"tool_name":"Bash","session_id":"sess-pt-2","tool_input":{"command":"git status"}}'
out=$(echo "$event_json" | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.permissionDecision')
t_assert "allow-list hit (cos:git) → allow" "allow" "$decision"

# 3. Allow-list miss + no grant → escalate-deny.
# Use `terraform` against eng-frontend: not in eng-frontend allow-list,
# so it must traverse the escalation branch (not the early-allow shortcut).
event_json='{"tool_name":"Bash","session_id":"sess-pt-3","tool_input":{"command":"terraform plan"}}'
out=$(echo "$event_json" | AGENT_ROLE=eng-frontend bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.permissionDecision')
reason_prefix=$(echo "$out" | jq -r '.permissionDecisionReason' | cut -d: -f1-3 | cut -d. -f1)
t_assert "allow-list miss → deny" "deny" "$decision"
t_assert "allow-list miss → deny:allow-list:terraform" "deny:allow-list:terraform" "$reason_prefix"
msg_count=$(t_db "SELECT COUNT(*) FROM messages WHERE type='tool_authorization_request' AND from_agent='eng-frontend';")
t_assert "messages.tool_authorization_request inserted" "1" "$msg_count"
audit_count=$(t_db "SELECT COUNT(*) FROM agent_actions_log WHERE deny_reason LIKE 'deny:allow-list:%' AND escalation_msg_id IS NOT NULL;")
t_assert "agent_actions_log row links to escalation_msg_id" "1" "$audit_count"

# 4. Allow-list miss + matching grant → allow + grant consumed.
# Same trick: `terraform` is not in eng-frontend allow-list, so a
# pre-installed grant is the only way the call passes.
ARGS_JSON='{"command":"terraform apply"}'
ARGS_HASH=$(printf '%s' "$ARGS_JSON" | shasum -a 256 | awk '{print $1}')
t_db "INSERT INTO bash_oneshot_grants
  (agent_role, args_hash, granted_by, expires_at)
  VALUES ('eng-frontend', '$ARGS_HASH', 'ceo',
          DATETIME(CURRENT_TIMESTAMP, '+10 minutes'));"
event_json='{"tool_name":"Bash","session_id":"sess-pt-4","tool_input":{"command":"terraform apply"}}'
out=$(echo "$event_json" | AGENT_ROLE=eng-frontend bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.permissionDecision')
t_assert "matching grant → allow" "allow" "$decision"
consumed=$(t_db "SELECT consumed FROM bash_oneshot_grants WHERE agent_role='eng-frontend' AND args_hash='$ARGS_HASH';")
t_assert "grant marked consumed=1" "1" "$consumed"

# 5. Unknown role → deny:no-role.
event_json='{"tool_name":"Bash","session_id":"sess-pt-5","tool_input":{"command":"echo hi"}}'
out=$(echo "$event_json" | AGENT_ROLE=ghost-role bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.permissionDecision')
reason_prefix=$(echo "$out" | jq -r '.permissionDecisionReason' | cut -d: -f1-2)
t_assert "unknown role → deny" "deny" "$decision"
t_assert "unknown role → reason prefix deny:no-role" "deny:no-role" "$reason_prefix"

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
echo
echo "==================================================="
TOTAL=$((PASS+FAIL))
echo "Total: $TOTAL · Passed: $PASS · Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
