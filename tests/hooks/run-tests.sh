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

# Regression (#61): Claude Code delivers the event on stdin as a REDIRECT, not
# a named pipe. The old `[ -p /dev/stdin ]` guard was false for a redirect →
# EVENT_JSON empty → session_id never captured (the hook silently no-op'd).
# Deliver via `< file` and assert it is still captured. (The pipe-based test
# above passed even with the bug, which is why it went unnoticed.)
t_reset_agents
t_seed_agent "cos" "inactive"
printf '%s' '{"session_id":"sess-redir-9"}' > "$TMPROOT/ev-ss.json"
AGENT_ROLE=cos bash "$HOOKS_DIR/session-start.sh" < "$TMPROOT/ev-ss.json"
sid=$(t_db "SELECT session_id FROM agents WHERE role='cos';")
t_assert "captures session_id via redirected (non-pipe) stdin" "sess-redir-9" "$sid"

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

# BUG-051: the three FEAT-035 wrap-up COUNT(*)s must collapse into ONE Turso
# round-trip. session-end runs at the exit-teardown boundary; three serial
# calls can sum past the window Claude Code grants shutdown hooks and get
# cancelled ("Hook cancelled"). We swap in a logging `turso` shim (one line
# per invocation, newlines flattened) and assert exactly one query touches the
# count tables — and that that single query carries all three — while the
# reminder still lands with the correct per-source counts.
t_db "DELETE FROM messages; DELETE FROM inbound_queue; DELETE FROM decisions;"
# Seed observable unsaved work: 2 pending queue, 1 proposed decision, 1 unread CEO.
t_db "INSERT INTO inbound_queue (counterparty_id, agent_owner, content, confidence, status)
      VALUES ('cp1','cos','x','unknown','pending'),('cp2','cos','y','unknown','pending');"
t_db "INSERT INTO decisions (agent, title, status) VALUES ('cos','pending thing','proposed');"
t_db "INSERT INTO messages (from_agent, to_agent, type, content, notify_ceo, status)
      VALUES ('x','cos','escalation','{}',1,'unread');"

WRAP_LOG="$TMPROOT/turso-calls.log"
: > "$WRAP_LOG"
cat > "$FAKE_BIN/turso" <<EOF
#!/usr/bin/env bash
printf '%s ' "\$@" | tr '\n' ' ' >> "$WRAP_LOG"; printf '\n' >> "$WRAP_LOG"
exec bash "$SCRIPT_DIR/fake-turso.sh" "\$@"
EOF
chmod +x "$FAKE_BIN/turso"

wrap_event=$(jq -n --arg sid "sess-wrap-1" '{session_id:$sid}')
echo "$wrap_event" | AGENT_ROLE=cos bash "$HOOKS_DIR/session-end.sh" 2>/dev/null

wrap_roundtrips=$(grep -c 'FROM inbound_queue' "$WRAP_LOG")
t_assert "BUG-051: single wrap-up round-trip (not 3)" "1" "$wrap_roundtrips"
combined=$(grep 'FROM inbound_queue' "$WRAP_LOG" | grep -c 'FROM decisions.*FROM messages')
t_assert "BUG-051: all three counts in one query" "1" "$combined"

reminder=$(t_db "SELECT content FROM messages WHERE type='session-wrap-reminder' ORDER BY id DESC LIMIT 1;")
t_assert "wrap reminder: pending_queue"      "2" "$(echo "$reminder" | jq -r '.pending_queue')"
t_assert "wrap reminder: proposed_decisions" "1" "$(echo "$reminder" | jq -r '.proposed_decisions')"
t_assert "wrap reminder: unread_ceo_messages" "1" "$(echo "$reminder" | jq -r '.unread_ceo_messages')"

