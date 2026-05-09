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

# Retrieve most recent snapshot for this agent and write to stdout
SNAPSHOT=$(juvant_db_query \
  "SELECT snapshot FROM session_snapshots WHERE agent='$ROLE_ESC' ORDER BY created_at DESC LIMIT 1;" \
  | tail -n 1 || echo "")

if [[ -z "$SNAPSHOT" ]]; then
  echo "[post-compact] INFO: No snapshot found for $ROLE. Starting fresh context." >&2
  exit 0
fi

echo "$SNAPSHOT"

exit 0
