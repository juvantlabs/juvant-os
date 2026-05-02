#!/usr/bin/env bash
# hooks/session-end.sh
# Claude Code hook: SessionEnd
# Called when a Claude Code session ends.
# Marks agent as inactive in Turso.
# SessionEnd is the commit boundary: anything not in Turso is lost.

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
  echo "[session-end] WARN: No Turso credentials. Skipping status update." >&2
  exit 0
fi

ROLE="${AGENT_ROLE:-cos}"
NOW=$(date -u +"%Y-%m-%d %H:%M:%S")

turso db shell "$TURSO_URL" \
  "UPDATE agents SET status='inactive', updated_at='$NOW' WHERE role='$ROLE';" \
  2>/dev/null || echo "[session-end] WARN: Failed to update agent status." >&2

exit 0
