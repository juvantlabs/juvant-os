#!/usr/bin/env bash
# hooks/post-tool-use-failure.sh
# Claude Code PostToolUseFailure hook — runs when a tool call errors out.
#
# Per handbook ADR 0004 Track 3: update the most-recent matching
# 'pending' row in agent_actions_log to status='failure' with
# ended_at. Same match key pattern as post-tool-use.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

EVENT_JSON=""
if [ ! -t 0 ]; then
  EVENT_JSON=$(cat -)
fi

TOOL_NAME=$(echo "$EVENT_JSON" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
SESSION_ID=$(echo "$EVENT_JSON" | jq -r '.session_id // ""' 2>/dev/null || echo "")
ROLE="${AGENT_ROLE:-unknown}"

ARGS_JSON=$(echo "$EVENT_JSON" | jq -c -S '.tool_input // {}' 2>/dev/null || echo "{}")
ARGS_HASH=$(printf '%s' "$ARGS_JSON" | shasum -a 256 | awk '{print $1}')

if [[ -z "${TURSO_URL:-}" || -z "${TURSO_TOKEN:-}" ]]; then
  if [[ -f "$CONFIG" ]]; then
    TURSO_URL=$(jq -r '.turso_url // ""' "$CONFIG" 2>/dev/null || echo "")
    TURSO_TOKEN=$(jq -r '.turso_token // ""' "$CONFIG" 2>/dev/null || echo "")
  fi
fi

if [[ -z "${TURSO_URL:-}" ]]; then
  echo "[post-tool-use-failure] WARN: no Turso credentials; skipping log update" >&2
  exit 0
fi

NOW=$(date -u +"%Y-%m-%d %H:%M:%S")
SESSION_ESC="${SESSION_ID//\'/\'\'}"
ROLE_ESC="${ROLE//\'/\'\'}"
TOOL_ESC="${TOOL_NAME//\'/\'\'}"

turso db shell "$TURSO_URL" "UPDATE agent_actions_log
  SET status = 'failure',
      ended_at = '$NOW'
  WHERE id = (
    SELECT id FROM agent_actions_log
    WHERE session_id = '$SESSION_ESC'
      AND agent = '$ROLE_ESC'
      AND tool_name = '$TOOL_ESC'
      AND args_hash = '$ARGS_HASH'
      AND status = 'pending'
    ORDER BY started_at DESC
    LIMIT 1
  );" >/dev/null 2>&1 \
  || echo "[post-tool-use-failure] WARN: failed to update agent_actions_log" >&2

exit 0
