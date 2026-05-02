#!/usr/bin/env bash
# hooks/post-compact.sh
# Claude Code hook: PostCompact
# Called immediately after Claude Code compacts the context window.
# Outputs the latest session snapshot to stdout so Claude Code injects
# it back into the new context window.

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
  echo "[post-compact] WARN: No Turso credentials. Cannot restore snapshot." >&2
  exit 0
fi

ROLE="${AGENT_ROLE:-cos}"

# Retrieve most recent snapshot for this agent and write to stdout
# Claude Code reads stdout from PostCompact hooks and injects it into context
SNAPSHOT=$(turso db shell "$TURSO_URL" \
  "SELECT snapshot FROM session_snapshots WHERE agent='$ROLE' ORDER BY created_at DESC LIMIT 1;" \
  2>/dev/null | tail -n 1 || echo "")

if [[ -z "$SNAPSHOT" ]]; then
  echo "[post-compact] INFO: No snapshot found for $ROLE. Starting fresh context." >&2
  exit 0
fi

# Output snapshot to stdout — Claude Code injects this into the new context
echo "$SNAPSHOT"

exit 0
