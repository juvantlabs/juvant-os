#!/usr/bin/env bash
# helpers/drain-outbox.sh
# ADR 0024 — outbound action queue (outbox) readiness surfacer.
#
# WHAT THIS DOES (and deliberately does NOT do):
#   The outbox (scripts/schema.sql) stages side-effecting MCP operations
#   through draft → approved → sent → failed. The actual dispatch step
#   (approved → sent) calls an MCP server, and MCP servers are Claude-tool
#   surfaces — they are NOT callable from a cron shell. So in v1.0 dispatch
#   is AGENT-MEDIATED: CoS drains approved-and-due rows during a session,
#   honoring per-target throttle (see JUVANT_OS.md § "Outbox — staged
#   outbound actions"). Fully autonomous cloud-routine drain is v1.1+.
#
#   This helper therefore does the shell-safe, network-light part: it reads
#   the outbox and SURFACES what is approved and due, so the morning brief
#   / a notification can tell the CEO "N actions staged and approved,
#   awaiting dispatch" and so a stale backlog never sits silent. It makes
#   exactly one read query, never calls an MCP, never sends anything.
#
# Self-bootstrapping: registered in helpers/install-schedules.sh and safe
# to run on a timer or ad hoc. No-op (exit 0) when the queue is empty or no
# DB is configured.

set -euo pipefail

# launchd / cron provide a minimal PATH — APPEND Homebrew dirs so
# turso/sqlite3 are found, without shadowing a deliberately-first turso.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# db.sh expects SCRIPT_DIR to point at the hooks dir for path resolution.
SCRIPT_DIR="$REPO_ROOT/hooks"
# shellcheck disable=SC1091
. "$REPO_ROOT/hooks/lib/db.sh"

juvant_db_resolve
if [[ -z "${JUVANT_DB_PROVIDER:-}" ]]; then
  echo "[drain-outbox] no db.provider configured; nothing to surface" >&2
  exit 0
fi

# Due = approved AND (no schedule OR schedule has arrived). CURRENT_TIMESTAMP
# is UTC in both sqlite3 and turso, matching scheduled_for's storage.
DUE_SQL="SELECT COUNT(*) FROM outbox
         WHERE status='approved'
           AND (scheduled_for IS NULL OR scheduled_for <= CURRENT_TIMESTAMP);"

DUE="$(juvant_db_query "$DUE_SQL" 2>/dev/null || true)"
DUE="${DUE:-0}"

if [[ "$DUE" == "0" ]]; then
  # Nothing approved-and-due — the common, quiet path.
  exit 0
fi

# Surface a per-target breakdown so the operator sees where the backlog is.
BREAKDOWN_SQL="SELECT target_mcp, COUNT(*) FROM outbox
               WHERE status='approved'
                 AND (scheduled_for IS NULL OR scheduled_for <= CURRENT_TIMESTAMP)
               GROUP BY target_mcp ORDER BY COUNT(*) DESC;"

echo "[drain-outbox] $DUE outbox action(s) approved and due — awaiting agent-mediated dispatch (CoS):"
juvant_db_query_csv "$BREAKDOWN_SQL" 2>/dev/null | while IFS=',' read -r target n; do
  [[ -n "$target" ]] && echo "  - ${target}: ${n}"
done

# Exit 0: surfacing a backlog is informational, not an error. The dispatch
# itself happens in an agent turn, not here.
exit 0
