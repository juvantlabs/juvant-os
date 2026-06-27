#!/usr/bin/env bash
# hooks/post-compact.sh
# Claude Code hook: PostCompact
# Called immediately after Claude Code compacts the context window.
# Outputs the latest session snapshot to stdout so Claude Code injects
# it back into the new context window.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/db.sh"
juvant_db_resolve

if [[ -z "$JUVANT_DB_PROVIDER" ]]; then
  echo "[post-compact] WARN: No db.provider configured. Cannot restore snapshot." >&2
  exit 0
fi

ROLE="${AGENT_ROLE:-cos}"
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
ROLE_ESC=$(sql_escape "$ROLE")

# Retrieve most recent snapshot for this agent. pre-compact.sh stores it
# base64-encoded — a single, whitespace-free line — precisely so it survives
# the CLI round-trip (juvant_db_query strips all whitespace on turso; the
# `tail -n 1` below keeps the last line). Both are no-ops on base64.
SNAPSHOT_RAW=$(juvant_db_query \
  "SELECT snapshot FROM session_snapshots WHERE agent='$ROLE_ESC' ORDER BY created_at DESC LIMIT 1;" \
  | tail -n 1 || echo "")

if [[ -z "$SNAPSHOT_RAW" ]]; then
  echo "[post-compact] INFO: No snapshot found for $ROLE. Starting fresh context." >&2
  exit 0
fi

# Decode base64. Back-compat: rows written before this change are raw text,
# which is not valid base64 — detect by round-trip identity (re-encoding the
# decode must reproduce the stored string) and fall back to the raw value.
SNAPSHOT_DECODED=$(printf '%s' "$SNAPSHOT_RAW" | base64 -d 2>/dev/null || true)
if [[ -n "$SNAPSHOT_DECODED" ]] \
   && [[ "$(printf '%s' "$SNAPSHOT_DECODED" | base64 | tr -d '\n')" == "$SNAPSHOT_RAW" ]]; then
  SNAPSHOT="$SNAPSHOT_DECODED"
else
  SNAPSHOT="$SNAPSHOT_RAW"   # legacy raw row (pre-base64)
fi

echo "$SNAPSHOT"

exit 0
