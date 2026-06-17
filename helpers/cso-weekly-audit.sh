#!/usr/bin/env bash
# helpers/cso-weekly-audit.sh
# Helper for FEAT-007 (Agent Helpers pattern) — CSO weekly audit cadence.
#
# Scheduled weekly (Sunday 22:00) via launchd / cron.
# Per ADR 0004 + FEAT-007: pure SQL aggregate + curl, no Claude Code spawn.
#
# The CSO 5-layer audit CANNOT be dispatched directly from a bash helper
# because `Task(subagent_type='cso', ...)` requires the Claude Code main
# thread (per JUVANT_OS.md §9.7 constraint: Task tool is main-thread only).
# This helper therefore:
#   1. Checks whether a 5-layer or bootstrap_baseline audit has already
#      run in the last 7 days. If yes — exits 0 (cadence satisfied).
#   2. If stale: writes a Critical inbound_queue entry for the cso agent
#      so CoS surfaces it to the CEO at next session start.
#   3. Sends a Teams notification to the `ops` channel flagging the gap,
#      so the reminder reaches the CEO even outside a Claude Code session.
#
# On-demand usage (manual trigger):
#   bash helpers/cso-weekly-audit.sh
#
# Schedule: Sunday 22:00 local — installed via helpers/install-schedules.sh.

set -euo pipefail

# launchd / cron provide a minimal PATH — extend it to find Homebrew tools.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

# BUG-027: run-ID stamp + prune log to last 7 runs.
_LOG="$SCRIPT_DIR/../.juvant/logs/cso-weekly-audit.log"
if [[ -f "$_LOG" ]]; then
  _total=$(grep -c '^=== RUN ' "$_LOG" 2>/dev/null || true)
  if [[ "${_total:-0}" -gt 7 ]]; then
    _skip=$(( _total - 7 ))
    awk -v skip="$_skip" '/^=== RUN /{n++} n>skip{print}' \
      "$_LOG" > "${_LOG}.tmp" && mv "${_LOG}.tmp" "$_LOG"
  fi
fi
echo "=== RUN $(date -u +%Y%m%dT%H%M%SZ) ===" >> "$_LOG"

TURSO_URL=$(jq -r '.turso_url // ""' "$CONFIG" 2>/dev/null || echo "")
if [[ -z "$TURSO_URL" ]]; then
  echo "[cso-weekly-audit] FATAL: turso_url missing from $CONFIG" >&2
  exit 1
fi

TEAMS_URL=$(jq -r '.notifications.teams_webhooks.ops // ""' "$CONFIG" 2>/dev/null || echo "")
COMPANY=$(jq -r '.company.name // .company_name // "Juvant OS"' "$CONFIG" 2>/dev/null || echo "Juvant OS")

# ── Staleness check ──────────────────────────────────────────────────────────
# Returns 1 if last audit is older than 7 days, 0 if fresh.
STALENESS_DAYS=$(turso db shell "$TURSO_URL" "
SELECT CAST(julianday('now') - julianday(MAX(created_at)) AS INTEGER)
FROM security_audit_log
WHERE audit_type IN ('5-layer','bootstrap_baseline');
" 2>/dev/null | { grep -E '^[0-9]+$' || true; } | tail -1 | tr -d ' ')

STALENESS_DAYS="${STALENESS_DAYS:-99}"   # treat missing as very stale

echo "[cso-weekly-audit] days since last 5-layer/bootstrap audit: ${STALENESS_DAYS}"

if [[ "$STALENESS_DAYS" -le 7 ]]; then
  echo "[cso-weekly-audit] OK — last audit within cadence (${STALENESS_DAYS}d ≤ 7d)"
  exit 0
fi

# ── Audit is stale — write inbound_queue entry for CSO ──────────────────────
NOW=$(date -u +"%Y-%m-%d %H:%M:%S")
turso db shell "$TURSO_URL" "
INSERT INTO inbound_queue (agent_owner, priority, status, subject, body, created_at)
VALUES (
  'cso',
  'critical',
  'pending',
  'CSO 5-layer audit overdue (${STALENESS_DAYS}d stale)',
  'The weekly CSO 5-layer security audit has not run in ${STALENESS_DAYS} days (threshold: 7d). Dispatch via Task(subagent_type=''cso'', ...) per JUVANT_OS.md §9.7. Source: cso-weekly-audit.sh scheduled helper.',
  '${NOW}'
);
" 2>/dev/null || echo "[cso-weekly-audit] WARN: failed to write inbound_queue row" >&2

echo "[cso-weekly-audit] ALERT: audit stale (${STALENESS_DAYS}d) — inbound_queue row written for cso"

# ── Teams notification ───────────────────────────────────────────────────────
if [[ -z "$TEAMS_URL" ]]; then
  echo "[cso-weekly-audit] WARN: notifications.teams_webhooks.ops not configured — skipping Teams alert" >&2
  exit 1
fi

DATE_DISPLAY=$(date "+%a %d %b %Y")

CARD=$(jq -n \
  --arg days "$STALENESS_DAYS" \
  --arg date "$DATE_DISPLAY" \
  --arg company "$COMPANY" \
  '{
    "type": "AdaptiveCard",
    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
    "version": "1.4",
    "body": [
      {
        "type": "TextBlock",
        "text": "Security Audit Overdue",
        "size": "Medium",
        "weight": "Bolder",
        "color": "Attention"
      },
      {
        "type": "TextBlock",
        "text": ($company + " · " + $date),
        "size": "Small",
        "isSubtle": true,
        "spacing": "None"
      },
      {
        "type": "TextBlock",
        "text": ("The CSO 5-layer security audit has not run in " + $days + " days (threshold: 7d). Action required: open a Claude Code session and dispatch the CSO audit via Atlas → Shield."),
        "wrap": true,
        "spacing": "Medium"
      },
      {
        "type": "FactSet",
        "facts": [
          { "title": "Cadence", "value": "Weekly (Sunday 22:00)" },
          { "title": "Days stale", "value": ($days + "d") },
          { "title": "Helper", "value": "cso-weekly-audit.sh" }
        ]
      }
    ]
  }')

curl -s -X POST "$TEAMS_URL" \
  -H "Content-Type: application/json" \
  -d "$CARD" \
  -o /dev/null 2>&1 || echo "[cso-weekly-audit] WARN: Teams delivery failed" >&2

echo "[cso-weekly-audit] DONE — stale alert sent for ${DATE_DISPLAY} (${STALENESS_DAYS}d)"
exit 1
