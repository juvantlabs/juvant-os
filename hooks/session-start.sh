#!/usr/bin/env bash
# hooks/session-start.sh
# Claude Code hook: SessionStart
# Called when a Claude Code session starts.
# Reads JSON event from stdin; writes agent status to Turso (or Local
# SQLite per .juvant/config.json db.provider).
#
# Claude Code provides hook event data via stdin as JSON.
# Example stdin: {"type":"session_start","session_id":"abc123"}
#
# Env vars used: AGENT_ROLE (set by JUVANT_OS.md skill at session boot)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read event JSON from stdin (may be empty on some Claude Code versions)
EVENT_JSON=""
if [ -p /dev/stdin ]; then
  EVENT_JSON=$(cat -)
fi

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/db.sh"
juvant_db_resolve

if [[ -z "$JUVANT_DB_PROVIDER" ]]; then
  echo "[session-start] WARN: No db.provider configured. Skipping status update." >&2
  exit 0
fi

# Resolve agent role — needed for both kill-switch check and status update
ROLE="${AGENT_ROLE:-cos}"

# Per handbook ADR 0004 Track 4 — refuse session start when kill switch is active
KILL_ROW=$(juvant_db_query \
  "SELECT active || '|' || COALESCE(reason, '') || '|' || COALESCE(affected_agents, '') FROM agent_kill_switch WHERE id=1;" \
  | tail -1 || echo "0||")
KILL_ACTIVE=$(echo "$KILL_ROW" | cut -d'|' -f1 | tr -d ' ')
KILL_REASON=$(echo "$KILL_ROW" | cut -d'|' -f2)
KILL_AFFECTED=$(echo "$KILL_ROW" | cut -d'|' -f3)

if [[ "$KILL_ACTIVE" == "1" ]]; then
  if [[ -z "$KILL_AFFECTED" || "$KILL_AFFECTED" == "null" ]] || \
     echo "$KILL_AFFECTED" | jq -r '.[]' 2>/dev/null | grep -qx "$ROLE"; then
    echo "[session-start] KILL SWITCH ACTIVE: $KILL_REASON. Refusing session start for role=$ROLE." >&2
    # Best-effort notify CEO via existing notification hook
    JUVANT_NOTIFY_PRIORITY=critical \
      bash "$SCRIPT_DIR/notification.sh" \
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
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
ROLE_ESC=$(sql_escape "$ROLE")
SESSION_ESC=$(sql_escape "$SESSION_ID")

# Update agent status to active
if [[ -n "$SESSION_ID" ]]; then
  juvant_db_exec \
    "UPDATE agents SET status='active', session_id='$SESSION_ESC', updated_at='$NOW' WHERE role='$ROLE_ESC';" \
    || echo "[session-start] WARN: Failed to update agent status." >&2
else
  juvant_db_exec \
    "UPDATE agents SET status='active', updated_at='$NOW' WHERE role='$ROLE_ESC';" \
    || echo "[session-start] WARN: Failed to update agent status." >&2
fi

exit 0
