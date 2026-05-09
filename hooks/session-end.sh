#!/usr/bin/env bash
# hooks/session-end.sh
# Claude Code hook: SessionEnd
# Called when a Claude Code session ends.
# Marks agent as inactive AND finalizes the main-session token-usage
# row (FEAT-024) with ended_at and final cumulative counters.
# SessionEnd is the commit boundary: anything not persisted is lost.
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

if [[ -z "$JUVANT_DB_PROVIDER" ]]; then
  echo "[session-end] WARN: No db.provider configured. Skipping status update." >&2
  exit 0
fi

# Cloud-provider env propagation for track-tokens.sh (which expects
# TURSO_URL/TURSO_TOKEN). Local provider sets only the URL — track-tokens
# routes via the same db.sh helper internally.
if [[ -n "${JUVANT_DB_URL:-}" ]]; then
  export TURSO_URL="$JUVANT_DB_URL"
fi
if [[ -n "${JUVANT_DB_TOKEN:-}" ]]; then
  export TURSO_TOKEN="$JUVANT_DB_TOKEN"
fi

ROLE="${AGENT_ROLE:-cos}"
NOW=$(date -u +"%Y-%m-%d %H:%M:%S")
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
ROLE_ESC=$(sql_escape "$ROLE")

juvant_db_exec \
  "UPDATE agents SET status='inactive', updated_at='$NOW' WHERE role='$ROLE_ESC';" \
  || echo "[session-end] WARN: Failed to update agent status." >&2

# FEAT-024 — finalize main-session token usage with ended_at.
TRANSCRIPT=""
SESSION_ID=""
if [[ -n "$EVENT_JSON" ]] && command -v jq &>/dev/null; then
  TRANSCRIPT=$(echo "$EVENT_JSON" | jq -r '.transcript_path // ""')
  SESSION_ID=$(echo "$EVENT_JSON" | jq -r '.session_id // ""')
fi

if [[ -n "$TRANSCRIPT" && -n "$SESSION_ID" && -f "$SCRIPT_DIR/lib/track-tokens.sh" ]]; then
  PRINCIPAL_ID="${JUVANT_PRINCIPAL:-}"
  PROJECT_SLUG="${JUVANT_ACTIVE_PROJECT:-}"
  ENDED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  STARTED_AT="$ENDED_AT"  # only used on first INSERT; UPSERT preserves prior on existing row
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/lib/track-tokens.sh"
  track_main_session_usage \
    "$TRANSCRIPT" "$SESSION_ID" "$STARTED_AT" \
    "$PRINCIPAL_ID" "$PROJECT_SLUG" "$ENDED_AT" \
    || true
fi

exit 0
