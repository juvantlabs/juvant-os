#!/usr/bin/env bash
# hooks/subagent-start.sh
# Claude Code hook: SubagentStart
# Called when a subagent (nested agent) starts within a session.
# Logs activation to the agents table.
#
# stdin: JSON event with subagent type
# Format: {"type":"subagent_start","agent_type":"...","session_id":"..."}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read event from stdin
EVENT_JSON=""
if [ -p /dev/stdin ]; then
  EVENT_JSON=$(cat -)
fi

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/db.sh"
juvant_db_resolve

if [[ -z "$JUVANT_DB_PROVIDER" ]]; then
  exit 0
fi

# Parse agent type from event or fall back to AGENT_ROLE env var
SUBAGENT_ROLE=""
if [[ -n "$EVENT_JSON" ]] && command -v jq &>/dev/null; then
  SUBAGENT_ROLE=$(echo "$EVENT_JSON" | jq -r '.agent_type // ""' 2>/dev/null || echo "")
fi
SUBAGENT_ROLE="${SUBAGENT_ROLE:-${AGENT_ROLE:-unknown}}"

NOW=$(date -u +"%Y-%m-%d %H:%M:%S")
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
ROLE_ESC=$(sql_escape "$SUBAGENT_ROLE")

# Update agent status
juvant_db_exec \
  "UPDATE agents SET status='active', updated_at='$NOW' WHERE role='$ROLE_ESC';" \
  || true

exit 0
