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
# F-2 fix (v0.7.3+): prefer `.agent_type` from event payload (populated
# by Claude Code when the hook fires inside a subagent) over env-derived
# AGENT_ROLE. Same precedence pattern as pre-tool-use.sh — keeps the
# pre/post pair's match key (session_id, agent, tool_name, args_hash)
# consistent across the row's lifecycle.
ROLE=$(echo "$EVENT_JSON" | jq -r '.agent_type // ""' 2>/dev/null || echo "")
ROLE="${ROLE:-${AGENT_ROLE:-unknown}}"

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

# Args_hash adds precision to the strict (session, agent, tool_name)
# match when tool_input is identical at pre-tool-use and post-tool-use.
# For tools whose tool_input mutates between the two events (e.g.
# AskUserQuestion: pre carries the question, post carries the
# question + the user's selected option; args_hash differs
# deterministically), the strict match would find 0 rows and the
# pending row would leak forever — observed in the Golf Corp testco
# run on 2026-05-09 as F-22 (2 orphan AskUserQuestion rows after
# bootstrap completion). Fall back to the (session, agent, tool_name)
# match for those tools — sequential-per-session ordering with
# `LIMIT 1` selects the right pending row.
WHERE_CLAUSE="WHERE session_id = '$SESSION_ESC'
      AND agent = '$ROLE_ESC'
      AND tool_name = '$TOOL_ESC'
      AND status = 'pending'"

case "$TOOL_NAME" in
  AskUserQuestion) ;;  # tool_input mutates pre→post; skip args_hash
  *) WHERE_CLAUSE="$WHERE_CLAUSE
      AND args_hash = '$ARGS_HASH'" ;;
esac

juvant_db_exec "UPDATE agent_actions_log
  SET status = 'success',
      result_hash = '$RESULT_HASH',
      ended_at = '$NOW'
  WHERE id = (
    SELECT id FROM agent_actions_log
    $WHERE_CLAUSE
    ORDER BY started_at DESC
    LIMIT 1
  );" \
  || echo "[post-tool-use] WARN: failed to update agent_actions_log" >&2

exit 0
