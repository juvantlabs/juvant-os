#!/usr/bin/env bash
# hooks/subagent-stop.sh
# Claude Code hook: SubagentStop
# Called when a subagent (nested agent) stops within a session.
# Logs deactivation to the agents table AND inserts a token-usage row
# for the subagent invocation (FEAT-024).
#
# stdin: JSON event with subagent type, session_id, transcript_path.
# Format: {"agent_type":"...","session_id":"...","transcript_path":"..."}

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

# Cloud-provider env propagation for track-tokens.sh.
if [[ -n "${JUVANT_DB_URL:-}" ]]; then
  export TURSO_URL="$JUVANT_DB_URL"
fi
if [[ -n "${JUVANT_DB_TOKEN:-}" ]]; then
  export TURSO_TOKEN="$JUVANT_DB_TOKEN"
fi

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
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
ROLE_ESC=$(sql_escape "$SUBAGENT_ROLE")

juvant_db_exec \
  "UPDATE agents SET status='inactive', updated_at='$NOW' WHERE role='$ROLE_ESC';" \
  || true

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
