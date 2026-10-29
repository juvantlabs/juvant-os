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

TEAMS_URL=$(juvant_secret_get '.notifications.teams_webhooks.ops' "$CONFIG")
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

_STALENESS_READ=0; [[ -n "$STALENESS_DAYS" ]] && _STALENESS_READ=1
_GAP_READ=0;       [[ -n "$GAP_ACTION" ]]     && _GAP_READ=1
STALENESS_DAYS="${STALENESS_DAYS:-99}"   # treat missing/unreachable as very stale (fail-safe)
GAP_ACTION="${GAP_ACTION:-99}"

echo "[cso-weekly-audit] cadence: audit=${STALENESS_DAYS}d, actions=${GAP_ACTION}d (thresholds warn=${CONTINUITY_WARN_DAYS:-14}d fail=${CONT_FAIL_DAYS}d)"

# ── Declared pause windows (decisions#300; shared lib, same semantics as the
# CSO bootstrap audit). A silence inside master_context.halt_windows is a
# declared closure, not a cadence failure: both indicators are reduced to their
# UNCOVERED portion before the threshold check. The fail-safe 99d sentinel (a
# failed/empty read) is never discounted. No key → EFF_* == raw → unchanged.
EFF_STALENESS="$STALENESS_DAYS"
EFF_GAP="$GAP_ACTION"
PW_ON=0
PW_SUMMARY=""
if [[ -f "$SCRIPT_DIR/../hooks/lib/pause-windows.sh" ]]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/../hooks/lib/pause-windows.sh"
  if juvant_pause_windows_load; then
    PW_ON=1
    PW_SUMMARY=$(juvant_pause_windows_summary)
    [[ "$_STALENESS_READ" == "1" ]] && EFF_STALENESS=$(juvant_pause_uncovered_days "$STALENESS_DAYS")
    [[ "$_GAP_READ" == "1" ]]       && EFF_GAP=$(juvant_pause_uncovered_days "$GAP_ACTION")
    echo "[cso-weekly-audit] declared halt_windows: ${PW_SUMMARY} — uncovered: audit=${EFF_STALENESS}d, actions=${EFF_GAP}d"
    IFS='|' read -r _PW_CNT _PW_MIN _PW_MAX <<<"$(juvant_pause_activity_inside agent_actions_log started_at)"
    if [[ "${_PW_CNT:-0}" =~ ^[0-9]+$ ]] && [[ "${_PW_CNT:-0}" -gt 0 ]]; then
      echo "[cso-weekly-audit] INFO: ${_PW_CNT} agent_actions_log row(s) dated inside declared halt_windows (${_PW_MIN} .. ${_PW_MAX}) — replayed/backfilled activity; informational, not a contradiction of the declared closure"
    fi
  fi
fi

if [[ "$EFF_STALENESS" -le "${CONTINUITY_WARN_DAYS:-14}" ]] && [[ "$EFF_GAP" -le "${CONTINUITY_WARN_DAYS:-14}" ]]; then
  if [[ "$PW_ON" == "1" ]] && { [[ "$STALENESS_DAYS" -gt "${CONTINUITY_WARN_DAYS:-14}" ]] || [[ "$GAP_ACTION" -gt "${CONTINUITY_WARN_DAYS:-14}" ]]; }; then
    echo "[cso-weekly-audit] OK — silence covered by declared halt_windows (${PW_SUMMARY}); uncovered remainder within cadence"
  else
    echo "[cso-weekly-audit] OK — audit + actions both within cadence"
  fi
  exit 0
fi

_PW_MSG=""
if [[ "$PW_ON" == "1" ]]; then
  _PW_MSG=" Declared halt_windows (${PW_SUMMARY}) already discounted: raw audit ${STALENESS_DAYS}d, raw action_log ${GAP_ACTION}d; figures above are the UNCOVERED portion."
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
  'CSO cadence signal: last audit ${EFF_STALENESS}d, latest action_log ${EFF_GAP}d (warn=${CONTINUITY_WARN_DAYS:-14}d fail=${CONT_FAIL_DAYS}d).${_PW_MSG} Dispatch CSO 5-layer audit from main thread. If action_log gap dominates, verify Track-3 write path AND whether the silence is a declared window in master_context.halt_windows.',
  'critical',
  1,
  '${NOW}'
);
" || echo "[cso-weekly-audit] WARN: failed to write messages escalation row" >&2

echo "[cso-weekly-audit] ALERT: audit stale (audit=${EFF_STALENESS}d, actions=${EFF_GAP}d) — messages escalation row written for cos (notify_ceo=1)"

# ── Teams notification ───────────────────────────────────────────────────────
if [[ -z "$TEAMS_URL" ]]; then
  echo "[cso-weekly-audit] WARN: notifications.teams_webhooks.ops not configured — skipping Teams alert" >&2
  exit 1
fi

DATE_DISPLAY=$(date "+%a %d %b %Y")

CARD=$(jq -n \
  --arg days "$EFF_STALENESS" \
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

echo "[cso-weekly-audit] DONE — stale alert sent for ${DATE_DISPLAY} (${EFF_STALENESS}d)"
exit 1
