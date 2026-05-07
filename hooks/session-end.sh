#!/usr/bin/env bash
# hooks/session-end.sh
# Claude Code hook: SessionEnd
# Called when a Claude Code session ends.
# Marks agent as inactive in Turso AND finalizes the main-session
# token-usage row (FEAT-024) with ended_at and final cumulative counters.
# SessionEnd is the commit boundary: anything not in Turso is lost.
#
# stdin: JSON event including transcript_path and session_id.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

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
  echo "[session-end] WARN: No Turso credentials. Skipping status update." >&2
  exit 0
fi

export TURSO_URL TURSO_TOKEN

ROLE="${AGENT_ROLE:-cos}"
NOW=$(date -u +"%Y-%m-%d %H:%M:%S")

turso db shell "$TURSO_URL" \
  "UPDATE agents SET status='inactive', updated_at='$NOW' WHERE role='$ROLE';" \
  2>/dev/null || echo "[session-end] WARN: Failed to update agent status." >&2

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