# Restore the plain shim so later suites are unaffected by call logging.
cp "$SCRIPT_DIR/fake-turso.sh" "$FAKE_BIN/turso"
chmod +x "$FAKE_BIN/turso"

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
# E (Track 2d hardening) — write-detection bypass regressions.
# git directory-redirect: the write verb no longer sits directly after `git `.
t_assert "non-writer + git -C /tmp/o push → deny"        "deny"  "$(_t2d dog-ai-product-lead 'git -C /tmp/o push')"
t_assert "non-writer + git --work-tree=/tmp/o commit → deny" "deny" "$(_t2d dog-ai-product-lead 'git --work-tree=/tmp/o commit -m x')"
# ultrareview #68: indirect-verb bypasses (shell wrapper, no-arg globals,
# quoted -c value with spaces) must all be caught.
t_assert "non-writer + bash -c 'git push' → deny"        "deny"  "$(_t2d dog-ai-product-lead "bash -c 'git push'")"
t_assert "non-writer + sh -c \"git commit\" → deny"      "deny"  "$(_t2d dog-ai-product-lead 'sh -c "git commit -m x"')"
t_assert "non-writer + git --no-pager push → deny"       "deny"  "$(_t2d dog-ai-product-lead 'git --no-pager push')"
t_assert "non-writer + git --bare push → deny"           "deny"  "$(_t2d dog-ai-product-lead 'git --bare push')"
t_assert "non-writer + git -c 'user.name=My Name' push → deny" "deny" "$(_t2d dog-ai-product-lead 'git -c "user.name=My Name" push')"
# Read controls — common reads must NOT be over-gated.
t_assert "non-writer + git log --oneline → allow"        "allow" "$(_t2d dog-ai-product-lead 'git log --oneline -5')"
t_assert "non-writer + git show <sha> → allow"           "allow" "$(_t2d dog-ai-product-lead 'git show abc123')"
# gh api bodies that aren't field flags, and explicit non-GET methods.
t_assert "non-writer + gh api --input → deny"            "deny"  "$(_t2d dog-ai-product-lead 'gh api repos/o/r/issues --input body.json')"
t_assert "non-writer + gh api --method POST → deny"      "deny"  "$(_t2d dog-ai-product-lead 'gh api repos/o/r/issues --method POST')"
t_assert "non-writer + gh api -X DELETE → deny"          "deny"  "$(_t2d dog-ai-product-lead 'gh api repos/o/r/x -X DELETE')"
# ultrareview #68: lowercase method, compact short-flag, and sibling/comment
# -X GET must not disable the write check.
t_assert "non-writer + gh api --method post (lowercase) → deny" "deny" "$(_t2d dog-ai-product-lead 'gh api repos/o/r/issues --method post')"
t_assert "non-writer + gh api -X delete (lowercase) → deny" "deny" "$(_t2d dog-ai-product-lead 'gh api repos/o/r/x -X delete')"
t_assert "non-writer + gh api -XPOST (compact) → deny"   "deny"  "$(_t2d dog-ai-product-lead 'gh api repos/o/r -XPOST')"
t_assert "non-writer + gh api -XDELETE (compact) → deny" "deny"  "$(_t2d dog-ai-product-lead 'gh api repos/o/r/x -XDELETE')"
t_assert "non-writer + gh api --input && sibling -X GET → deny" "deny" "$(_t2d dog-ai-product-lead 'gh api repos/o/r --input b.json && gh api repos/o/r -X GET')"
t_assert "non-writer + gh api --input # -X GET comment → deny" "deny" "$(_t2d dog-ai-product-lead 'gh api repos/o/r --input b.json # -X GET')"
# Controls — reads must still pass.
t_assert "non-writer + gh api (plain GET) → allow"       "allow" "$(_t2d dog-ai-product-lead 'gh api repos/o/r/issues')"
t_assert "non-writer + gh api --method GET → allow"      "allow" "$(_t2d dog-ai-product-lead 'gh api repos/o/r --method GET')"
t_assert "eng-platform + gh api POST → allow"      "allow" "$(_t2d eng-platform 'gh api orgs/x/repos -X POST')"
# component maintainer (FEAT-053): single-writer on its own repo; BUG-049
# normalization maps <slug>-maintainer → maintainer for the allow-list.
t_assert "maintainer + gh pr create → allow"       "allow" "$(_t2d engram-maintainer 'gh pr create --title x')"
t_assert "maintainer + git commit → allow"         "allow" "$(_t2d engram-maintainer 'git commit -m x')"
t_assert "maintainer + npm test → allow"           "allow" "$(_t2d engram-maintainer 'npm test')"
t_assert "maintainer + gh pr view → allow"         "allow" "$(_t2d engram-maintainer 'gh pr view 1')"
# main thread (no agent_type) bypasses the gate
_t2d_mt=$(echo '{"tool_name":"Bash","session_id":"s","tool_input":{"command":"gh pr create --title x"}}' \
  | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null | jq -r '.permissionDecision')
