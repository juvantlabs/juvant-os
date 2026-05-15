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
ORPHAN_DECISIONS=$(turso db shell "$TURSO_URL" "
  SELECT COUNT(*) FROM decisions d
  WHERE d.created_at > '$SINCE'
    AND NOT EXISTS (
      SELECT 1 FROM agent_actions_log a
      WHERE a.agent = d.agent
        AND ABS(julianday(a.started_at) - julianday(d.created_at)) * 1440 <= 5
    );
" 2>/dev/null | tail -1 | tr -d ' ')

# Anomaly 2: pending rows older than 1 hour (hooks should always
# have fired post-tool-use within seconds; long-pending = stuck).
STUCK_PENDING=$(turso db shell "$TURSO_URL" "
  SELECT COUNT(*) FROM agent_actions_log
  WHERE status = 'pending'
    AND started_at > '$SINCE'
    AND julianday(CURRENT_TIMESTAMP) - julianday(started_at) > (1.0/24);
" 2>/dev/null | tail -1 | tr -d ' ')

ORPHAN_DECISIONS=${ORPHAN_DECISIONS:-0}
STUCK_PENDING=${STUCK_PENDING:-0}
TOTAL_ANOMALIES=$((ORPHAN_DECISIONS + STUCK_PENDING))

echo "[audit-reconcile] window: last ${WINDOW_DAYS} days"
echo "[audit-reconcile] orphan decisions (possible fabrication): $ORPHAN_DECISIONS"
echo "[audit-reconcile] stuck pending (possible hook failure):    $STUCK_PENDING"

if [[ "$TOTAL_ANOMALIES" -gt 0 ]]; then
  MSG="Audit reconcile: ${ORPHAN_DECISIONS} orphan decisions + ${STUCK_PENDING} stuck pending in last ${WINDOW_DAYS}d"
  echo "[audit-reconcile] ALERT: $MSG" >&2
  # Use existing notification.sh infrastructure
  JUVANT_NOTIFY_CHANNEL=system \
    bash "$SCRIPT_DIR/../hooks/notification.sh" <<< "{\"message\":\"$MSG\"}" \
    || echo "[audit-reconcile] WARN: failed to send notification" >&2
  exit 1
fi

echo "[audit-reconcile] OK — no anomalies in last ${WINDOW_DAYS}d"
exit 0
