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

# decisions#300 item 13 (security_audit_log#148, detection half): guardrail
# tree integrity. Runs before the DB check so a DB-less session still sees it.
# SessionStart stdout is added to the session context, so the warning reaches
# the main thread (CoS), which must surface it to the CEO. Never blocks.
if [[ -f "$SCRIPT_DIR/lib/hooks-integrity.sh" ]]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/lib/hooks-integrity.sh"
  _HI_RC=0
  _HI_OUT=$(juvant_hooks_integrity_check "$REPO_ROOT") || _HI_RC=$?
  if [[ "$_HI_RC" -eq 1 ]]; then
    _HI_LIST=$(printf '%s' "$_HI_OUT" | grep -v '^baseline:' | paste -sd ';' - | sed 's/;/; /g')
    echo "SECURITY WARNING (hooks integrity, decisions#300): guardrail files differ from the canonical upstream content — ${_HI_LIST}. The PreToolUse gate may have been tampered with. Surface this to the CEO and the CSO before any other work; restore with 'git checkout upstream/main -- <file>' once reviewed."
    echo "[session-start] SECURITY WARNING: hooks integrity check failed: ${_HI_LIST}" >&2
    if [[ -n "$JUVANT_DB_PROVIDER" ]]; then
      _HI_SUM=$(printf 'hooks integrity: %s' "$_HI_LIST" | cut -c1-200 | sed "s/'/''/g")
      _HI_HASH=$(printf '%s' "$_HI_OUT" | shasum -a 256 2>/dev/null | cut -d' ' -f1)
      juvant_db_exec_async "INSERT INTO agent_actions_log
        (session_id, agent, tool_name, args_hash, status, deny_reason, input_summary, started_at)
        VALUES (NULL, 'system', 'HooksIntegrity', '${_HI_HASH:-no-hash}', 'failed',
                'guardrail files not from canonical upstream (decisions#300 item 13)',
                '$_HI_SUM', '$(date -u +"%Y-%m-%d %H:%M:%S")');" \
        || echo "[session-start] WARN: failed to spool hooks-integrity row" >&2
    fi
  fi
fi

# decisions#305 (B1a, ADR 0034): security policy health + change detection.
# The policy is read from refs/remotes/origin/main. Any change to its blob
# since the previous session → high row + CEO alert (a policy change must be a
# reviewed, visible event). invalid / deleted → the PreToolUse gate fails
# closed on every mcp__ call; say so here too. legacy → deprecation notice.
if [[ -f "$SCRIPT_DIR/lib/security-policy.sh" ]]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/lib/security-policy.sh"
  juvant_policy_load "$REPO_ROOT" 2>/dev/null || true
  _SP_SEEN_FILE="$REPO_ROOT/.juvant/policy-blob-seen"
  _SP_ROW=""; _SP_ALERT=""
  case "$JUVANT_POLICY_STATE" in
    invalid|deleted)
      echo "SECURITY WARNING (security policy, decisions#305): security/policy.json on origin/main is ${JUVANT_POLICY_STATE} (${JUVANT_POLICY_ERR:-}). Every MCP tool call is denied (fail closed) until a valid policy is merged to main. Surface this to the CEO and the CSO."
      _SP_ROW="security policy ${JUVANT_POLICY_STATE} at session start (${JUVANT_POLICY_ERR:-})"
      _SP_ALERT="Security policy ${JUVANT_POLICY_STATE} on origin/main — all MCP calls are denied (decisions#305)" ;;
    legacy)
      echo "NOTICE (decisions#305): sensitive-space rules are still read from .juvant/config.json .security.space_access (deprecated). Move them to a committed security/policy.json on main before the next minor version." ;;
    ok)
      _SP_PREV=$(cat "$_SP_SEEN_FILE" 2>/dev/null || echo "")
      if [[ -n "$_SP_PREV" && "$_SP_PREV" != "$JUVANT_POLICY_BLOB" ]]; then
        echo "SECURITY NOTICE (decisions#305): security/policy.json on origin/main changed since the last session (blob ${_SP_PREV:0:12} → ${JUVANT_POLICY_BLOB:0:12}). Confirm with the CEO that this change was reviewed and intended."
        _SP_ROW="security policy changed on origin/main: ${_SP_PREV} -> ${JUVANT_POLICY_BLOB}"
        _SP_ALERT="security/policy.json changed on origin/main (${_SP_PREV:0:12} → ${JUVANT_POLICY_BLOB:0:12}) — confirm it was reviewed (decisions#305)"
      fi
      mkdir -p "$REPO_ROOT/.juvant" 2>/dev/null || true
      printf '%s\n' "$JUVANT_POLICY_BLOB" > "$_SP_SEEN_FILE" 2>/dev/null || true ;;
  esac
  if [[ -n "$_SP_ROW" && -n "$JUVANT_DB_PROVIDER" ]]; then
    _SP_ROW_ESC=$(printf '%s' "$_SP_ROW" | sed "s/'/''/g")
    # Not spooled (decisions#303 R3 executes only allowlisted spool shapes);
    # the stdout warning + alert carry the event if the DB is unreachable.
    JUVANT_DB_EXEC_NO_SPOOL=1 juvant_db_exec "INSERT INTO security_audit_log
      (auditor, scope, audit_type, layer, finding, severity, category, status)
      VALUES ('hook:session-start', 'company', 'incident', 'agents', '${_SP_ROW_ESC}', 'high', 'policy-change', 'open');" \
      >/dev/null 2>&1 || echo "[session-start] WARN: security-policy row not written inline (spooled if the transport failed)" >&2
  fi
  if [[ -n "$_SP_ALERT" ]]; then
    JUVANT_NOTIFY_PRIORITY=critical \
      bash "$SCRIPT_DIR/notification.sh" \
      <<< "$(jq -n --arg m "$_SP_ALERT" '{message:$m}')" >/dev/null 2>&1 || true
  fi
fi

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
