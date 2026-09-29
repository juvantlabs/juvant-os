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

# launchd / cron provide a minimal PATH — APPEND Homebrew dirs so turso/
# sqlite3/jq are found, without shadowing a test-shimmed or deliberately-
# first CLI on PATH (mirrors helpers/drain-outbox.sh).
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

# BUG-027: run-ID stamp + prune log to last 7 runs.
_LOG="$SCRIPT_DIR/../.juvant/logs/cso-weekly-audit.log"
if [[ -f "$_LOG" ]]; then
  _total=$(grep -c '^=== RUN ' "$_LOG" 2>/dev/null || true)
  if [[ "${_total:-0}" -gt 7 ]]; then
    _skip=$(( _total - 7 ))
    awk -v skip="$_skip" '/^=== RUN /{n++} n>skip{print}' \
      "$_LOG" > "${_LOG}.tmp" && cat "${_LOG}.tmp" > "$_LOG" && rm -f "${_LOG}.tmp"
  fi
fi
echo "=== RUN $(date -u +%Y%m%dT%H%M%SZ) ===" >> "$_LOG"

# Route DB access through hooks/lib/db.sh: provider-agnostic (turso/azure/
# aws/gcp cloud OR local sqlite), timeout-bounded (BUG-046), reading the
# canonical `.db.url` key with `.turso_url` fallback. The old
# `jq -r '.turso_url'` read FATAL-exited on v0.8 instances whose config
# moved the endpoint under `.db.*`, and the staleness read + escalation
# write silently no-op'd on local-sqlite adopters — this cadence gate
# died without a trace either way.
export JUVANT_CONFIG="$CONFIG"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../hooks/lib/db.sh"
juvant_db_resolve
if [[ -z "${JUVANT_DB_PROVIDER:-}" ]]; then
  echo "[cso-weekly-audit] FATAL: no DB provider configured — set .db.provider (or legacy .turso_url) in $CONFIG" >&2
  exit 1
fi
if ! juvant_db_cli_ok; then
  echo "[cso-weekly-audit] FATAL: the '$JUVANT_DB_PROVIDER' DB CLI ($(juvant_db_required_cli)) is not on PATH — re-run helpers/install-schedules.sh so the schedule's PATH includes it." >&2
  exit 1
fi

TEAMS_URL=$(jq -r '.notifications.teams_webhooks.ops // ""' "$CONFIG" 2>/dev/null || echo "")
COMPANY=$(jq -r '.company.name // .company_name // "Juvant OS"' "$CONFIG" 2>/dev/null || echo "Juvant OS")

# ── Staleness + continuity check ─────────────────────────────────────────────
# decisions#277: replaced hard-coded 7d threshold with env-tunable
# CONTINUITY_WARN_DAYS/FAIL and added agent_actions_log gap so a dead DB
# write path cannot masquerade as a healthy audit surface.
CONT_FAIL_DAYS="${CONTINUITY_FAIL_DAYS:-30}"
STALENESS_DAYS=$(juvant_db_query "
SELECT CAST(julianday('now') - julianday(MAX(created_at)) AS INTEGER)
FROM security_audit_log
WHERE audit_type IN ('5-layer','bootstrap_baseline');
" 2>/dev/null | { grep -E '^[0-9]+$' || true; } | tail -1 | tr -d ' ' || true)
GAP_ACTION=$(juvant_db_query \
  "SELECT CAST(julianday('now') - julianday(COALESCE(MAX(started_at),'1970-01-01 00:00:00')) AS INTEGER) FROM agent_actions_log;" \
  2>/dev/null | { grep -E '^[0-9]+$' || true; } | tail -1 | tr -d '[:space:]' || true)

STALENESS_DAYS="${STALENESS_DAYS:-99}"   # treat missing/unreachable as very stale (fail-safe)
GAP_ACTION="${GAP_ACTION:-99}"

echo "[cso-weekly-audit] cadence: audit=${STALENESS_DAYS}d, actions=${GAP_ACTION}d (thresholds warn=${CONTINUITY_WARN_DAYS:-14}d fail=${CONT_FAIL_DAYS}d)"

if [[ "$STALENESS_DAYS" -le "${CONTINUITY_WARN_DAYS:-14}" ]] && [[ "$GAP_ACTION" -le "${CONTINUITY_WARN_DAYS:-14}" ]]; then
  echo "[cso-weekly-audit] OK — audit + actions both within cadence"
  exit 0
fi

# ── Audit is stale — escalate to CoS via the messages queue ─────────────────
# `messages` is the internal agent-to-agent escalation channel (type='escalation',
# priority, notify_ceo). `inbound_queue` is NOT used: it is the counterparty
# inbound queue and requires a NOT NULL counterparty_id — there is no
# counterparty for an audit-cadence alert.
NOW=$(date -u +"%Y-%m-%d %H:%M:%S")
juvant_db_exec "
INSERT INTO messages (from_agent, to_agent, type, content, priority, notify_ceo, created_at)
VALUES (
  'cso-weekly-audit',
  'cos',
  'escalation',
  'CSO cadence signal: last audit ${STALENESS_DAYS}d, latest action_log ${GAP_ACTION}d (warn=${CONTINUITY_WARN_DAYS:-14}d fail=${CONT_FAIL_DAYS}d). Dispatch CSO 5-layer audit from main thread. If action_log gap dominates, verify Track-3 write path AND whether the silence is a declared window in master_context.halt_windows.',
  'critical',
  1,
  '${NOW}'
);
" || echo "[cso-weekly-audit] WARN: failed to write messages escalation row" >&2

echo "[cso-weekly-audit] ALERT: audit stale (audit=${STALENESS_DAYS}d, actions=${GAP_ACTION}d) — messages escalation row written for cos (notify_ceo=1)"

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
        "text": ("The CSO 5-layer security audit has not run in " + $days + " days (threshold: 7d). Action required: open a Claude Code session and dispatch the CSO audit via CoS → CSO."),
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
