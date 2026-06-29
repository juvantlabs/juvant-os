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

# FEAT-035 — wrap-up check: query Turso for observable unsaved-work
# indicators. If any found, write a session-wrap-reminder messages row
# so session-start.sh surfaces it at next boot.
if [[ -n "$JUVANT_DB_PROVIDER" ]]; then
  # BUG-048: route through db.sh's juvant_db_query (hard-timeout wrapped per
  # BUG-046) instead of calling `turso db shell` directly — a direct call has
  # no time bound and can hang session end on a network stall.
  _count() { juvant_db_query "$1" 2>/dev/null | tail -1 | tr -d ' \r'; }

  PENDING_QUEUE=$(_count \
    "SELECT COUNT(*) FROM inbound_queue WHERE agent_owner='cos' AND status='pending';")
  PROPOSED_DECISIONS=$(_count \
    "SELECT COUNT(*) FROM decisions WHERE status='proposed'
     AND created_at > datetime('now','-24 hours');")
  UNREAD_CEO=$(_count \
    "SELECT COUNT(*) FROM messages WHERE notify_ceo=1 AND status='unread';")

  PENDING_QUEUE=${PENDING_QUEUE:-0}
  PROPOSED_DECISIONS=${PROPOSED_DECISIONS:-0}
  UNREAD_CEO=${UNREAD_CEO:-0}

  WRAP_TOTAL=$((PENDING_QUEUE + PROPOSED_DECISIONS + UNREAD_CEO))
  if [[ "$WRAP_TOTAL" -gt 0 ]]; then
    SESSION_ESC=$(printf '%s' "${SESSION_ID:-}" | sed "s/'/''/g")
    CONTENT=$(printf '{"pending_queue":%s,"proposed_decisions":%s,"unread_ceo_messages":%s,"session_id":"%s"}' \
      "$PENDING_QUEUE" "$PROPOSED_DECISIONS" "$UNREAD_CEO" "$SESSION_ESC")
    juvant_db_exec \
      "INSERT INTO messages (from_agent, to_agent, type, content, priority, notify_ceo)
       VALUES ('cos','cos','session-wrap-reminder','$CONTENT','high',1);" \
      || echo "[session-end] WARN: failed to write wrap-up reminder" >&2
    echo "[session-end] wrap-up reminder written: queue=$PENDING_QUEUE decisions=$PROPOSED_DECISIONS unread=$UNREAD_CEO"
  fi
fi

exit 0
