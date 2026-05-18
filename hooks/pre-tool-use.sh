#!/usr/bin/env bash
# hooks/pre-tool-use.sh
# Claude Code PreToolUse hook — runs BEFORE every tool call.
#
# Two responsibilities per handbook ADR 0004:
#
#   Track 2 — gate Bash via universal deny-list + per-agent allow-list.
#     Pattern source: hooks/bash-policy.json. On match, output
#     {"permissionDecision":"deny"} which Claude Code honors as a hard
#     block (the tool call never executes).
#
#   Track 3 — write a 'pending' row to agent_actions_log BEFORE the
#     tool runs, so the audit trail exists independent of what the
#     agent later writes via decisions / messages. Cover-up by
#     fabricating decisions rows is detectable by reconciling against
#     this log (helpers/audit-reconcile.sh, weekly).
#
# Stdin: Claude Code event JSON
#   { "session_id": "...", "tool_name": "Bash"|...,
#     "tool_input": { ... } }
# Stdout: decision JSON
#   { "permissionDecision": "allow"|"deny",
#     "permissionDecisionReason": "..." }
#
# Env vars: TURSO_URL, TURSO_TOKEN (fallback to .juvant/config.json)
#           AGENT_ROLE (set by Skill at session boot)
#
# Latency budget: < 100ms typical. Turso INSERT is the bottleneck.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="$SCRIPT_DIR/bash-policy.json"

# Read event from stdin
EVENT_JSON=""
if [ ! -t 0 ]; then
  EVENT_JSON=$(cat -)
fi

