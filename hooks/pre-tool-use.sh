#!/usr/bin/env bash
# hooks/pre-tool-use.sh
# Claude Code PreToolUse hook — runs BEFORE every tool call.
#
# Three responsibilities (handbook ADR 0004 / FEAT-018, FEAT-019, FEAT-025):
#
#   Track 2 — gate Bash via universal deny-list + per-agent allow-list.
#     Universal deny: HARD deny, no escalation possible (irreversible /
#     destructive commands). Returns deny:universal:<pattern>.
#     Allow-list miss: NOT a hard deny. Checks bash_oneshot_grants for
#     a matching unconsumed unexpired CEO grant; if found, allows and
#     marks consumed. Otherwise opens a tool_authorization_request to
#     CoS (notify_ceo=1) and returns deny:allow-list:<binary>. The
#     sub-agent is expected to surface the deny + message id to its
#     parent (SYSTEM_INVARIANTS.md § Sub-agent escalation invariant),
#     not retry, not abandon.
#
#   Track 3 — write a row to agent_actions_log on every call, BEFORE
#     the tool runs. status='pending' for allowed, 'denied' for blocked.
#     Cover-up by fabricating decisions rows is detectable by
#     reconciling against this log (helpers/audit-reconcile.sh, weekly).
#
#   Diagnostic codes (FEAT-025 rec #4) — permissionDecisionReason
#     prefixes: deny:universal:<pat> | deny:allow-list:<bin> |
#     deny:no-role | deny:policy-load-failure. Sub-agents and
#     human readers can disambiguate the cause.
#
# Stdin: Claude Code event JSON
#   { "session_id": "...", "tool_name": "Bash"|...,
#     "tool_input": { ... } }
# Stdout: decision JSON
#   { "permissionDecision": "allow"|"deny",
#     "permissionDecisionReason": "..." }  (omitted on allow)
#
# Env vars: TURSO_URL, TURSO_TOKEN (fallback to .juvant/config.json)
#           AGENT_ROLE (set by Skill at session boot; unset = operator mode)
#
# Latency budget: < 100ms typical. The Turso INSERT for audit log is
# the bottleneck; failing the audit-log write is non-fatal (logged to
# stderr, decision still emitted) so a transient Turso outage does
# not block agent work.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"
POLICY="$SCRIPT_DIR/bash-policy.json"

# SQL single-quote escape that works on bash 3.2 (macOS default).
# The shell parameter expansion ${V//\'/\'\'} is mis-interpreted by
# bash < 4, producing \'\' instead of ''. sed sidesteps the issue.
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# ─────────────────────────────────────────────
# 1. Read event + extract fields
# ─────────────────────────────────────────────
EVENT_JSON=""
if [ ! -t 0 ]; then
  EVENT_JSON=$(cat -)
fi

