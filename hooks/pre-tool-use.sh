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
CONFIG="$SCRIPT_DIR/../.juvant/config.json"
POLICY="$SCRIPT_DIR/bash-policy.json"

# Read event from stdin
EVENT_JSON=""
if [ ! -t 0 ]; then
  EVENT_JSON=$(cat -)
fi

# Parse event fields (default to safe fallbacks if event shape unexpected)
TOOL_NAME=$(echo "$EVENT_JSON" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
SESSION_ID=$(echo "$EVENT_JSON" | jq -r '.session_id // ""' 2>/dev/null || echo "")
ROLE="${AGENT_ROLE:-unknown}"

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
      FIRST_TOKEN=$(echo "$COMMAND" | awk '{print $1}' | sed 's|.*/||')
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

# ─────────────────────────────────────────────
# Track 3 — append-only audit log
# ─────────────────────────────────────────────
if [[ -z "${TURSO_URL:-}" || -z "${TURSO_TOKEN:-}" ]]; then
  if [[ -f "$CONFIG" ]]; then
    TURSO_URL=$(jq -r '.turso_url // ""' "$CONFIG" 2>/dev/null || echo "")
    TURSO_TOKEN=$(jq -r '.turso_token // ""' "$CONFIG" 2>/dev/null || echo "")
  fi
fi

if [[ -n "${TURSO_URL:-}" ]]; then
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

  turso db shell "$TURSO_URL" "INSERT INTO agent_actions_log
    (session_id, agent, tool_name, args_hash, status, deny_reason)
    VALUES
    ('$SESSION_ESC', '$ROLE_ESC', '$TOOL_ESC', '$ARGS_HASH', '$STATUS', $DENY_SQL);" \
    >/dev/null 2>&1 || echo "[pre-tool-use] WARN: failed to write agent_actions_log row" >&2
fi

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
