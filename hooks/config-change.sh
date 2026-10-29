#!/usr/bin/env bash
# hooks/config-change.sh
# Claude Code hook: ConfigChange (FEAT-062)
# Fires when a configuration file changes during a session. Records a forensic
# row in agent_actions_log (Track 3 audit log) — the DETECTION half of guarding
# the guardrail config. This hook is LOG-ONLY and NON-BLOCKING by design:
#
#   • A ConfigChange `decision:"block"` does NOT revert the on-disk write — it
#     only stops Claude Code from hot-reloading the change into the running
#     session (verified live, 2026-10-28). So blocking here is not tamper
#     PREVENTION; the file still changed. Prevention belongs at the PreToolUse
#     write-deny layer (tracked as a separate adopter-scoped issue), which is
#     already fail-closed (FEAT-061). This hook's job is to make sure every
#     config change is RECORDED even when it isn't prevented.
#   • Observational hooks must never break the session, so this always exit 0.
#
# Verified event input schema (CC 2.1.312, live capture):
#   {session_id, transcript_path, cwd, prompt_id, hook_event_name:"ConfigChange",
#    source:"user_settings|project_settings|local_settings|policy_settings|skills",
#    file_path:"<absolute path of the changed config file>"}

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read the event from stdin (redirect, not a named pipe — see subagent-start.sh).
EVENT_JSON=""
if [ ! -t 0 ]; then
  IFS= read -r -d "" -t 2 EVENT_JSON 2>/dev/null || true
fi

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/db.sh"
juvant_db_resolve 2>/dev/null || exit 0
[[ -z "${JUVANT_DB_PROVIDER:-}" ]] && exit 0

SOURCE="" FILE_PATH="" SESSION_ID=""
if [[ -n "$EVENT_JSON" ]] && command -v jq &>/dev/null; then
  SOURCE=$(printf '%s' "$EVENT_JSON" | jq -r '.source // ""' 2>/dev/null || echo "")
  FILE_PATH=$(printf '%s' "$EVENT_JSON" | jq -r '.file_path // ""' 2>/dev/null || echo "")
  SESSION_ID=$(printf '%s' "$EVENT_JSON" | jq -r '.session_id // ""' 2>/dev/null || echo "")
fi
SOURCE="${SOURCE:-unknown}"

# args_hash is NOT NULL in agent_actions_log; hash the raw event (shasum on
# macOS, sha256sum on Linux; fixed sentinel if neither is present).
if command -v shasum &>/dev/null; then
  HASH=$(printf '%s' "$EVENT_JSON" | shasum -a 256 2>/dev/null | cut -d' ' -f1)
elif command -v sha256sum &>/dev/null; then
  HASH=$(printf '%s' "$EVENT_JSON" | sha256sum 2>/dev/null | cut -d' ' -f1)
fi
HASH="${HASH:-no-hash}"

BASE="${FILE_PATH##*/}"
SUMMARY="config change: ${SOURCE}${BASE:+ (}${BASE}${BASE:+)}"
SUMMARY="${SUMMARY:0:200}"
NOW=$(date -u +"%Y-%m-%d %H:%M:%S")

sql_escape() { printf '%s' "$1" | LC_ALL=C sed "s/'/''/g"; }
HASH_ESC=$(sql_escape "$HASH")
SUM_ESC=$(sql_escape "$SUMMARY")
if [[ -n "$SESSION_ID" ]]; then
  SID_SQL="'$(sql_escape "$SESSION_ID")'"
else
  SID_SQL="NULL"
fi

# agent='system' — ConfigChange carries no agent identity; this is a
# framework-originated forensic row (handbook ADR 0004 Track 3).
juvant_db_exec \
  "INSERT INTO agent_actions_log
     (session_id, agent, tool_name, args_hash, status, input_summary, started_at, ended_at)
   VALUES
     ($SID_SQL, 'system', 'ConfigChange', '$HASH_ESC',
      'success', '$SUM_ESC', '$NOW', '$NOW');" \
  2>/dev/null || true

exit 0
