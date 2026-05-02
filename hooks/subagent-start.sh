#!/usr/bin/env bash
# hooks/subagent-start.sh
# Claude Code hook: SubagentStart
# Called when a subagent (nested agent) starts within a session.
# Logs activation to Turso agents table.
#
# stdin: JSON event with subagent type
# Format: {"type":"subagent_start","agent_type":"...","session_id":"..."}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

# Read event from stdin
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
  exit 0
fi

# Parse agent type from event or fall back to AGENT_ROLE env var
SUBAGENT_ROLE=""
if [[ -n "$EVENT_JSON" ]] && command -v jq &>/dev/null; then
  SUBAGENT_ROLE=$(echo "$EVENT_JSON" | jq -r '.agent_type // ""' 2>/dev/null || echo "")
fi
SUBAGENT_ROLE="${SUBAGENT_ROLE:-${AGENT_ROLE:-unknown}}"

NOW=$(date -u +"%Y-%m-%d %H:%M:%S")

# Update agent status
turso db shell "$TURSO_URL" \
  "UPDATE agents SET status='active', updated_at='$NOW' WHERE role='$SUBAGENT_ROLE';" \
  2>/dev/null || true

exit 0
