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

# ── Layer 1 (ADR 0028 / ARCH-017): capture-at-execution gate (shared lib) ──
# Main-thread coverage: if a PR merged this session references an approved,
# still-unmarked pr-spec, block the turn until the agent closes the row. No role
# filter (main thread is not a single subagent). Shared logic with
# subagent-stop.sh; BUG-057 warn + BUG-058 spool-drain handled in the lib.
if [[ -f "$SCRIPT_DIR/lib/spec-marking-gate.sh" ]]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/lib/spec-marking-gate.sh"
  # NOTE: do NOT swallow the gate's stderr — the BUG-057 unresolved-repo WARN
  # must stay visible. stdout is the block reason (captured); stderr flows out.
  _L1_REASON="$(spec_marking_gate "$SESSION_ID" "" || echo "")"
  if [[ -n "$_L1_REASON" ]]; then
    jq -nc --arg r "$_L1_REASON" '{decision:"block", reason:$r}' 2>/dev/null \
      || printf '{"decision":"block","reason":"spec-marking gate: an approved pr-spec is unmarked after its PR merged"}\n'
    echo "$_L1_REASON" >&2
    exit 2
  fi
fi

exit 0
