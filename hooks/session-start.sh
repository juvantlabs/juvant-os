#!/usr/bin/env bash
# hooks/session-start.sh
# Claude Code hook: SessionStart
# Called when a Claude Code session starts.
# Reads JSON event from stdin; writes agent status to Turso (or Local
# SQLite per .juvant/config.json db.provider).
#
# Claude Code provides hook event data via stdin as JSON.
# Example stdin: {"type":"session_start","session_id":"abc123"}
#
# Env vars used: AGENT_ROLE (set by JUVANT_OS.md skill at session boot)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Read event JSON from stdin (may be empty on some Claude Code versions)
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
  echo "[session-start] WARN: No db.provider configured. Skipping status update." >&2
  exit 0
fi

# Resolve agent role — needed for both kill-switch check and status update
ROLE="${AGENT_ROLE:-cos}"

# Per handbook ADR 0004 Track 4 — refuse session start when kill switch is active
KILL_ROW=$(juvant_db_query \
  "SELECT active || '|' || COALESCE(reason, '') || '|' || COALESCE(affected_agents, '') FROM agent_kill_switch WHERE id=1;" \
  | tail -1 || echo "0||")
KILL_ACTIVE=$(echo "$KILL_ROW" | cut -d'|' -f1 | tr -d ' ')
KILL_REASON=$(echo "$KILL_ROW" | cut -d'|' -f2)
KILL_AFFECTED=$(echo "$KILL_ROW" | cut -d'|' -f3)

if [[ "$KILL_ACTIVE" == "1" ]]; then
  if [[ -z "$KILL_AFFECTED" || "$KILL_AFFECTED" == "null" ]] || \
     echo "$KILL_AFFECTED" | jq -r '.[]' 2>/dev/null | grep -qx "$ROLE"; then
    echo "[session-start] KILL SWITCH ACTIVE: $KILL_REASON. Refusing session start for role=$ROLE." >&2
    # Best-effort notify CEO via existing notification hook
    JUVANT_NOTIFY_PRIORITY=critical \
      bash "$SCRIPT_DIR/notification.sh" \
      <<< "{\"message\":\"Kill switch denied $ROLE start: $KILL_REASON\"}" \
      2>/dev/null || true
    exit 1
  fi
fi

# Extract session_id from stdin JSON if available
SESSION_ID=""
if [[ -n "$EVENT_JSON" ]] && command -v jq &>/dev/null; then
  SESSION_ID=$(echo "$EVENT_JSON" | jq -r '.session_id // ""' 2>/dev/null || echo "")
fi

NOW=$(date -u +"%Y-%m-%d %H:%M:%S")
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
ROLE_ESC=$(sql_escape "$ROLE")
SESSION_ESC=$(sql_escape "$SESSION_ID")

# Update agent status to active
if [[ -n "$SESSION_ID" ]]; then
  juvant_db_exec \
    "UPDATE agents SET status='active', session_id='$SESSION_ESC', updated_at='$NOW' WHERE role='$ROLE_ESC';" \
    || echo "[session-start] WARN: Failed to update agent status." >&2
else
  juvant_db_exec \
    "UPDATE agents SET status='active', updated_at='$NOW' WHERE role='$ROLE_ESC';" \
    || echo "[session-start] WARN: Failed to update agent status." >&2
fi

# FEAT-026: run knowledge source snapshot check in background (never blocks).
# BUG-027: stamp run-ID + prune log to last 7 runs before launching so
# stale error entries from prior runs are never re-surfaced as current bugs.
if [[ -x "$REPO_ROOT/helpers/kb-sync.sh" ]]; then
  _KBLOG="$REPO_ROOT/.juvant/logs/kb-sync.log"
  mkdir -p "$(dirname "$_KBLOG")"
  if [[ -f "$_KBLOG" ]]; then
    _total=$(grep -c '^=== RUN ' "$_KBLOG" 2>/dev/null || true)
    if [[ "${_total:-0}" -gt 7 ]]; then
      _skip=$(( _total - 7 ))
      awk -v skip="$_skip" '/^=== RUN /{n++} n>skip{print}' \
        "$_KBLOG" > "${_KBLOG}.tmp" && mv "${_KBLOG}.tmp" "$_KBLOG"
    fi
  fi
  echo "=== RUN $(date -u +%Y%m%dT%H%M%SZ) ===" >> "$_KBLOG"
  bash "$REPO_ROOT/helpers/kb-sync.sh" >> "$_KBLOG" 2>&1 &
fi

# FEAT-051: flush the audit spool in the background (never blocks session
# start). Self-bootstrapping replacement for a cron-driven drain — every
# new session drains whatever the previous session spooled, so the spool
# can never grow unbounded even on instances that don't schedule the
# periodic drain.
if [[ -x "$REPO_ROOT/helpers/drain-audit-spool.sh" ]]; then
  bash "$REPO_ROOT/helpers/drain-audit-spool.sh" >/dev/null 2>&1 &
fi

exit 0