TOOL_NAME=""
SESSION_ID=""
COMMAND=""
ARGS_JSON="{}"
if [[ -n "$EVENT_JSON" ]] && command -v jq &>/dev/null; then
  TOOL_NAME=$(echo "$EVENT_JSON" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
  SESSION_ID=$(echo "$EVENT_JSON" | jq -r '.session_id // ""' 2>/dev/null || echo "")
  ARGS_JSON=$(echo "$EVENT_JSON" | jq -c -S '.tool_input // {}' 2>/dev/null || echo "{}")
  if [[ "$TOOL_NAME" == "Bash" ]]; then
    COMMAND=$(echo "$EVENT_JSON" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
  fi
fi

ROLE="${AGENT_ROLE:-unknown}"
ARGS_HASH=$(printf '%s' "$ARGS_JSON" | shasum -a 256 | awk '{print $1}')

# ─────────────────────────────────────────────
# 2. Default decision
# ─────────────────────────────────────────────
DECISION="allow"
DENY_REASON=""
ESCALATION_MSG_ID=""

# ─────────────────────────────────────────────
# 3. Load Turso credentials (used by audit log + escalation + grants)
# ─────────────────────────────────────────────
if [[ -z "${TURSO_URL:-}" || -z "${TURSO_TOKEN:-}" ]]; then
  if [[ -f "$CONFIG" ]]; then
    TURSO_URL=$(jq -r '.turso_url // .db.url // ""' "$CONFIG" 2>/dev/null || echo "")
    TURSO_TOKEN=$(jq -r '.turso_token // .db.auth_token // ""' "$CONFIG" 2>/dev/null || echo "")
  fi
fi
export TURSO_URL TURSO_TOKEN

# ─────────────────────────────────────────────
# 4. Track 2 — Bash policy enforcement
# ─────────────────────────────────────────────
if [[ "$TOOL_NAME" == "Bash" ]]; then
  if [[ ! -f "$POLICY" ]]; then
    DECISION="deny"
    DENY_REASON="deny:policy-load-failure: hooks/bash-policy.json missing or unreadable"
  fi

  # 4a. Universal deny-list — HARD deny, no escalation.
  if [[ "$DECISION" == "allow" ]]; then
    while IFS= read -r pattern; do
      [[ -z "$pattern" || "$pattern" == "null" ]] && continue
      if [[ "$COMMAND" =~ $pattern ]]; then
        DECISION="deny"
        DENY_REASON="deny:universal:${pattern}"
        break
      fi
    done < <(jq -r '.deny_patterns[]?' "$POLICY" 2>/dev/null)
  fi

  # 4b. Per-agent allow-list (only if not already universally denied).
  if [[ "$DECISION" == "allow" ]]; then
    # Operator mode: AGENT_ROLE unset/unknown/ceo/operator → human is
    # driving Claude Code directly, not via the Skill agent dispatcher.
    # Per-role allow-list does not apply — universal deny already
    # enforced. Auditing still applies (Track 3).
    if [[ -z "$ROLE" || "$ROLE" == "unknown" || "$ROLE" == "ceo" || "$ROLE" == "operator" ]]; then
      :
    else
      # Resolve first-token (binary name) of the command.
      FIRST_TOKEN=$(echo "$COMMAND" | awk '{print $1}' | sed 's|.*/||')
      ALLOW_HIT=$(jq -r --arg role "$ROLE" --arg bin "$FIRST_TOKEN" \
        '(.agent_allow[$role] // []) | index($bin) // empty' \
        "$POLICY" 2>/dev/null || echo "")

      # Role exists in policy?
      ROLE_KNOWN=$(jq -r --arg role "$ROLE" \
        '.agent_allow | has($role)' \
        "$POLICY" 2>/dev/null || echo "false")

      if [[ "$ROLE_KNOWN" != "true" ]]; then
        # 4b-i. Role not registered in policy → config error. Refuse
        # (operator must add the role via tool-matrix-change).
        DECISION="deny"
        DENY_REASON="deny:no-role: agent role '$ROLE' is not registered in hooks/bash-policy.json. Operational misconfiguration; the role must be added via tool-matrix-change decision."
      elif [[ -n "$ALLOW_HIT" ]]; then
        # 4b-ii. First-token in allow-list → allow.
        :
      else
        # 4b-iii. Allow-list miss → check bash_oneshot_grants.
        GRANT_FOUND=""
        if [[ -n "${TURSO_URL:-}" ]]; then
          GRANT_LOOKUP_ROLE=$(sql_escape "$ROLE")
          GRANT_LOOKUP_HASH=$(sql_escape "$ARGS_HASH")
          GRANT_FOUND=$(turso db shell "$TURSO_URL" --output csv \
            "SELECT id FROM bash_oneshot_grants
             WHERE agent_role='$GRANT_LOOKUP_ROLE'
               AND args_hash='$GRANT_LOOKUP_HASH'
               AND consumed=0
               AND expires_at > CURRENT_TIMESTAMP
             ORDER BY granted_at DESC LIMIT 1;" 2>/dev/null \
            | tail -n +2 | head -1 | tr -d ' ')
        fi

        if [[ -n "$GRANT_FOUND" ]]; then
          # One-shot grant matches → consume and allow.
          turso db shell "$TURSO_URL" \
            "UPDATE bash_oneshot_grants
             SET consumed=1, consumed_at=CURRENT_TIMESTAMP
             WHERE id=$GRANT_FOUND;" 2>/dev/null || true
        else
          # No grant → escalate to CoS.
          DECISION="deny"
          DENY_REASON="deny:allow-list:${FIRST_TOKEN}"
          if [[ -n "${TURSO_URL:-}" ]]; then
            CMD_ESC=$(sql_escape "$COMMAND")
            ROLE_ESC=$(sql_escape "$ROLE")
            HASH_ESC=$(sql_escape "$ARGS_HASH")
            BIN_ESC=$(sql_escape "$FIRST_TOKEN")
            CONTENT_JSON=$(jq -n -c \
              --arg cmd "$COMMAND" \
              --arg bin "$FIRST_TOKEN" \
              --arg agent "$ROLE" \
              --arg hash "$ARGS_HASH" \
              '{command:$cmd, command_first_token:$bin, agent_role:$agent, args_hash:$hash, kind:"tool_authorization_request"}')
            CONTENT_ESC=$(sql_escape "$CONTENT_JSON")
            turso db shell "$TURSO_URL" \
              "INSERT INTO messages
                (from_agent, to_agent, type, content, priority, notify_ceo, ref_id)
               VALUES
                ('$ROLE_ESC', 'cos', 'tool_authorization_request', '$CONTENT_ESC',
                 'high', 1, '$HASH_ESC');" \
              2>/dev/null || true
            ESCALATION_MSG_ID=$(turso db shell "$TURSO_URL" --output csv \
              "SELECT id FROM messages
               WHERE from_agent='$ROLE_ESC' AND to_agent='cos'
                 AND type='tool_authorization_request' AND ref_id='$HASH_ESC'
               ORDER BY created_at DESC LIMIT 1;" 2>/dev/null \
              | tail -n +2 | head -1 | tr -d ' ')
            if [[ -n "$ESCALATION_MSG_ID" ]]; then
              DENY_REASON="deny:allow-list:${FIRST_TOKEN}. Authorization request opened with CoS — message #${ESCALATION_MSG_ID}. Surface this to your parent (CoS) instead of retrying. Expected outcomes: (a) CEO grants one-shot; (b) CEO promotes '${FIRST_TOKEN}' to permanent allow-list via tool-matrix-change; (c) CEO denies with reason."
            else
              DENY_REASON="deny:allow-list:${FIRST_TOKEN}. Authorization request open (message id unavailable — Turso write may have failed). Surface to CoS."
            fi
          fi
        fi
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────
# 5. Track 3 — append-only audit log
# ─────────────────────────────────────────────
if [[ -n "${TURSO_URL:-}" ]]; then
  STATUS="pending"
  DENY_SQL="NULL"
  ESCALATION_SQL="NULL"
  if [[ "$DECISION" == "deny" ]]; then
    STATUS="denied"
    DENY_SQL="'$(sql_escape "$DENY_REASON")'"
  fi
  if [[ -n "$ESCALATION_MSG_ID" ]]; then
    ESCALATION_SQL="$ESCALATION_MSG_ID"
  fi
  SESSION_ESC=$(sql_escape "$SESSION_ID")
  ROLE_ESC=$(sql_escape "$ROLE")
  TOOL_ESC=$(sql_escape "$TOOL_NAME")
  HASH_ESC=$(sql_escape "$ARGS_HASH")

  turso db shell "$TURSO_URL" \
    "INSERT INTO agent_actions_log
       (session_id, agent, tool_name, args_hash, status, deny_reason, escalation_msg_id)
     VALUES
       ('$SESSION_ESC', '$ROLE_ESC', '$TOOL_ESC', '$HASH_ESC', '$STATUS', $DENY_SQL, $ESCALATION_SQL);" \
    >/dev/null 2>&1 \
    || echo "[pre-tool-use] WARN: failed to write agent_actions_log row" >&2
fi

# ─────────────────────────────────────────────
# 6. Output decision
# ─────────────────────────────────────────────
if [[ "$DECISION" == "deny" ]]; then
  jq -n --arg reason "$DENY_REASON" \
    '{permissionDecision: "deny", permissionDecisionReason: $reason}'
else
  jq -n '{permissionDecision: "allow"}'
fi

exit 0
