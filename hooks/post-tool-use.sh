#!/usr/bin/env bash
# hooks/post-tool-use.sh
# Claude Code PostToolUse hook — runs AFTER successful tool execution.
#
# Per handbook ADR 0004 Track 3: update the most-recent matching
# 'pending' row in agent_actions_log to status='success' with the
# result_hash + ended_at. Match key:
# (session_id, agent, tool_name, args_hash) — same fingerprint
# pre-tool-use.sh wrote.
#
# In the unlikely case of multiple pending rows with the same
# fingerprint (same tool, same args, same session, in flight in
# parallel — Claude Code typically serializes per-session, but
# defensive), updates the MOST RECENT pending one (LIMIT 1
# ORDER BY started_at DESC).
#
# Stdin: { "session_id": "...", "tool_name": "...",
#          "tool_input": { ... }, "tool_response": { ... } }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EVENT_JSON=""
if [ ! -t 0 ]; then
  EVENT_JSON=$(cat -)
fi

TOOL_NAME=$(echo "$EVENT_JSON" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
SESSION_ID=$(echo "$EVENT_JSON" | jq -r '.session_id // ""' 2>/dev/null || echo "")
ROLE="${AGENT_ROLE:-unknown}"

ARGS_JSON=$(echo "$EVENT_JSON" | jq -c -S '.tool_input // {}' 2>/dev/null || echo "{}")
ARGS_HASH=$(printf '%s' "$ARGS_JSON" | shasum -a 256 | awk '{print $1}')

RESULT_JSON=$(echo "$EVENT_JSON" | jq -c -S '.tool_response // {}' 2>/dev/null || echo "{}")
RESULT_HASH=$(printf '%s' "$RESULT_JSON" | shasum -a 256 | awk '{print $1}')

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/db.sh"
juvant_db_resolve

if [[ -z "$JUVANT_DB_PROVIDER" ]]; then
  echo "[post-tool-use] WARN: no db.provider configured; skipping log update" >&2
  exit 0
fi

NOW=$(date -u +"%Y-%m-%d %H:%M:%S")
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
SESSION_ESC=$(sql_escape "$SESSION_ID")
ROLE_ESC=$(sql_escape "$ROLE")
TOOL_ESC=$(sql_escape "$TOOL_NAME")

juvant_db_exec "UPDATE agent_actions_log
  SET status = 'success',
      result_hash = '$RESULT_HASH',
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
  );" \
  || echo "[post-tool-use] WARN: failed to update agent_actions_log" >&2

exit 0
