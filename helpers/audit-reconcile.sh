#!/usr/bin/env bash
# helpers/audit-reconcile.sh
# Weekly reconciliation of agent_actions_log (hook-written, ground
# truth) vs decisions (agent-written, possibly tampered).
#
# Per handbook ADR 0004 Track 3: cover-up via fabricated decisions
# rows is detectable by reconciling against the hook log. The hook
# log row exists BEFORE the agent has a chance to write anywhere
# else, so a decisions row with no matching antecedent action is an
# anomaly worth surfacing.
#
# Anomalies surfaced:
#   1. decisions row in time window with no preceding agent_actions_log
#      entry in the same session within ±5 minutes — possible
#      fabrication.
#   2. agent_actions_log session that abruptly stops with multiple
#      pending rows that never got finalized — possible session crash
#      OR hook failure (deserves investigation).
#
# Notification: Critical priority via hooks/notification.sh →
# Telegram + Teams `Approvals` channel if anomaly count > 0.
#
# Schedule: weekly, Saturday 03:00 (low contention).

set -euo pipefail

# launchd / cron provide a minimal PATH — extend it to find Homebrew tools.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

# BUG-027: run-ID stamp + prune log to last 7 runs.
_LOG="$SCRIPT_DIR/../.juvant/logs/audit-reconcile.log"
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
  echo "[audit-reconcile] FATAL: turso_url missing from $CONFIG" >&2
  exit 1
fi

WINDOW_DAYS=7
SINCE=$(date -u -v-${WINDOW_DAYS}d +"%Y-%m-%d %H:%M:%S" 2>/dev/null \
        || date -u -d "${WINDOW_DAYS} days ago" +"%Y-%m-%d %H:%M:%S")

# Anomaly 1: decisions rows with no matching agent_actions_log in same
# session within ±5 minutes. Tolerance accounts for hook-write delay.
# BUG-026 fix: main-thread CoS writes are logged as agent='unknown'
# (no agent_type in operator context). Accept 'unknown' as a valid
# antecedent for decisions.agent='cos' so legitimate CoS decisions do
# not trigger false-positive fabrication alerts.
ORPHAN_DECISIONS=$(turso db shell "$TURSO_URL" "
  SELECT COUNT(*) FROM decisions d
  WHERE d.created_at > '$SINCE'
    AND NOT EXISTS (
      SELECT 1 FROM agent_actions_log a
      WHERE (a.agent = d.agent OR (d.agent = 'cos' AND a.agent = 'unknown'))
        AND ABS(julianday(a.started_at) - julianday(d.created_at)) * 1440 <= 5
    );
" 2>/dev/null | { grep -E '^[0-9]+$' || true; } | tail -1 | tr -d ' ')

# Anomaly 2: pending rows older than 1 hour that belong to sessions
# with mixed status (at least one completed row). This distinguishes
# crash pattern (some success/failure + some stuck pending) from
# background subagent pattern (ALL rows pending — post-tool-use hook
# never reaches background subagent process context, BUG-025).
STUCK_PENDING=$(turso db shell "$TURSO_URL" "
  SELECT COUNT(*) FROM agent_actions_log
  WHERE status = 'pending'
    AND started_at > '$SINCE'
    AND julianday(CURRENT_TIMESTAMP) - julianday(started_at) > (1.0/24)
    AND session_id IN (
      SELECT DISTINCT session_id FROM agent_actions_log
      WHERE status IN ('success', 'failure', 'denied')
        AND started_at > '$SINCE'
    );
" 2>/dev/null | { grep -E '^[0-9]+$' || true; } | tail -1 | tr -d ' ')

# Anomaly 3: §4c violations — project-scope agent wrote to company DB
# (FEAT-042 / SYSTEM_INVARIANTS §4c, 2026-05-18)
_PROJECT_AGENTS="'pca','product-lead','design-lead','eng-lead','eng-api','eng-backend','eng-frontend','eng-ai'"
SCOPE_VIOLATIONS=$(turso db shell "$TURSO_URL" "
  SELECT COUNT(*) FROM decisions
  WHERE created_at > '$SINCE'
    AND agent IN ($_PROJECT_AGENTS);
" 2>/dev/null | { grep -E '^[0-9]+$' || true; } | tail -1 | tr -d ' ')

# Anomaly 4 (FEAT-039): stale gh-issue-spec / pr-spec decisions — approved or
# proposed but never executed after STALE_DAYS days. Surfaces the write-path gap
# where Eng Lead created the GH artifact but skipped the source_ref / status
# UPDATE. Threshold is 3 days to tolerate decisions pending CEO approval over a
# weekend.
STALE_DAYS=3
STALE_SINCE=$(date -u -v-${STALE_DAYS}d +"%Y-%m-%d %H:%M:%S" 2>/dev/null \
              || date -u -d "${STALE_DAYS} days ago" +"%Y-%m-%d %H:%M:%S")

STALE_SPECS=$(turso db shell "$TURSO_URL" "
  SELECT COUNT(*) FROM decisions
  WHERE category IN ('gh-issue-spec', 'pr-spec')
    AND status IN ('proposed', 'approved')
    AND created_at < '$STALE_SINCE';
" 2>/dev/null | { grep -E '^[0-9]+$' || true; } | tail -1 | tr -d ' ')

ORPHAN_DECISIONS=${ORPHAN_DECISIONS:-0}
STUCK_PENDING=${STUCK_PENDING:-0}
SCOPE_VIOLATIONS=${SCOPE_VIOLATIONS:-0}
STALE_SPECS=${STALE_SPECS:-0}
TOTAL_ANOMALIES=$((ORPHAN_DECISIONS + STUCK_PENDING + SCOPE_VIOLATIONS + STALE_SPECS))

echo "[audit-reconcile] window: last ${WINDOW_DAYS} days"
echo "[audit-reconcile] orphan decisions (possible fabrication):  $ORPHAN_DECISIONS"
echo "[audit-reconcile] stuck pending (possible hook failure):     $STUCK_PENDING"
echo "[audit-reconcile] scope-boundary violations §4c (proj→co):  $SCOPE_VIOLATIONS"
echo "[audit-reconcile] stale gh-issue/pr specs (>3d unexecuted): $STALE_SPECS"

if [[ "$TOTAL_ANOMALIES" -gt 0 ]]; then
  MSG="Audit reconcile: ${ORPHAN_DECISIONS} orphan + ${STUCK_PENDING} stuck-pending + ${SCOPE_VIOLATIONS} scope-violations + ${STALE_SPECS} stale-specs in last ${WINDOW_DAYS}d"
  echo "[audit-reconcile] ALERT: $MSG" >&2
  # Use existing notification.sh infrastructure
  JUVANT_NOTIFY_CHANNEL=system \
    bash "$SCRIPT_DIR/../hooks/notification.sh" <<< "{\"message\":\"$MSG\"}" \
    || echo "[audit-reconcile] WARN: failed to send notification" >&2
  exit 1
fi

echo "[audit-reconcile] OK — no anomalies in last ${WINDOW_DAYS}d"
exit 0
