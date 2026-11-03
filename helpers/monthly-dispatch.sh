#!/usr/bin/env bash
# helpers/monthly-dispatch.sh
# FEAT-067 (juvantlabs/juvant-os-pm#203) — monthly scheduled dispatch for the
# protocols the agent templates run "on the first business day of each month":
#
#   --job clo-disclosure-audit   CLO Monthly Disclosure Audit      (07:45)
#   --job chro-ranking           CHRO monthly Agent Ranking         (09:00)
#
# Enqueue-only. A helper cannot spawn a subagent (the Task tool is main-thread
# only), so on the first business day of the month this writes ONE `messages`
# row for CoS (type 'scheduled-dispatch', notify_ceo=1); at session start CoS
# dispatches the agent with its protocol prompt and marks the row read.
#
# Scheduled on days 1–4 of each month (launchd StartCalendarInterval array /
# cron `1-4`): the first business day is always among them unless the month
# opens with a long holiday run, a missed launchd slot is coalesced on wake,
# and the gates below make every other run a no-op.
#
# Gates (each a clean exit 0):
#   1. business day — today is Mon–Fri and not a holiday;
#   2. first one   — no earlier day this month was a business day;
#   3. idempotent  — no messages row with ref_id '<ref>-YYYY-MM' exists, and no
#                    decisions row of the job's category was created this month
#                    (the protocol already ran, dispatched by hand).
#
# Holidays (no country default — OSS genericity): `.juvant/config.json`
# `scheduling.holidays`, an array of "MM-DD" (every year) and/or "YYYY-MM-DD"
# (one date — moveable feasts such as Easter Monday). JUVANT_HOLIDAYS="MM-DD,
# YYYY-MM-DD,…" overrides the config. Empty → weekends only.
#
# Usage:
#   bash helpers/monthly-dispatch.sh --job clo-disclosure-audit [--dry-run]
#   JUVANT_TODAY=YYYY-MM-DD   evaluate as of that date (tests / back-fill)
#
# Exit: 0 = not due / already done / enqueued; 1 = DB unavailable or write
# failed (the next scheduled day retries); 2 = usage error.

set -euo pipefail

# launchd / cron provide a minimal PATH — APPEND Homebrew dirs (mirrors
# helpers/cso-weekly-audit.sh) without shadowing a test-shimmed CLI.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${JUVANT_CONFIG:-$SCRIPT_DIR/../.juvant/config.json}"

JOB=""; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --job) JOB="${2:-}"; shift 2 ;;
    --job=*) JOB="${1#--job=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "[monthly-dispatch] unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$JOB" in
  clo-disclosure-audit)
    AGENT="clo"; REF_PREFIX="disclosure-audit"; DECISION_CATEGORY="disclosure-audit"
    TITLE="Monthly Disclosure Audit"
    PROMPT_REF="clo.md § Monthly Disclosure Audit"
    EXTRA=" Read-only on existing policies." ;;
  chro-ranking)
    AGENT="chro"; REF_PREFIX="monthly-ranking"; DECISION_CATEGORY="monthly-ranking"
    TITLE="Monthly Agent Ranking"
    PROMPT_REF="chro.md § Agent Ranking Protocol"
    EXTRA="" ;;
  *) echo "[monthly-dispatch] usage: $0 --job clo-disclosure-audit|chro-ranking [--dry-run]" >&2; exit 2 ;;
esac
TAG="[monthly-dispatch:$JOB]"
AGENT_UC=$(printf '%s' "$AGENT" | tr '[:lower:]' '[:upper:]')   # bash 3.2: no ${x^^}

# BUG-027: run-ID stamp + prune the log to the last 12 runs.
_LOG="$SCRIPT_DIR/../.juvant/logs/${JOB}.log"
if [[ -f "$_LOG" ]]; then
  _total=$(grep -c '^=== RUN ' "$_LOG" 2>/dev/null || true)
  if [[ "${_total:-0}" -gt 12 ]]; then
    _skip=$(( _total - 12 ))
    awk -v skip="$_skip" '/^=== RUN /{n++} n>skip{print}' \
      "$_LOG" > "${_LOG}.tmp" && cat "${_LOG}.tmp" > "$_LOG" && rm -f "${_LOG}.tmp"
  fi
fi
if [[ -d "$(dirname "$_LOG")" ]]; then
  echo "=== RUN $(date -u +%Y%m%dT%H%M%SZ) ===" >> "$_LOG"
fi

export JUVANT_CONFIG="$CONFIG"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../hooks/lib/db.sh"
juvant_db_resolve
if [[ -z "${JUVANT_DB_PROVIDER:-}" ]]; then
  echo "$TAG FATAL: no DB provider configured — set .db.provider (or legacy .turso_url) in $CONFIG" >&2
  exit 1
fi
if ! juvant_db_cli_ok; then
  echo "$TAG FATAL: the '$JUVANT_DB_PROVIDER' DB CLI ($(juvant_db_required_cli)) is not on PATH — re-run helpers/install-schedules.sh so the schedule's PATH includes it." >&2
  exit 1
fi

