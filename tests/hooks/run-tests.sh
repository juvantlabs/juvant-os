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
trap 'rm -rf "$TMPROOT"' EXIT

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

# FEAT-051: isolate the audit spool to the temp dir so async audit writes
# (pre/post-tool-use) don't pollute the real repo's .juvant/, and so the
# drainer can be exercised end-to-end against the fake DB.
export JUVANT_SPOOL="$TMPROOT/audit-spool.sql"

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

# 1. Universal deny (rm -rf /).
event_json='{"tool_name":"Bash","session_id":"sess-pt-1","tool_input":{"command":"rm -rf /"}}'
out=$(echo "$event_json" | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.permissionDecision')
reason=$(echo "$out" | jq -r '.permissionDecisionReason')
t_assert "universal deny → permissionDecision=deny" "deny" "$decision"
case "$reason" in
  *"universal deny-list match"*) t_assert "universal deny → reason cites universal deny-list" "ok" "ok" ;;
  *) t_assert "universal deny → reason cites universal deny-list" "ok" "got: $reason" ;;
esac

# 2. Allow-list hit (cos → git).
event_json='{"tool_name":"Bash","session_id":"sess-pt-2","tool_input":{"command":"git status"}}'
out=$(echo "$event_json" | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.permissionDecision')
t_assert "allow-list hit (cos:git) → allow" "allow" "$decision"

# 3. Allow-list miss → static deny (handbook ADR 0004 Track 2).
# Use `terraform` against eng-frontend: not in eng-frontend allow-list.
# v0.6.0 ships static deny — automatic tool_authorization_request emit +
# bash_oneshot_grants consumption is FEAT-025, deferred to v1.1.
event_json='{"tool_name":"Bash","session_id":"sess-pt-3","tool_input":{"command":"terraform plan"}}'
out=$(echo "$event_json" | AGENT_ROLE=eng-frontend bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.permissionDecision')
t_assert "allow-list miss → deny" "deny" "$decision"
# FEAT-051: the audit row is spooled (off the gating path), not written
# inline. Assert it lands first in the spool, then reaches the DB after a
# drain — exercising the full spool→drain pipeline.
t_assert "allow-list miss → audit row spooled (status=denied)" "1" \
  "$(grep -c "agent_actions_log.*eng-frontend.*denied" "$JUVANT_SPOOL" 2>/dev/null || echo 0)"
bash "$ROOT_DIR/helpers/drain-audit-spool.sh" >/dev/null 2>&1
audit_count=$(t_db "SELECT COUNT(*) FROM agent_actions_log WHERE agent='eng-frontend' AND status='denied';")
t_assert "allow-list miss → audit log row written (status=denied)" "1" "$audit_count"
t_assert "drain empties the spool" "no" \
  "$([[ -f "$JUVANT_SPOOL" ]] && echo yes || echo no)"

# 4. Unknown role → deny (operator-mode bypass does NOT apply for unknown agent roles).
# v0.7.3+ (F-28): universal_allow contains POSIX shell builtins (cd, echo,
# bash, sh, …). The test must use a binary NOT in universal_allow to exercise
# the allow-list-miss path. `git` is the canonical choice — a real binary
# several roles legitimately need, so a ghost role attempting `git` correctly
# falls through to the per-role allow-list and gets denied.
event_json='{"tool_name":"Bash","session_id":"sess-pt-4","tool_input":{"command":"git status"}}'
out=$(echo "$event_json" | AGENT_ROLE=ghost-role bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.permissionDecision')
t_assert "unknown role → deny" "deny" "$decision"

# 5. Agent-role deny (R3 defense-in-depth, v1.5.1+): cloud-mutating verbs
# blocked for any real agent role even when the binary is in the role's
# allow-list. eng-platform has `az` in @infra_cli but `az ad app create`
# is a cloud write — must be denied via agent_role_deny_patterns.
t_seed_agent "eng-platform" "active"
event_json='{"tool_name":"Bash","session_id":"sess-pt-5","tool_input":{"command":"az ad app create --display-name foo"}}'
out=$(echo "$event_json" | AGENT_ROLE=eng-platform bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.permissionDecision')
reason=$(echo "$out" | jq -r '.permissionDecisionReason')
t_assert "agent role + az write → deny" "deny" "$decision"
case "$reason" in
  *"agent-role deny-list match"*) t_assert "agent role + az write → reason cites R3" "ok" "ok" ;;
  *) t_assert "agent role + az write → reason cites R3" "ok" "got: $reason" ;;
esac

# 5b. Same role, read-only az — must pass (terraform-apply workflow path
# is the only legitimate write path; read-only az is fine for spec authors).
event_json='{"tool_name":"Bash","session_id":"sess-pt-5b","tool_input":{"command":"az account show"}}'
out=$(echo "$event_json" | AGENT_ROLE=eng-platform bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.permissionDecision')
t_assert "agent role + az read → allow" "allow" "$decision"

# 5c. Same role, terraform plan — read-only, must pass.
event_json='{"tool_name":"Bash","session_id":"sess-pt-5c","tool_input":{"command":"terraform plan"}}'
out=$(echo "$event_json" | AGENT_ROLE=eng-platform bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.permissionDecision')
t_assert "agent role + terraform plan → allow" "allow" "$decision"

# 5d. Same role, terraform apply — must be denied via R3.
event_json='{"tool_name":"Bash","session_id":"sess-pt-5d","tool_input":{"command":"terraform apply -auto-approve"}}'
out=$(echo "$event_json" | AGENT_ROLE=eng-platform bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.permissionDecision')
t_assert "agent role + terraform apply → deny" "deny" "$decision"

# ─────────────────────────────────────────────
# single-writer gate (Track 2d: git + gh writes) — FEAT-047 + FEAT-052
# Also exercises BUG-049 role normalization (project-prefixed agent_type).
# NOTE: the gate keys on event.agent_type; the bypass triggers when it is
# absent (main thread), so these cases MUST pass agent_type in the event.
# ─────────────────────────────────────────────
suite "single-writer gate (Track 2d: git + gh)"

_t2d() {  # $1=agent_type  $2=command  -> prints decision
  jq -nc --arg c "$2" --arg a "$1" \
    '{tool_name:"Bash",session_id:"sess-t2d",agent_type:$a,tool_input:{command:$c}}' \
    | bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null | jq -r '.permissionDecision'
}

# project writer (prefixed) — allowed (needs BUG-049 normalization to even
# pass the Track-2 allow-list for bare gh/git, then the Track-2d writer case)
t_assert "eng-lead + git commit → allow"           "allow" "$(_t2d dog-ai-eng-lead 'git commit -m x')"
t_assert "eng-lead + gh pr create → allow"         "allow" "$(_t2d dog-ai-eng-lead 'gh pr create --title x')"
t_assert "eng-lead + gh api POST → allow"          "allow" "$(_t2d dog-ai-eng-lead 'gh api repos/o/r -X POST')"
# project non-writer with gh — reads ok, writes denied
t_assert "product-lead + gh pr view → allow"       "allow" "$(_t2d dog-ai-product-lead 'gh pr view 1')"
t_assert "product-lead + gh pr create → deny"      "deny"  "$(_t2d dog-ai-product-lead 'gh pr create --title x')"
t_assert "product-lead + gh api -f (POST) → deny"  "deny"  "$(_t2d dog-ai-product-lead 'gh api repos/o/r -f a=b')"
t_assert "product-lead + gh api -X GET -f → allow" "allow" "$(_t2d dog-ai-product-lead 'gh api repos/o/r -X GET -f a=b')"
t_assert "product-lead + git push → deny"          "deny"  "$(_t2d dog-ai-product-lead 'git push')"
t_assert "wrapped gh write still gated → deny"     "deny"  "$(_t2d dog-ai-product-lead 'bash helpers/with-timeout.sh 60 gh pr merge 7')"
t_assert "eng-platform + gh api POST → allow"      "allow" "$(_t2d eng-platform 'gh api orgs/x/repos -X POST')"
# main thread (no agent_type) bypasses the gate
_t2d_mt=$(echo '{"tool_name":"Bash","session_id":"s","tool_input":{"command":"gh pr create --title x"}}' \
  | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null | jq -r '.permissionDecision')
t_assert "main thread + gh write → allow (bypass)" "allow" "$_t2d_mt"

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