# Parse event fields (default to safe fallbacks if event shape unexpected)
TOOL_NAME=$(echo "$EVENT_JSON" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
SESSION_ID=$(echo "$EVENT_JSON" | jq -r '.session_id // ""' 2>/dev/null || echo "")
# Resolve role precedence (F-2 fix, v0.7.3+): when the hook fires inside
# a subagent, Claude Code populates `.agent_type` in the event payload
# (per https://code.claude.com/docs/en/hooks). Use it as the primary
# source of truth — env-derived AGENT_ROLE was never set in subagent
# context (operator mode bypass triggered every CSO tool call as
# `agent='unknown'`, masked Layer 5 §11 fail-safe predicate (b), and
# bypassed the per-agent allow-list in bash-policy.json — closing both
# F-2 and F-10 in one fix).
ROLE=$(echo "$EVENT_JSON" | jq -r '.agent_type // ""' 2>/dev/null || echo "")
ROLE="${ROLE:-${AGENT_ROLE:-}}"
if [[ -z "$ROLE" ]]; then
  # Main thread in a Juvant OS instance = CoS operating as orchestrator.
  # Fallback to 'unknown' only outside a Juvant OS instance.
  if [[ -f "$SCRIPT_DIR/../.juvant/config.json" ]]; then
    ROLE="cos"
  else
    ROLE="unknown"
  fi
fi

# Compute SHA-256 of canonical (sorted-keys) JSON of tool_input
ARGS_JSON=$(echo "$EVENT_JSON" | jq -c -S '.tool_input // {}' 2>/dev/null || echo "{}")
ARGS_HASH=$(printf '%s' "$ARGS_JSON" | shasum -a 256 | awk '{print $1}')

# Default: allow
DECISION="allow"
DENY_REASON=""

# ─────────────────────────────────────────────
# Track 2 — Bash policy enforcement
# ─────────────────────────────────────────────
if [[ "$TOOL_NAME" == "Bash" && -f "$POLICY" ]]; then
  COMMAND=$(echo "$EVENT_JSON" | jq -r '.tool_input.command // ""')

  # Universal deny-list
  while IFS= read -r pattern; do
    [[ -z "$pattern" || "$pattern" == "null" ]] && continue
    if [[ "$COMMAND" =~ $pattern ]]; then
      DECISION="deny"
      DENY_REASON="universal deny-list match: $pattern (handbook ADR 0004 Track 2)"
      break
    fi
  done < <(jq -r '.deny_patterns[]?' "$POLICY" 2>/dev/null)

  # Per-agent allow-list (only if not already denied universally).
  # Operator mode: when AGENT_ROLE is unset/unknown/ceo/operator, the
  # human is driving Claude Code directly (not via the Skill agent
  # dispatcher). Per-role allow-list does not apply — only the
  # universal deny-list. Auditing still applies (Track 3).
  if [[ "$DECISION" == "allow" ]]; then
    if [[ -z "$ROLE" || "$ROLE" == "unknown" || "$ROLE" == "ceo" || "$ROLE" == "operator" ]]; then
      : # operator mode — universal deny already enforced; allow continues
    else
      # F-30 fix (v0.7.4+): when $COMMAND starts with newline(s) (heredoc
      # patterns, multi-line scripts), `awk '{print $1}'` prints $1 of
      # EVERY line, producing a multi-line FIRST_TOKEN that always fails
      # allow-list lookup and emits a malformed deny_reason. Skip leading
      # blank lines via `NF>0`; extract $1 of the first non-empty line and
      # exit. Strip any directory prefix (e.g. /opt/homebrew/bin/foo → foo).
      FIRST_TOKEN=$(echo "$COMMAND" | awk 'NF>0 {print $1; exit}' | sed 's|.*/||')
      # F-28 fix (v0.7.3+): check universal_allow (POSIX shell builtins
      # like cd, pushd, echo — not real binaries, harmless across roles)
      # before falling through to per-role allow-list. Without this,
      # the Skill's `cd /tmp/... && sqlite3 ...` compound commands
      # got denied on `cd` even though sqlite3 was in cso allow-list.
      UNIVERSAL_OK=$(jq -r --arg bin "$FIRST_TOKEN" \
        '(.universal_allow // []) | index($bin) // empty' \
        "$POLICY" 2>/dev/null || echo "")
      if [[ -z "$UNIVERSAL_OK" ]]; then
        ALLOW_OK=$(jq -r --arg role "$ROLE" --arg bin "$FIRST_TOKEN" \
          '(.agent_allow[$role] // []) | index($bin) // empty' \
          "$POLICY" 2>/dev/null || echo "")
        if [[ -z "$ALLOW_OK" ]]; then
          DECISION="deny"
          DENY_REASON="binary '$FIRST_TOKEN' not in agent '$ROLE' allow-list (handbook ADR 0004 Track 2). Escalate to CoS for tool-matrix-change."
        fi
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────
# Track 2b — Scope boundary guard (SYSTEM_INVARIANTS §4b / §4c)
# ─────────────────────────────────────────────
# Bidirectional block: project-scope agent → company DB (§4c hard-fail)
# and company-scope agent → project DB post-bootstrap (§4b hard-fail).
# Conservative whole-word token match on full command string.
# False positives acceptable; false negatives caught by Layer 3 drift audit.
if [[ "$TOOL_NAME" == "Bash" && "$DECISION" == "allow" ]]; then
  _T2B_CMD=$(echo "$EVENT_JSON" | jq -r '.tool_input.command // ""')

  # Detect write tokens (whole-word, case-insensitive)
  if echo "$_T2B_CMD" | grep -qiE \
      '\b(INSERT|UPDATE|DELETE|REPLACE)\b|CREATE[[:space:]]+TABLE|ALTER[[:space:]]+TABLE|DROP[[:space:]]+TABLE'; then

    _CFG="$SCRIPT_DIR/../.juvant/config.json"
    _COMPANY_URL=$(jq -r '.turso_url // ""' "$_CFG" 2>/dev/null || echo "")

    # Classify DB target
    _T2B_COMPANY=false
    _T2B_PROJECT=false
    if [[ -n "$_COMPANY_URL" && "$_T2B_CMD" == *"$_COMPANY_URL"* ]]; then
      _T2B_COMPANY=true
    else
      while IFS= read -r _PU; do
        [[ -z "$_PU" || "$_PU" == "null" ]] && continue
        if [[ "$_T2B_CMD" == *"$_PU"* ]]; then _T2B_PROJECT=true; break; fi
      done < <(jq -r '.projects | to_entries[].value.db_url // empty' "$_CFG" 2>/dev/null)
    fi

    # Classify agent scope
    _COMPANY_ROLES=" cos cfo clo cmo cco cso cto chro cetho cro eng-platform vpe ca "
    _T2B_IS_CO=false
    _T2B_IS_PROJ=false
    if [[ -n "$ROLE" && "$ROLE" != "unknown" && "$ROLE" != "ceo" && "$ROLE" != "operator" ]]; then
      if echo "$_COMPANY_ROLES" | grep -q " $ROLE "; then
        _T2B_IS_CO=true
      else
        _T2B_IS_PROJ=true
      fi
    fi

    # Case a — §4c: project agent → company DB
    if [[ "$_T2B_IS_PROJ" == "true" && "$_T2B_COMPANY" == "true" ]]; then
      DECISION="deny"
      DENY_REASON="SCOPE BOUNDARY VIOLATION §4c (SYSTEM_INVARIANTS): project-scope agent '$ROLE' may not write to company DB. Write to project DB or route spec to company agent via CoS. Refs: FEAT-042 juvantlabs/juvant-os-pm#90"

    # Case b — §4b: company agent → project DB (post-bootstrap, with exceptions)
    elif [[ "$_T2B_IS_CO" == "true" && "$_T2B_PROJECT" == "true" ]]; then
      _BW=$(jq -r '.bootstrap_window // "0"' "$_CFG" 2>/dev/null || echo "0")
      _EXEMPT=false
      if [[ "$_BW" == "1" ]] && \
         [[ "$ROLE" == "chro" || "$ROLE" == "cos" || "$ROLE" == "cso" ]]; then
        _EXEMPT=true
      fi
      if [[ "$_EXEMPT" == "false" ]]; then
        DECISION="deny"
        DENY_REASON="SCOPE BOUNDARY VIOLATION §4b (SYSTEM_INVARIANTS): company-scope agent '$ROLE' may not write to project DB post-bootstrap. Refs: FEAT-042 juvantlabs/juvant-os-pm#90"
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────
# Track 3 — append-only audit log
# ─────────────────────────────────────────────
# Routes via hooks/lib/db.sh so Local SQLite adopters get audit-log
# writes too. Pre-v0.6.3 the hook only used `turso db shell` directly,
# which silently no-ops on Local installations (the turso CLI cannot
# read filesystem paths) — Track 3 of handbook ADR 0004 was effectively
# disabled for every Local adopter. v0.6.3 fix.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/db.sh"

# SQL-escape single quotes via sed (bash 3.2 parameter expansion
# `${V//\'/\'\'}` produces `\'\'` on macOS default bash, which is
# not valid SQL escaping — would silently fail every INSERT carrying
# apostrophes. See FEAT-008 layer-2 dogfood finding (2026-05-08).
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

STATUS="pending"
DENY_SQL="NULL"
if [[ "$DECISION" == "deny" ]]; then
  STATUS="denied"
  DENY_ESCAPED=$(sql_escape "$DENY_REASON")
  DENY_SQL="'$DENY_ESCAPED'"
fi

SESSION_ESC=$(sql_escape "$SESSION_ID")
ROLE_ESC=$(sql_escape "$ROLE")
TOOL_ESC=$(sql_escape "$TOOL_NAME")

juvant_db_exec "INSERT INTO agent_actions_log
  (session_id, agent, tool_name, args_hash, status, deny_reason)
  VALUES
  ('$SESSION_ESC', '$ROLE_ESC', '$TOOL_ESC', '$ARGS_HASH', '$STATUS', $DENY_SQL);" \
  || echo "[pre-tool-use] WARN: failed to write agent_actions_log row" >&2

# ─────────────────────────────────────────────
# Output decision
# ─────────────────────────────────────────────
if [[ "$DECISION" == "deny" ]]; then
  jq -n --arg reason "$DENY_REASON" \
    '{permissionDecision: "deny", permissionDecisionReason: $reason}'
else
  jq -n '{permissionDecision: "allow"}'
fi

exit 0
