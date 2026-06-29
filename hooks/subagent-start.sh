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
# Claude Code delivers the event JSON on stdin as a REDIRECT, not necessarily
# a named pipe — the old `[ -p /dev/stdin ]` guard was false for a redirect,
# so the event was never read (session_id lost; the hook silently no-op'd).
# Read whenever stdin is not a terminal, bounded by a 2s read timeout so a
# non-EOF stdin can never hang the hook (no `timeout(1)` dep — absent on macOS).
if [ ! -t 0 ]; then
  IFS= read -r -d "" -t 2 EVENT_JSON 2>/dev/null || true
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
