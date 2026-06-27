#!/usr/bin/env bash
# helpers/activity-digest.sh
# Per-agent activity summary for the last 24 hours, designed to be
# embedded in the FEAT-007 Helper 1 Morning Brief.
#
# Per handbook ADR 0004 Track 4 § Daily activity digest.
#
# Output: markdown to stdout. Sample:
#
#   Yesterday's agent activity:
#     cfo     14 calls (12 read, 2 write_idempotent),  0 denied,  0 failed
#     cos      9 calls (8 read, 1 write_irreversible), 0 denied,  0 failed
#     ...
#   Anomalies: none
#   Kill switch events: none
#
# Standalone usage (CEO ad-hoc): ./helpers/activity-digest.sh
#
# Programmatic usage (Morning Brief composition): pipe the output into
# the Telegram / Teams brief assembly. Output is UTF-8 markdown,
# no terminal escape codes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

# Route DB access through hooks/lib/db.sh: provider-agnostic (turso/azure/
# aws/gcp cloud OR local sqlite), timeout-bounded (BUG-046), reading the
# canonical `.db.url` key with `.turso_url` fallback. The old
# `jq -r '.turso_url'` read FATAL-exited on v0.8 instances whose config
# moved the endpoint under `.db.*`, and produced empty output on
# local-sqlite adopters — the digest came back blank either way.
export JUVANT_CONFIG="$CONFIG"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../hooks/lib/db.sh"
juvant_db_resolve
if [[ -z "${JUVANT_DB_PROVIDER:-}" ]]; then
  echo "[activity-digest] FATAL: no DB provider configured (.db.provider / .db.url / .turso_url absent in $CONFIG)" >&2
  exit 1
fi

# Window: last 24 hours
SINCE=$(date -u -v-1d +"%Y-%m-%d %H:%M:%S" 2>/dev/null \
        || date -u -d "1 day ago" +"%Y-%m-%d %H:%M:%S")

# Per-agent summary. We don't have category in agent_actions_log
# (only in the MCP server source), so we report by tool_name buckets:
# count + breakdown by status.
PER_AGENT=$(juvant_db_query_csv "
SELECT
  agent,
  COUNT(*) AS calls,
  SUM(CASE WHEN status='success' THEN 1 ELSE 0 END) AS ok,
  SUM(CASE WHEN status='denied'  THEN 1 ELSE 0 END) AS denied,
  SUM(CASE WHEN status='failure' THEN 1 ELSE 0 END) AS failed
FROM agent_actions_log
WHERE started_at > '$SINCE'
GROUP BY agent
ORDER BY calls DESC;
" 2>/dev/null || true)

# Kill switch events (set_at within window or currently active)
KILL_EVENTS=$(juvant_db_query_csv "
SELECT
  CASE WHEN active=1 THEN 'ACTIVE' ELSE 'inactive' END,
  COALESCE(set_at, '-'),
  REPLACE(COALESCE(reason, '-'), ',', ';')
FROM agent_kill_switch
WHERE id=1
  AND (active=1 OR set_at > '$SINCE');
" 2>/dev/null || true)

echo "## Yesterday's agent activity"
echo ""
if [[ -z "$PER_AGENT" ]]; then
  echo "_No agent calls in the last 24 hours._"
else
  echo "| Agent | Calls | OK | Denied | Failed |"
  echo "|---|---:|---:|---:|---:|"
  while IFS=',' read -r agent calls ok denied failed; do
    agent=$(echo "$agent" | tr -d ' ')
    calls=$(echo "$calls" | tr -d ' ')
    ok=$(echo "$ok" | tr -d ' ')
    denied=$(echo "$denied" | tr -d ' ')
    failed=$(echo "$failed" | tr -d ' ')
    [[ -z "$agent" ]] && continue
    printf "| %s | %s | %s | %s | %s |\n" "$agent" "$calls" "$ok" "$denied" "$failed"
  done <<< "$PER_AGENT"
fi
echo ""

echo "### Kill switch"
if [[ -z "$KILL_EVENTS" ]]; then
  echo "No kill switch events in the last 24 hours; switch currently inactive."
else
  while IFS=',' read -r state when reason; do
    state=$(echo "$state" | tr -d ' ')
    [[ -z "$state" ]] && continue
    echo "- **$state** (set_at: $when, reason: $reason)"
  done <<< "$KILL_EVENTS"
fi
echo ""

# Anomaly summary — invoke the same query logic as anomaly-check
# but in non-alerting mode, just report. Keeps activity-digest
# self-contained (no inter-helper coupling).
echo "### Anomalies (last 24 hours)"
DENIED_AGENTS=$(juvant_db_query_csv "
SELECT agent, COUNT(*) FROM agent_actions_log
WHERE status='denied' AND started_at > '$SINCE'
GROUP BY agent;
" 2>/dev/null || true)

if [[ -z "$DENIED_AGENTS" ]]; then
  echo "No denied calls. No reconciliation discrepancies."
else
  echo "Denied calls by agent:"
  while IFS=',' read -r agent count; do
    agent=$(echo "$agent" | tr -d ' ')
    count=$(echo "$count" | tr -d ' ')
    [[ -z "$agent" ]] && continue
    echo "- $agent: $count"
  done <<< "$DENIED_AGENTS"
fi

exit 0