t_assert "main thread + gh write → allow (bypass)" "allow" "$_t2d_mt"

# ─────────────────────────────────────────────
# repo-scoped single-writer gate (Track 2d / FEAT-054) — owned-set, multi-repo
# Uses a JUVANT_CONFIG fixture so the gate has a registry to scope against.
# ─────────────────────────────────────────────
suite "repo-scoped gate (Track 2d / FEAT-054)"

RS_CFG="$TMPROOT/repo-scope-config.json"
cat > "$RS_CFG" <<'JSON'
{
  "components": [
    { "slug":"lumen-cli", "maintainer":"lumen-cli-maintainer", "repo":"juvantlabs/lumen-cli",
      "working_tree":"/W/lumen-cli", "additional_working_trees":[] }
  ],
  "projects": {
    "hardys": { "working_tree":"/W/hardys-web", "additional_working_trees":["/W/hardys-api"],
      "github_repos":["juvantlabs/hardys-web","juvantlabs/hardys-api","juvantlabs/hardys-infra"] }
  }
}
JSON
_rs() {  # $1=agent_type $2=command -> decision (with the repo-scope fixture)
  JUVANT_CONFIG="$RS_CFG" jq -nc --arg c "$2" --arg a "$1" \
    '{tool_name:"Bash",session_id:"s",agent_type:$a,tool_input:{command:$c}}' \
    | JUVANT_CONFIG="$RS_CFG" bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null | jq -r '.permissionDecision'
}
# maintainer (N=1)
t_assert "maintainer + own-tree git push → allow"   "allow" "$(_rs lumen-cli-maintainer 'cd /W/lumen-cli && git push')"
t_assert "maintainer + own-repo gh → allow"         "allow" "$(_rs lumen-cli-maintainer 'gh pr create --repo juvantlabs/lumen-cli')"
t_assert "maintainer + other-repo gh → deny"        "deny"  "$(_rs lumen-cli-maintainer 'gh pr create --repo juvantlabs/other')"
t_assert "maintainer + other-tree git → deny"       "deny"  "$(_rs lumen-cli-maintainer 'cd /W/other && git push')"
t_assert "maintainer + undeterminable → allow (fail-open)" "allow" "$(_rs lumen-cli-maintainer 'git commit -m x')"
# eng-lead, multi-repo project (hardys: N=many)
t_assert "eng-lead + owned repo (api) → allow"      "allow" "$(_rs hardys-eng-lead 'gh pr create --repo juvantlabs/hardys-api')"
t_assert "eng-lead + owned repo (infra) → allow"    "allow" "$(_rs hardys-eng-lead 'gh api repos/juvantlabs/hardys-infra/pulls -X POST')"
t_assert "eng-lead + non-owned repo → deny"         "deny"  "$(_rs hardys-eng-lead 'gh pr create --repo juvantlabs/hardys-mobile')"
t_assert "eng-lead + other-tree git → deny"         "deny"  "$(_rs hardys-eng-lead 'cd /W/elsewhere && git push')"
# E (Track 2d hardening) — the cross-tree redirect via `git -C` must be seen
# as a working-tree target (the prior gate only parsed a leading `cd`).
t_assert "maintainer + git -C /W/other push → deny (cross-tree via -C)"   "deny"  "$(_rs lumen-cli-maintainer 'git -C /W/other push')"
t_assert "maintainer + git -C /W/lumen-cli push → allow (own tree via -C)" "allow" "$(_rs lumen-cli-maintainer 'git -C /W/lumen-cli push')"
# ultrareview #68: -C must OVERRIDE a leading `cd` (git changes its own CWD),
# and a '..' traversal out of the owned tree must be rejected fail-closed.
t_assert "maintainer + cd owned && git -C /W/other push → deny (-C overrides cd)" "deny" "$(_rs lumen-cli-maintainer 'cd /W/lumen-cli && git -C /W/other push')"
t_assert "maintainer + git -C /W/lumen-cli/../other push → deny (.. traversal)"   "deny" "$(_rs lumen-cli-maintainer 'git -C /W/lumen-cli/../other push')"
t_assert "maintainer + cd /W/lumen-cli/../other && git push → deny (.. via cd)"   "deny" "$(_rs lumen-cli-maintainer 'cd /W/lumen-cli/../other && git push')"

