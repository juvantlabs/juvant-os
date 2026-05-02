#!/usr/bin/env bash
# hooks/pre-compact.sh
# Claude Code hook: PreCompact
# Called immediately before Claude Code compacts the context window.
# CRITICAL ORDER:
#   1. Agent MUST have committed all pending Turso writes before this runs.
#      (The JUVANT_OS.md Skill instructs agents to commit before snapshot.)
#   2. This script reads the snapshot from stdin (written by agent),
#      then writes it to Turso session_snapshots.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

# Load credentials
if [[ -z "${TURSO_URL:-}" || -z "${TURSO_TOKEN:-}" ]]; then
  if [[ -f "$CONFIG" ]]; then
    TURSO_URL=$(jq -r '.turso_url' "$CONFIG" 2>/dev/null || echo "")
    TURSO_TOKEN=$(jq -r '.turso_token' "$CONFIG" 2>/dev/null || echo "")
  fi
fi

if [[ -z "${TURSO_URL:-}" || -z "${TURSO_TOKEN:-}" ]]; then
  echo "[pre-compact] WARN: No Turso credentials. Snapshot not persisted." >&2
  exit 0
fi

ROLE="${AGENT_ROLE:-cos}"
NOW=$(date -u +"%Y-%m-%d %H:%M:%S")

# Read snapshot content from stdin (agent writes its context summary to stdout
# which Claude Code routes to this hook's stdin)
SNAPSHOT_CONTENT=""
if [ -p /dev/stdin ]; then
  SNAPSHOT_CONTENT=$(cat -)
fi

if [[ -z "$SNAPSHOT_CONTENT" ]]; then
  echo "[pre-compact] WARN: Empty snapshot for $ROLE. No session_snapshots row written." >&2
  exit 0
fi

# Escape single quotes for SQL
SNAPSHOT_ESCAPED=$(echo "$SNAPSHOT_CONTENT" | sed "s/'/''/g")

# Get current session_id
SESSION_ID=$(turso db shell "$TURSO_URL" \
  "SELECT session_id FROM agents WHERE role='$ROLE' LIMIT 1;" 2>/dev/null | tail -n 1 || echo "")

# Write snapshot to Turso
turso db shell "$TURSO_URL" \
  "INSERT INTO session_snapshots (agent, snapshot, session_id, created_at) VALUES ('$ROLE', '$SNAPSHOT_ESCAPED', '$SESSION_ID', '$NOW');" \
  2>/dev/null || echo "[pre-compact] WARN: Failed to write snapshot to Turso." >&2

exit 0
