#!/usr/bin/env bash
# helpers/anomaly-baseline-report.sh
# Threshold calibration helper for anomaly-check.sh.
#
# Reads agent_actions_log over a window (default 30 days) and
# reports observed per-agent statistics:
#   - calls/hour rolling rate (mean + p95)
#   - denied % (mean + p95)
#   - failure % (mean + p95)
#
# Then recommends threshold values based on observed data:
#   - rate_burst_factor: max(5, ceil(p95_rate / mean_rate))
#   - denied_pct: max(10, p95_denied + 5)
#   - failure_pct: max(30, p95_failed + 10)
#
# The "max(default, observed)" floor preserves the structural
# baseline — adopters can lower thresholds if their observed
# baseline justifies stricter limits, but the helper won't
# recommend doing so automatically (would require explicit human
# decision via tool-matrix-change per ADR 0004).
#
# Usage:
#   ./helpers/anomaly-baseline-report.sh                # default 30d window
#   ./helpers/anomaly-baseline-report.sh --days 90      # custom window
#   ./helpers/anomaly-baseline-report.sh --apply        # write recommended
#                                                      # values to config
#                                                      # (with confirmation)
#
# Output: markdown report to stdout. CEO uses for the
# tool-matrix-change decision when proposing threshold updates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

WINDOW_DAYS=30
APPLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) WINDOW_DAYS="$2"; shift 2;;
    --apply) APPLY=1; shift;;
    -h|--help)
      cat <<USAGE
Usage: $0 [--days N] [--apply]

Reports observed anomaly-related statistics from agent_actions_log
and recommends threshold values for anomaly-check.sh.

  --days N  Window size in days (default 30)
  --apply   Write recommended thresholds to .juvant/config.json
            (prompts for confirmation; backs up the original
            config to .juvant/config.json.bak)
USAGE
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

TURSO_URL=$(jq -r '.turso_url // ""' "$CONFIG" 2>/dev/null || echo "")
if [[ -z "$TURSO_URL" ]]; then
  echo "[anomaly-baseline-report] FATAL: turso_url missing from $CONFIG" >&2
  exit 1
fi

echo "# Anomaly threshold baseline report"
echo ""
echo "**Window**: last ${WINDOW_DAYS} days"
echo "**Generated**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo ""

