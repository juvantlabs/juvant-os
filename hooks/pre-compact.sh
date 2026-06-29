#!/usr/bin/env bash
# hooks/pre-compact.sh
# Claude Code hook: PreCompact
# Called immediately before Claude Code compacts the context window.
# CRITICAL ORDER:
#   1. Agent MUST have committed all pending state writes before this runs.
#      (The JUVANT_OS.md Skill instructs agents to commit before snapshot.)
#   2. This script reads the snapshot from stdin (written by agent),
#      then writes it to session_snapshots.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/db.sh"
juvant_db_resolve

if [[ -z "$JUVANT_DB_PROVIDER" ]]; then
  echo "[pre-compact] WARN: No db.provider configured. Snapshot not persisted." >&2
  exit 0
fi

ROLE="${AGENT_ROLE:-cos}"
NOW=$(date -u +"%Y-%m-%d %H:%M:%S")

# Read snapshot content from stdin (agent writes its context summary to stdout
# which Claude Code routes to this hook's stdin)
SNAPSHOT_CONTENT=""
# Claude Code delivers the event JSON on stdin as a REDIRECT, not necessarily
# a named pipe — the old `[ -p /dev/stdin ]` guard was false for a redirect,
# so the event was never read (session_id lost; the hook silently no-op'd).
# Read whenever stdin is not a terminal, bounded by a 2s read timeout so a
# non-EOF stdin can never hang the hook (no `timeout(1)` dep — absent on macOS).
if [ ! -t 0 ]; then
  IFS= read -r -d "" -t 2 SNAPSHOT_CONTENT 2>/dev/null || true
fi

if [[ -z "$SNAPSHOT_CONTENT" ]]; then
  echo "[pre-compact] WARN: Empty snapshot for $ROLE. No session_snapshots row written." >&2
  exit 0
fi

# Escape single quotes for SQL via sed — bash 3.2 (macOS) parameter
# expansion `${V//\'/\'\'}` produces `\'\'`, which is not valid SQL.
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
# Store the snapshot base64-encoded (single line, no whitespace, no quotes).
# A snapshot is multi-line free text; reading it back through a CLI mangles
# it — `juvant_db_query` strips ALL whitespace on the turso backend and the
# reader's `tail -n 1` keeps only the last line. base64 is immune to both
# (one line, space-free), so post-compact.sh can round-trip it intact.
SNAPSHOT_STORED=$(printf '%s' "$SNAPSHOT_CONTENT" | base64 | tr -d '\n')
ROLE_ESC=$(sql_escape "$ROLE")

# Get current session_id
SESSION_ID=$(juvant_db_query \
  "SELECT session_id FROM agents WHERE role='$ROLE_ESC' LIMIT 1;" \
  | tail -n 1 || echo "")
SESSION_ESC=$(sql_escape "$SESSION_ID")

# Write snapshot
juvant_db_exec \
  "INSERT INTO session_snapshots (agent, snapshot, session_id, created_at)
   VALUES ('$ROLE_ESC', '$SNAPSHOT_STORED', '$SESSION_ESC', '$NOW');" \
  || echo "[pre-compact] WARN: Failed to write snapshot." >&2

exit 0