# ── Date arithmetic (portable: no GNU/BSD `date` differences) ───────────────
TODAY="${JUVANT_TODAY:-$(date +%Y-%m-%d)}"
if [[ ! "$TODAY" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
  echo "$TAG usage: JUVANT_TODAY must be YYYY-MM-DD (got '$TODAY')" >&2; exit 2
fi
Y=$((10#${BASH_REMATCH[1]})); M=$((10#${BASH_REMATCH[2]})); D=$((10#${BASH_REMATCH[3]}))
YM=$(printf '%04d-%02d' "$Y" "$M")

# Day of week, 0 = Sunday (Sakamoto).
_dow() {
  local y="$1" m="$2" d="$3"
  local -a t=(0 3 2 5 0 3 5 1 4 6 2 4)
  (( m < 3 )) && y=$((y - 1))
  echo $(( (y + y / 4 - y / 100 + y / 400 + t[m - 1] + d) % 7 ))
}

HOLIDAYS="${JUVANT_HOLIDAYS-}"
if [[ -z "${JUVANT_HOLIDAYS+x}" && -f "$CONFIG" ]]; then
  HOLIDAYS=$(jq -r '(.scheduling.holidays // []) | join(",")' "$CONFIG" 2>/dev/null || echo "")
fi
HOLIDAYS=",${HOLIDAYS// /},"

_is_business_day() {   # <day-of-month>
  local d="$1" md ymd w
  md=$(printf '%02d-%02d' "$M" "$d"); ymd="${YM}-$(printf '%02d' "$d")"
  w=$(_dow "$Y" "$M" "$d")
  [[ "$w" -ge 1 && "$w" -le 5 ]] || return 1
  [[ "$HOLIDAYS" == *",$md,"* || "$HOLIDAYS" == *",$ymd,"* ]] && return 1
  return 0
}

if ! _is_business_day "$D"; then
  echo "$TAG $TODAY is not a business day — nothing to do"
  exit 0
fi
for (( _d = 1; _d < D; _d++ )); do
  if _is_business_day "$_d"; then
    echo "$TAG $TODAY is not the first business day of $YM (that was day $_d) — nothing to do"
    exit 0
  fi
done

# ── Idempotency ──────────────────────────────────────────────────────────────
REF_ID="${REF_PREFIX}-${YM}"
_count() {   # <sql> → integer on stdout, or nothing when the read failed
  juvant_db_query "$1" 2>/dev/null | { grep -E '^[0-9]+$' || true; } | tail -1 | tr -d '[:space:]'
}
# `|| …`: under set -e a failed read must reach the WARN below, not exit silently.
MSG_N=$(_count "SELECT COUNT(*) FROM messages WHERE ref_id='${REF_ID}';") || MSG_N=""
DEC_N=$(_count "SELECT COUNT(*) FROM decisions WHERE category='${DECISION_CATEGORY}' AND created_at >= '${YM}-01';") || DEC_N=""
if [[ -z "$MSG_N" || -z "$DEC_N" ]]; then
  echo "$TAG WARN: cannot read messages/decisions to check whether $REF_ID is already queued — not enqueuing; the next scheduled day retries" >&2
  exit 1
fi
if [[ "$MSG_N" -gt 0 ]]; then
  echo "$TAG $REF_ID already queued — nothing to do"
  exit 0
fi
if [[ "$DEC_N" -gt 0 ]]; then
  echo "$TAG a '$DECISION_CATEGORY' decision already exists for $YM — the protocol ran; nothing to do"
  exit 0
fi

CONTENT="${TITLE} due for ${YM}: dispatch the ${AGENT_UC} with the ${TITLE} prompt (${PROMPT_REF}).${EXTRA} Mark this message read once dispatched."

if [[ "$DRY_RUN" == 1 ]]; then
  echo "$TAG DRY-RUN — $TODAY is the first business day of $YM: would enqueue messages row ref_id=$REF_ID for cos: $CONTENT"
  exit 0
fi

# ── Enqueue (never spooled: a spooled messages row of this shape would be
# quarantined by the drain allowlist, and the next scheduled day retries) ────
_CONTENT_SQL="${CONTENT//\'/\'\'}"
if ! JUVANT_DB_EXEC_NO_SPOOL=1 juvant_db_exec "INSERT INTO messages (from_agent, to_agent, type, content, priority, notify_ceo, ref_id) VALUES ('monthly-dispatch', 'cos', 'scheduled-dispatch', '${_CONTENT_SQL}', 'high', 1, '${REF_ID}');"; then
  echo "$TAG WARN: failed to write the messages row for $REF_ID — the next scheduled day retries" >&2
  exit 1
fi
echo "$TAG ENQUEUED — messages row ref_id=$REF_ID for cos (notify_ceo=1)"

# ── Optional Teams notification (as helpers/cso-weekly-audit.sh) ────────────
TEAMS_URL=$(juvant_secret_get '.notifications.teams_webhooks.ops' "$CONFIG" 2>/dev/null || true)
if [[ -z "$TEAMS_URL" ]]; then
  echo "$TAG notifications.teams_webhooks.ops not configured — no Teams notice (the messages row is the dispatch)"
  exit 0
fi
COMPANY=$(jq -r '.company.name // .company_name // "Juvant OS"' "$CONFIG" 2>/dev/null || echo "Juvant OS")
CARD=$(jq -n --arg title "$TITLE" --arg company "$COMPANY" --arg ym "$YM" --arg agent "${AGENT_UC}" '{
  "type": "AdaptiveCard",
  "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
  "version": "1.4",
  "body": [
    { "type": "TextBlock", "text": ($title + " due"), "size": "Medium", "weight": "Bolder" },
    { "type": "TextBlock", "text": ($company + " · " + $ym), "size": "Small", "isSubtle": true, "spacing": "None" },
    { "type": "TextBlock", "wrap": true, "spacing": "Medium",
      "text": ("Queued for CoS: at your next Claude Code session CoS dispatches the " + $agent + " with the " + $title + " prompt.") }
  ]
}')
curl -s -X POST "$TEAMS_URL" -H "Content-Type: application/json" -d "$CARD" -o /dev/null 2>&1 \
  || echo "$TAG WARN: Teams delivery failed (the messages row is already queued)" >&2
exit 0