# Per-agent rolling stats
STATS=$(turso db shell "$TURSO_URL" "
WITH per_hour AS (
  SELECT
    agent,
    strftime('%Y-%m-%d %H', started_at) AS hour_bucket,
    COUNT(*) AS calls,
    SUM(CASE WHEN status='denied'  THEN 1 ELSE 0 END) AS denied,
    SUM(CASE WHEN status='failure' THEN 1 ELSE 0 END) AS failed
  FROM agent_actions_log
  WHERE julianday(CURRENT_TIMESTAMP) - julianday(started_at) <= ${WINDOW_DAYS}.0
  GROUP BY agent, hour_bucket
)
SELECT
  agent,
  ROUND(AVG(calls), 2) AS mean_calls_per_hour,
  MAX(calls) AS max_calls_per_hour,
  ROUND(AVG(100.0 * denied / calls), 1) AS mean_denied_pct,
  MAX(100 * denied / calls) AS max_denied_pct,
  ROUND(AVG(100.0 * failed / calls), 1) AS mean_failure_pct,
  MAX(100 * failed / calls) AS max_failure_pct,
  COUNT(*) AS hours_observed
FROM per_hour
GROUP BY agent
ORDER BY mean_calls_per_hour DESC;
" 2>/dev/null || true)

if [[ -z "$STATS" ]]; then
  echo "_No agent activity in the last ${WINDOW_DAYS} days. Defer calibration until baseline accumulates._"
  echo ""
  echo "## Recommended thresholds"
  echo "Keep current defaults: rate_burst_factor=5, denied_pct=10, failure_pct=30."
  exit 0
fi

echo "## Per-agent observed statistics"
echo ""
echo "| Agent | Mean calls/h | Max calls/h | Mean denied % | Max denied % | Mean fail % | Max fail % | Hours obs |"
echo "|---|---:|---:|---:|---:|---:|---:|---:|"

# Compute global p95-ish: max of per-agent maxes (close-enough for v1
# calibration; true p95 across all rows requires more elaborate SQL)
MAX_RATE_FACTOR=1
MAX_DENIED=0
MAX_FAILED=0

while IFS='|' read -r agent mean_cph max_cph mean_d max_d mean_f max_f hours; do
  agent=$(echo "$agent" | xargs)
  [[ -z "$agent" || "$agent" == "agent" ]] && continue
  mean_cph=$(echo "$mean_cph" | xargs)
  max_cph=$(echo "$max_cph" | xargs)
  mean_d=$(echo "$mean_d" | xargs)
  max_d=$(echo "$max_d" | xargs)
  mean_f=$(echo "$mean_f" | xargs)
  max_f=$(echo "$max_f" | xargs)
  hours=$(echo "$hours" | xargs)

  printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n" \
    "$agent" "$mean_cph" "$max_cph" "$mean_d" "$max_d" "$mean_f" "$max_f" "$hours"

  # Track per-agent max-rate / mean ratio
  if [[ "$mean_cph" != "0" && "$mean_cph" != "0.0" ]]; then
    RATIO=$(awk -v m="$max_cph" -v a="$mean_cph" 'BEGIN { if (a > 0) printf "%.0f", m/a; else print 1 }')
    [[ "$RATIO" -gt "$MAX_RATE_FACTOR" ]] && MAX_RATE_FACTOR=$RATIO
  fi
  [[ "$max_d" -gt "$MAX_DENIED" ]] && MAX_DENIED=$max_d
  [[ "$max_f" -gt "$MAX_FAILED" ]] && MAX_FAILED=$max_f
done <<< "$STATS"

echo ""

# Recommendations: keep defaults as floor, recommend higher if observed
REC_RATE=$((MAX_RATE_FACTOR > 5 ? MAX_RATE_FACTOR : 5))
REC_DENIED=$((MAX_DENIED + 5 > 10 ? MAX_DENIED + 5 : 10))
REC_FAILED=$((MAX_FAILED + 10 > 30 ? MAX_FAILED + 10 : 30))

echo "## Recommended thresholds"
echo ""
echo "| Threshold | Current default | Observed (max in window) | Recommended |"
echo "|---|---:|---:|---:|"
echo "| rate_burst_factor | 5 | ${MAX_RATE_FACTOR}x | ${REC_RATE} |"
echo "| denied_pct        | 10 | ${MAX_DENIED}% | ${REC_DENIED} |"
echo "| failure_pct       | 30 | ${MAX_FAILED}% | ${REC_FAILED} |"
echo ""
echo "Rationale: \`max(default, observed + headroom)\` keeps the structural"
echo "floor in place. The helper does NOT recommend tightening below the"
echo "default; if observed baseline justifies stricter limits, that's an"
echo "explicit \`tool-matrix-change\` decision (CA proposes, CSO reviews,"
echo "CEO approves)."

if [[ "$APPLY" -eq 1 ]]; then
  echo ""
  read -r -p "Apply recommended thresholds to $CONFIG? [y/N] " ANSWER
  if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
    cp "$CONFIG" "$CONFIG.bak"
    UPDATED=$(jq --argjson r "$REC_RATE" --argjson d "$REC_DENIED" --argjson f "$REC_FAILED" '
      .guardrails = (.guardrails // {}) |
      .guardrails.anomaly_thresholds = {
        rate_burst_factor: $r,
        denied_pct: $d,
        failure_pct: $f
      }
    ' "$CONFIG")
    echo "$UPDATED" > "$CONFIG"
    echo "[anomaly-baseline-report] Applied. Backup at $CONFIG.bak."
    echo "[anomaly-baseline-report] Record this change as a 'decisions' row"
    echo "                          (category='tool-matrix-change') for"
    echo "                          auditability per ADR 0004 § Track 4."
  else
    echo "[anomaly-baseline-report] Not applied."
  fi
fi