# ─────────────────────────────────────────────
# Track 4 — spec gate distinguishes DB-unreachable from no-spec (E)
# ─────────────────────────────────────────────
suite "spec gate (Track 4: DB-unreachable vs no-spec)"

T4_CMD='turso db shell mydb "ALTER TABLE foo ADD COLUMN bar TEXT"'
_t4() {  # $1=db_file_override  -> full hook JSON for eng-platform + a gated db-schema cmd
  jq -nc --arg c "$T4_CMD" '{tool_name:"Bash",session_id:"s-t4",agent_type:"eng-platform",tool_input:{command:$c}}' \
    | JUVANT_TEST_DB_FILE="$1" bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null
}
t_db "DELETE FROM decisions;"
# Reachable, no approved spec → fail-closed with the missing-spec message.
out=$(_t4 "$TEST_DB")
t_assert "no spec → deny" "deny" "$(echo "$out" | jq -r '.permissionDecision')"
case "$(echo "$out" | jq -r '.permissionDecisionReason')" in
  *"None found"*) t_assert "no spec → 'None found' (author a spec)" "ok" "ok" ;;
  *) t_assert "no spec → 'None found' (author a spec)" "ok" "got other msg" ;;
esac
# DB unreachable (bad db file) → still deny, but DISTINCT message (do not author a spec).
out=$(_t4 "/nonexistent/dir/nope.db")
t_assert "DB unreachable → deny" "deny" "$(echo "$out" | jq -r '.permissionDecision')"
case "$(echo "$out" | jq -r '.permissionDecisionReason')" in
  *"unreachable"*) t_assert "DB unreachable → 'unreachable' (not a missing-spec message)" "ok" "ok" ;;
  *) t_assert "DB unreachable → 'unreachable' (not a missing-spec message)" "ok" "got other msg" ;;
esac
# Approved spec present → allow.
t_db "INSERT INTO decisions (agent,title,category,status,approved_by,approved_at,created_at)
      VALUES ('eng-platform','schema bump','install-spec','approved','ceo',datetime('now'),datetime('now'));"
t_assert "approved spec present → allow" "allow" "$(_t4 "$TEST_DB" | jq -r '.permissionDecision')"
t_db "DELETE FROM decisions;"

# ─────────────────────────────────────────────
# post-tool-use-failure.sh — ROLE derivation parity (audit plumbing)
# ─────────────────────────────────────────────
# pre-tool-use.sh writes the 'pending' row using the .agent_type from the
# event (the only ROLE a subagent carries). The failure hook must derive
# ROLE the same way, or its UPDATE's match key (session_id, agent,
# tool_name, args_hash) never finds the pending row and the failed call
# stays 'pending' forever. Regression: the hook used `${AGENT_ROLE:-unknown}`
# which ignored .agent_type.
suite "post-tool-use-failure.sh (ROLE parity)"

t_db "DELETE FROM agent_actions_log;"
# Seed a pending row exactly as pre-tool-use would for a subagent whose
# event carries agent_type='cfo' (NOT exported as AGENT_ROLE in the env).
ptf_event='{"session_id":"sess-ptf","tool_name":"Bash","tool_input":{"command":"terraform apply"},"agent_type":"cfo"}'
# Match the hook's fingerprint exactly: jq -c -S of .tool_input, hashed with
# NO trailing newline (printf '%s', not a bare `jq | shasum` which appends one).
ptf_args_json=$(echo "$ptf_event" | jq -c -S '.tool_input // {}')
ptf_args_hash=$(printf '%s' "$ptf_args_json" | shasum -a 256 | awk '{print $1}')
t_db "INSERT INTO agent_actions_log (session_id, agent, tool_name, args_hash, status, started_at)
      VALUES ('sess-ptf','cfo','Bash','$ptf_args_hash','pending', datetime('now'));"
