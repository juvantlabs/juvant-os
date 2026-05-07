#!/usr/bin/env bash
# hooks/subagent-stop.sh
# Claude Code hook: SubagentStop
# Called when a subagent (nested agent) stops within a session.
# Logs deactivation to Turso agents table AND inserts a token-usage row
# for the subagent invocation (FEAT-024).
#
# stdin: JSON event with subagent type, session_id, transcript_path.
# Format: {"agent_type":"...","session_id":"...","transcript_path":"..."}

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
    TURSO_URL=$(jq -r '.turso_url // .db.url // ""' "$CONFIG" 2>/dev/null || echo "")
    TURSO_TOKEN=$(jq -r '.turso_token // .db.auth_token // ""' "$CONFIG" 2>/dev/null || echo "")
  fi
fi

if [[ -z "${TURSO_URL:-}" || -z "${TURSO_TOKEN:-}" ]]; then
  exit 0
fi

export TURSO_URL TURSO_TOKEN

SUBAGENT_ROLE=""
PARENT_SESSION_ID=""
TRANSCRIPT=""
if [[ -n "$EVENT_JSON" ]] && command -v jq &>/dev/null; then
  SUBAGENT_ROLE=$(echo "$EVENT_JSON"     | jq -r '.agent_type // ""' 2>/dev/null || echo "")
  PARENT_SESSION_ID=$(echo "$EVENT_JSON" | jq -r '.session_id // ""' 2>/dev/null || echo "")
  TRANSCRIPT=$(echo "$EVENT_JSON"        | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
fi
SUBAGENT_ROLE="${SUBAGENT_ROLE:-${AGENT_ROLE:-unknown}}"

NOW=$(date -u +"%Y-%m-%d %H:%M:%S")

turso db shell "$TURSO_URL" \
  "UPDATE agents SET status='inactive', updated_at='$NOW' WHERE role='$SUBAGENT_ROLE';" \
  2>/dev/null || true

# FEAT-024 — record subagent invocation token usage.
if [[ -n "$TRANSCRIPT" && -n "$PARENT_SESSION_ID" && -f "$SCRIPT_DIR/lib/track-tokens.sh" ]]; then
  PRINCIPAL_ID="${JUVANT_PRINCIPAL:-}"
  PROJECT_SLUG="${JUVANT_ACTIVE_PROJECT:-}"
  STARTED_AT="${SUBAGENT_STARTED_AT:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
  ENDED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/lib/track-tokens.sh"
  track_subagent_invocation \
    "$TRANSCRIPT" "$PARENT_SESSION_ID" "$SUBAGENT_ROLE" \
    "$STARTED_AT" "$ENDED_AT" \
    "$PRINCIPAL_ID" "$PROJECT_SLUG" \
    || true
fi

exit 0
