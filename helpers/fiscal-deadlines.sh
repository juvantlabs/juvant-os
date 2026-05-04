#!/usr/bin/env bash
# helpers/fiscal-deadlines.sh
# Helper 3 of FEAT-007 (Agent Helpers pattern, handbook ADR 0004
# implications): scheduled fiscal-deadline scanner.
#
# Per FEAT-007: scheduled scripts (NOT agent sessions) that fetch
# data, classify by rules, populate Turso queues, notify on
# threshold. Agents drain queues only during interactive sessions.
# Single-consumer guarantees no concurrency bugs.
#
# Schedule: daily 07:45 (just before Morning Brief at 08:00, so
# the brief picks up imminent-deadline alerts in its assembly).
#
# Behavior:
#   - Reads scripts/deadlines.json (per-jurisdiction fiscal calendar
#     shipped with the template; adopters replace at company init).
#   - For each deadline: compute days_until. If
#     0 <= days_until <= deadline.days_notice, mark as "imminent".
#   - On any imminent deadline: assemble a single bundled
#     notification → notification.sh → Telegram + Teams ops channel.
#   - Idempotent within a single day's run (the helper runs once
#     daily; running it twice in a day = duplicate alert).
#   - NO Turso writes; deadlines.json is the truth source. CLO / CFO
#     re-read at session-start.
#
# Scope: this helper does NOT compute "is this deadline already done".
# A deadline that's been satisfied by the CEO manually still appears
# until its date passes. That's an acceptable v1 simplification —
# tracking completion would require a parallel state table that
# adopters edit by hand. Defer to v1.1+.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEADLINES_FILE="$SCRIPT_DIR/../scripts/deadlines.json"
NOTIFY="$SCRIPT_DIR/../hooks/notification.sh"

if [[ ! -f "$DEADLINES_FILE" ]]; then
  echo "[fiscal-deadlines] WARN: $DEADLINES_FILE not found; skipping" >&2
  exit 0
fi

TODAY=$(date -u +%Y-%m-%d)

# Iterate deadlines, compute days_until, filter to imminent.
# Output: tab-separated rows of (id, name, date, owner, days_until, days_notice)
IMMINENT=$(jq -r --arg today "$TODAY" '
  .deadlines[] |
  . as $d |
  (((($d.date | strptime("%Y-%m-%d") | mktime) - ($today | strptime("%Y-%m-%d") | mktime)) / 86400) | floor) as $days_until |
  select($days_until >= 0 and $days_until <= $d.days_notice) |
  [$d.id, $d.name, $d.date, $d.owner, $days_until, $d.days_notice] |
  @tsv
' "$DEADLINES_FILE" 2>/dev/null || true)

if [[ -z "$IMMINENT" ]]; then
  echo "[fiscal-deadlines] OK — no imminent deadlines today"
  exit 0
fi

# Assemble markdown bundle
MSG="📅 *Fiscal deadlines imminent*"$'\n\n'
while IFS=$'\t' read -r id name date owner days_until _days_notice; do
  [[ -z "$id" ]] && continue
  if [[ "$days_until" -le 7 ]]; then
    URGENCY="🔴"
  elif [[ "$days_until" -le 30 ]]; then
    URGENCY="🟡"
  else
    URGENCY="🟢"
  fi
  MSG+="${URGENCY} *${date}* (in ${days_until}d, owner: ${owner}) — ${name}"$'\n'
done <<< "$IMMINENT"

# Bundle into single notification
JSON_MSG=$(echo -n "$MSG" | jq -R -s '.')
JUVANT_NOTIFY_CHANNEL=ops \
  bash "$NOTIFY" <<< "{\"message\":$JSON_MSG}" \
  || echo "[fiscal-deadlines] WARN: notification dispatch failed" >&2

echo "[fiscal-deadlines] OK — alerted on $(echo "$IMMINENT" | wc -l | tr -d ' ') imminent deadline(s)"
exit 0
