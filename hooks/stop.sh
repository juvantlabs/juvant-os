#!/usr/bin/env bash
# hooks/stop.sh
# Claude Code hook: Stop
# Fires when the assistant finishes responding to a prompt (turn end).
# Used by FEAT-024 to UPSERT cumulative token usage for the main session
# in agent_token_usage. Idempotent: callable on every turn without
# producing duplicate rows.
#
# stdin: JSON event including transcript_path and session_id.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EVENT_JSON=""
if [ -p /dev/stdin ]; then
  EVENT_JSON=$(cat -)
fi

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/db.sh"
juvant_db_resolve

if [[ -z "$JUVANT_DB_PROVIDER" ]]; then exit 0; fi

# Cloud-provider env propagation for track-tokens.sh.
if [[ -n "${JUVANT_DB_URL:-}" ]]; then
  export TURSO_URL="$JUVANT_DB_URL"
fi
if [[ -n "${JUVANT_DB_TOKEN:-}" ]]; then
  export TURSO_TOKEN="$JUVANT_DB_TOKEN"
fi

TRANSCRIPT=""
SESSION_ID=""
if [[ -n "$EVENT_JSON" ]] && command -v jq &>/dev/null; then
  TRANSCRIPT=$(echo "$EVENT_JSON" | jq -r '.transcript_path // ""')
  SESSION_ID=$(echo "$EVENT_JSON" | jq -r '.session_id // ""')
fi

if [[ -z "$TRANSCRIPT" || -z "$SESSION_ID" ]]; then exit 0; fi

PRINCIPAL_ID="${JUVANT_PRINCIPAL:-}"
PROJECT_SLUG="${JUVANT_ACTIVE_PROJECT:-}"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# started_at: if a row already exists for this session, the UPSERT path in
# track_main_session_usage preserves it via excluded.* on update (we only
# overwrite the cumulative counters). For first INSERT we pass NOW as a
# best-effort started_at — not the actual session start, but Stop fires
# soon after so the drift is at most one turn.
STARTED_AT="$NOW"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/track-tokens.sh"
track_main_session_usage \
  "$TRANSCRIPT" "$SESSION_ID" "$STARTED_AT" \
  "$PRINCIPAL_ID" "$PROJECT_SLUG" "" \
  || true

exit 0
