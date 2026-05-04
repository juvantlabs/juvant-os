#!/usr/bin/env bash
# hooks/session-start.sh
# Claude Code hook: SessionStart
# Called when a Claude Code session starts.
# Reads JSON event from stdin; writes agent status to Turso.
#
# Claude Code provides hook event data via stdin as JSON.
# Example stdin: {"type":"session_start","session_id":"abc123"}
#
# Usage: registered in .claude/settings.json
# Env vars used: AGENT_ROLE (set by JUVANT_OS.md skill at session boot)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

# Read event JSON from stdin (may be empty on some Claude Code versions)
EVENT_JSON=""
if [ -p /dev/stdin ]; then
  EVENT_JSON=$(cat -)
fi

# Load credentials
if [[ -z "${TURSO_URL:-}" || -z "${TURSO_TOKEN:-}" ]]; then
  if [[ -f "$CONFIG" ]]; then
    TURSO_URL=$(jq -r '.turso_url' "$CONFIG" 2>/dev/null || echo "")
    TURSO_TOKEN=$(jq -r '.turso_token' "$CONFIG" 2>/dev/null || echo "")
  fi
fi

if [[ -z "${TURSO_URL:-}" || -z "${TURSO_TOKEN:-}" ]]; then
  echo "[session-start] WARN: No Turso credentials. Skipping status update." >&2
  exit 0
fi

# Resolve agent role first — we need it for both kill-switch check and status update
ROLE="${AGENT_ROLE:-cos}"

# Per handbook ADR 0004 Track 4 — refuse session start when kill switch is active
KILL_ROW=$(turso db shell "$TURSO_URL" \
  "SELECT active || '|' || COALESCE(reason, '') || '|' || COALESCE(affected_agents, '') FROM agent_kill_switch WHERE id=1;" \
  2>/dev/null | tail -1 || echo "0||")
KILL_ACTIVE=$(echo "$KILL_ROW" | cut -d'|' -f1 | tr -d ' ')
KILL_REASON=$(echo "$KILL_ROW" | cut -d'|' -f2)
KILL_AFFECTED=$(echo "$KILL_ROW" | cut -d'|' -f3)

if [[ "$KILL_ACTIVE" == "1" ]]; then
  if [[ -z "$KILL_AFFECTED" || "$KILL_AFFECTED" == "null" ]] || \
     echo "$KILL_AFFECTED" | jq -r '.[]' 2>/dev/null | grep -qx "$ROLE"; then
    echo "[session-start] KILL SWITCH ACTIVE: $KILL_REASON. Refusing session start for role=$ROLE." >&2
    # Best-effort notify CEO via existing notification hook
    SCRIPT_DIR_FOR_NOTIFY="$SCRIPT_DIR"
    JUVANT_NOTIFY_PRIORITY=critical \
      bash "$SCRIPT_DIR_FOR_NOTIFY/notification.sh" \
      <<< "{\"message\":\"Kill switch denied $ROLE start: $KILL_REASON\"}" \
      2>/dev/null || true
    exit 1
  fi
fi

# Extract session_id from stdin JSON if available
SESSION_ID=""
if [[ -n "$EVENT_JSON" ]] && command -v jq &>/dev/null; then
  SESSION_ID=$(echo "$EVENT_JSON" | jq -r '.session_id // ""' 2>/dev/null || echo "")
fi

NOW=$(date -u +"%Y-%m-%d %H:%M:%S")

# Update agent status to active
if [[ -n "$SESSION_ID" ]]; then
  turso db shell "$TURSO_URL" \
    "UPDATE agents SET status='active', session_id='$SESSION_ID', updated_at='$NOW' WHERE role='$ROLE';" \
    2>/dev/null || echo "[session-start] WARN: Failed to update agent status." >&2
else
  turso db shell "$TURSO_URL" \
    "UPDATE agents SET status='active', updated_at='$NOW' WHERE role='$ROLE';" \
    2>/dev/null || echo "[session-start] WARN: Failed to update agent status." >&2
fi

exit 0