# Fire the failure hook with AGENT_ROLE unset — ROLE must come from .agent_type.
echo "$ptf_event" | env -u AGENT_ROLE bash "$HOOKS_DIR/post-tool-use-failure.sh" >/dev/null 2>&1
ptf_status=$(t_db "SELECT status FROM agent_actions_log WHERE session_id='sess-ptf';")
t_assert "failure hook reads .agent_type → pending row finalized to 'failure'" "failure" "$ptf_status"

# ─────────────────────────────────────────────
# pre-compact.sh → post-compact.sh — snapshot round-trip (multi-line)
# ─────────────────────────────────────────────
# A snapshot is multi-line free text with spaces; the old reader truncated
# it (`tail -n 1`) and the turso scalar query strips all whitespace. base64
# storage makes it survive both. Round-trip an awkward snapshot and assert
# byte-for-byte identity.
suite "pre/post-compact.sh (snapshot round-trip)"

t_db "DELETE FROM session_snapshots WHERE agent='snaptest';"
snap=$'line one with spaces\nline two, with a comma\nit'\''s got an apostrophe\n  indented trailing line'
printf '%s' "$snap" | AGENT_ROLE=snaptest bash "$HOOKS_DIR/pre-compact.sh" >/dev/null 2>&1
restored=$(AGENT_ROLE=snaptest bash "$HOOKS_DIR/post-compact.sh" 2>/dev/null)
t_assert "multi-line snapshot survives the store→restore round-trip" "$snap" "$restored"
stored=$(t_db "SELECT snapshot FROM session_snapshots WHERE agent='snaptest' ORDER BY created_at DESC LIMIT 1;")
# base64 is a single line ⇒ zero embedded newlines. A regressed raw multi-line
# store would report >0 here.
t_assert "snapshot is stored single-line (base64 ⇒ zero embedded newlines)" "0" \
  "$(printf '%s' "$stored" | wc -l | tr -d ' ')"

# ─────────────────────────────────────────────
# drain-audit-spool.sh — partial failure does not duplicate (audit plumbing)
# ─────────────────────────────────────────────
# A spool whose middle statement fails must apply the head exactly once and
# re-queue only the unapplied tail. The old whole-batch re-queue re-applied
# the already-committed head on the next run, duplicating audit rows.
suite "drain-audit-spool.sh (no dup on partial failure)"

t_db "DELETE FROM messages WHERE from_agent='drain-t';"
rm -f "$JUVANT_SPOOL"
{
  echo "INSERT INTO messages (from_agent,to_agent,type,content) VALUES ('drain-t','x','task','one');"
  echo "INSERT INTO no_such_table_xyz (a) VALUES (1);"
  echo "INSERT INTO messages (from_agent,to_agent,type,content) VALUES ('drain-t','x','task','three');"
} > "$JUVANT_SPOOL"
bash "$ROOT_DIR/helpers/drain-audit-spool.sh" >/dev/null 2>&1
t_assert "partial drain applies only the head (1 row, not 2)" "1" \
  "$(t_db "SELECT COUNT(*) FROM messages WHERE from_agent='drain-t';")"
t_assert "partial drain re-queues the unapplied tail (2 lines)" "2" \
  "$([[ -f "$JUVANT_SPOOL" ]] && grep -c . "$JUVANT_SPOOL" || echo 0)"
# Repair the failing statement and drain again — the head must NOT re-apply.
echo "INSERT INTO messages (from_agent,to_agent,type,content) VALUES ('drain-t','x','task','three');" > "$JUVANT_SPOOL"
bash "$ROOT_DIR/helpers/drain-audit-spool.sh" >/dev/null 2>&1
t_assert "second drain adds the tail without duplicating the head (2 rows total)" "2" \
  "$(t_db "SELECT COUNT(*) FROM messages WHERE from_agent='drain-t';")"
t_assert "'one' was applied exactly once across both drains" "1" \
  "$(t_db "SELECT COUNT(*) FROM messages WHERE from_agent='drain-t' AND content='one';")"

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
