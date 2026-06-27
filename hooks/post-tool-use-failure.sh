#!/usr/bin/env bash
# hooks/post-tool-use-failure.sh
# Claude Code PostToolUseFailure hook — runs when a tool call errors out.
#
# Per handbook ADR 0004 Track 3: update the most-recent matching
# 'pending' row in agent_actions_log to status='failure' with
# ended_at. Same match key pattern as post-tool-use.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EVENT_JSON=""
if [ ! -t 0 ]; then
  EVENT_JSON=$(cat -)
fi

TOOL_NAME=$(echo "$EVENT_JSON" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
SESSION_ID=$(echo "$EVENT_JSON" | jq -r '.session_id // ""' 2>/dev/null || echo "")
# ROLE must be derived with the SAME precedence as pre-tool-use.sh (which
# wrote the 'pending' row) and post-tool-use.sh (the success path), or the
# match key (session_id, agent, tool_name, args_hash) diverges and this
# UPDATE never finds the pending row — leaving failed tool calls stuck as
# 'pending' forever (false "stuck-pending" reconcile alerts + lost failure
# forensics). The old `${AGENT_ROLE:-unknown}` ignored the event's
# `.agent_type` (the only ROLE signal a subagent carries) and defaulted to
# a different sentinel ('unknown' vs ''/'cos'). Mirror post-tool-use.sh:
ROLE=$(echo "$EVENT_JSON" | jq -r '.agent_type // ""' 2>/dev/null || echo "")
ROLE="${ROLE:-${AGENT_ROLE:-}}"
if [[ -z "$ROLE" ]]; then
  # Main thread in a Juvant OS instance = CoS orchestrator; 'unknown' only
  # outside an instance.
  if [[ -f "$SCRIPT_DIR/../.juvant/config.json" ]]; then
    ROLE="cos"
  else
    ROLE="unknown"
  fi
fi

ARGS_JSON=$(echo "$EVENT_JSON" | jq -c -S '.tool_input // {}' 2>/dev/null || echo "{}")
ARGS_HASH=$(printf '%s' "$ARGS_JSON" | shasum -a 256 | awk '{print $1}')

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/db.sh"
juvant_db_resolve

if [[ -z "$JUVANT_DB_PROVIDER" ]]; then
  echo "[post-tool-use-failure] WARN: no db.provider configured; skipping log update" >&2
  exit 0
fi

NOW=$(date -u +"%Y-%m-%d %H:%M:%S")
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
SESSION_ESC=$(sql_escape "$SESSION_ID")
ROLE_ESC=$(sql_escape "$ROLE")
TOOL_ESC=$(sql_escape "$TOOL_NAME")

juvant_db_exec "UPDATE agent_actions_log
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
  );" \
  || echo "[post-tool-use-failure] WARN: failed to update agent_actions_log" >&2

exit 0
