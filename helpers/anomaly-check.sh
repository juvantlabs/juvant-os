#!/usr/bin/env bash
# helpers/anomaly-check.sh
# Anomaly detection over agent_actions_log.
# Per handbook ADR 0004 Track 4.
#
# Runs every 15 min via launchd / cron. Computes rolling stats per
# agent for the last hour and compares against the 7-day baseline.
# Surfaces three classes of anomaly:
#
#   1. Rate burst — agent's calls/hour > 5× its 7-day rolling
#      average. Suggests a runaway loop or compromised prompt.
#   2. High denied rate — > 10% of agent's calls in last hour
#      were denied (PreToolUse veto). Suggests the agent is
#      probing the deny-list or misconfigured.
#   3. High failure rate — > 30% of agent's calls in last hour
#      ended in PostToolUseFailure. Suggests vendor outage,
#      bad credentials, or a buggy tool.
#
# Each detected anomaly emits a Telegram + Teams Critical alert
# via hooks/notification.sh. v1.0 is alert-only — no auto-kill.
# Adopters can wire auto-kill via a separate
# anomaly-response.sh layer (out of v1 scope).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

TURSO_URL=$(jq -r '.turso_url // ""' "$CONFIG" 2>/dev/null || echo "")
if [[ -z "$TURSO_URL" ]]; then
  echo "[anomaly-check] FATAL: turso_url missing from $CONFIG" >&2
  exit 1
fi

# Thresholds. ADR 0004 calls these "starting points"; calibrate
# against observed baselines and record adjustments in decisions.
# Loaded from .juvant/config.json `guardrails.anomaly_thresholds`
# with the documented defaults below as fallback. Adopters override
# via:
#   {
#     "guardrails": {
#       "anomaly_thresholds": {
#         "rate_burst_factor": 5,
#         "denied_pct": 10,
#         "failure_pct": 30
#       }
#     }
#   }
# See helpers/anomaly-baseline-report.sh for the calibration helper.
RATE_BURST_FACTOR=$(jq -r '.guardrails.anomaly_thresholds.rate_burst_factor // 5' "$CONFIG" 2>/dev/null || echo 5)
DENIED_PCT_THRESHOLD=$(jq -r '.guardrails.anomaly_thresholds.denied_pct // 10' "$CONFIG" 2>/dev/null || echo 10)
FAILURE_PCT_THRESHOLD=$(jq -r '.guardrails.anomaly_thresholds.failure_pct // 30' "$CONFIG" 2>/dev/null || echo 30)

ANOMALIES=()

# Per-agent rolling stats over last 1h vs 7-day baseline.
# Baseline = average calls/hour over last 7 days excluding the
# most recent hour (so the baseline isn't skewed by the burst
# we're trying to detect).
RESULTS=$(turso db shell "$TURSO_URL" "
WITH last_hour AS (
  SELECT agent, status,
    julianday(CURRENT_TIMESTAMP) - julianday(started_at) AS age_days
  FROM agent_actions_log
  WHERE julianday(CURRENT_TIMESTAMP) - julianday(started_at) <= (1.0/24)
),
last_hour_summary AS (
  SELECT
    agent,
    COUNT(*) AS calls_last_hour,
    SUM(CASE WHEN status='denied'  THEN 1 ELSE 0 END) AS denied,
    SUM(CASE WHEN status='failure' THEN 1 ELSE 0 END) AS failed
  FROM last_hour GROUP BY agent
),
baseline AS (
  SELECT
    agent,
    COUNT(*) / (7.0 * 24.0) AS calls_per_hour_baseline
  FROM agent_actions_log
  WHERE julianday(CURRENT_TIMESTAMP) - julianday(started_at) BETWEEN (1.0/24) AND 7.0
  GROUP BY agent
)
SELECT
  s.agent,
  s.calls_last_hour,
  COALESCE(b.calls_per_hour_baseline, 0.0),
  s.denied,
  s.failed
FROM last_hour_summary s
LEFT JOIN baseline b ON b.agent = s.agent;
" 2>/dev/null)

if [[ -z "$RESULTS" ]]; then
  echo "[anomaly-check] no agent activity in last hour"
  exit 0
fi

while IFS='|' read -r agent calls baseline denied failed; do
  agent=$(echo "$agent" | tr -d ' ')
  [[ -z "$agent" || "$agent" == "agent" ]] && continue
  calls=$(echo "$calls" | tr -d ' ' | head -1)
  baseline=$(echo "$baseline" | tr -d ' ')
  denied=$(echo "$denied" | tr -d ' ')
  failed=$(echo "$failed" | tr -d ' ')

  # Sanitize numerics
  calls=${calls:-0}; baseline=${baseline:-0}; denied=${denied:-0}; failed=${failed:-0}

  # Rate burst check
  if [[ "$baseline" != "0" && "$baseline" != "0.0" ]]; then
    BURST=$(awk -v c="$calls" -v b="$baseline" -v f="$RATE_BURST_FACTOR" \
      'BEGIN { if (b > 0 && c / b >= f) print "yes"; else print "no" }')
    if [[ "$BURST" == "yes" ]]; then
      ANOMALIES+=("$agent: rate burst — ${calls} calls/hr vs ${baseline} baseline (>= ${RATE_BURST_FACTOR}x)")
    fi
  fi

  # Denied + failed % checks (only if calls >= 5 — avoid n=1 false positives)
  if [[ "$calls" -ge 5 ]]; then
    DENIED_PCT=$(awk -v d="$denied" -v c="$calls" 'BEGIN { print int(d * 100 / c) }')
    if [[ "$DENIED_PCT" -gt "$DENIED_PCT_THRESHOLD" ]]; then
      ANOMALIES+=("$agent: high denied rate — ${denied}/${calls} (${DENIED_PCT}%) > ${DENIED_PCT_THRESHOLD}%")
    fi

    FAILED_PCT=$(awk -v f="$failed" -v c="$calls" 'BEGIN { print int(f * 100 / c) }')
    if [[ "$FAILED_PCT" -gt "$FAILURE_PCT_THRESHOLD" ]]; then
      ANOMALIES+=("$agent: high failure rate — ${failed}/${calls} (${FAILED_PCT}%) > ${FAILURE_PCT_THRESHOLD}%")
    fi
  fi
done <<< "$RESULTS"

if [[ "${#ANOMALIES[@]}" -eq 0 ]]; then
  echo "[anomaly-check] OK — no anomalies in last hour"
  exit 0
fi

echo "[anomaly-check] ALERT — ${#ANOMALIES[@]} anomaly(ies):"
for a in "${ANOMALIES[@]}"; do
  echo "  - $a"
done

# Fire single Critical notification with all anomalies bundled
MSG="Anomaly detector: $(IFS=$'\n  • '; echo "  • ${ANOMALIES[*]}")"
JUVANT_NOTIFY_PRIORITY=critical \
  bash "$SCRIPT_DIR/../hooks/notification.sh" \
  <<< "{\"message\":$(echo -n "$MSG" | jq -R -s '.')}" \
  2>/dev/null || echo "[anomaly-check] WARN: failed to dispatch notification" >&2

exit 1
