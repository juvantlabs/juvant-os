#!/usr/bin/env bash
# helpers/morning-brief.sh
# Helper 1 of FEAT-007 (Agent Helpers pattern).
#
# Daily 08:00 brief — sends a structured AdaptiveCard to the Teams ops channel.
# Per ADR 0004 + FEAT-007: pure SQL aggregate + curl, no Claude Code spawn.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

TURSO_URL=$(jq -r '.turso_url // ""' "$CONFIG" 2>/dev/null || echo "")
if [[ -z "$TURSO_URL" ]]; then
  echo "[morning-brief] FATAL: turso_url missing from $CONFIG" >&2
  exit 1
fi

TEAMS_URL=$(jq -r '.notifications.teams_webhooks.ops // ""' "$CONFIG" 2>/dev/null || echo "")
if [[ -z "$TEAMS_URL" ]]; then
  echo "[morning-brief] WARN: notifications.teams_webhooks.ops not configured — skipping" >&2
  exit 0
fi

COMPANY=$(jq -r '.company.name // .company_name // "Juvant OS"' "$CONFIG" 2>/dev/null || echo "Juvant OS")
DATE_DISPLAY=$(date "+%a %d %b %Y")
SINCE=$(date -u -v-1d +"%Y-%m-%d %H:%M:%S" 2>/dev/null \
        || date -u -d "1 day ago" +"%Y-%m-%d %H:%M:%S")

# ─── Decisions (last 24h)
DECISIONS_RAW=$(turso db shell "$TURSO_URL" "
SELECT category, COUNT(*) FROM decisions
WHERE created_at > '$SINCE'
GROUP BY category ORDER BY COUNT(*) DESC;
" 2>/dev/null | awk 'NR > 1' || true)

# ─── Pending queue
QUEUE_RAW=$(turso db shell "$TURSO_URL" "
SELECT agent_owner, COUNT(*) FROM inbound_queue
WHERE status IN ('pending','escalated')
GROUP BY agent_owner ORDER BY COUNT(*) DESC;
" 2>/dev/null | awk 'NR > 1' || true)

# ─── Agent activity (last 24h)
ACTIVITY_RAW=$(turso db shell "$TURSO_URL" "
SELECT agent, COUNT(*) AS calls,
  SUM(CASE WHEN status='success' THEN 1 ELSE 0 END) AS ok,
  SUM(CASE WHEN status='denied'  THEN 1 ELSE 0 END) AS denied
FROM agent_actions_log
WHERE started_at > '$SINCE'
GROUP BY agent ORDER BY calls DESC;
" 2>/dev/null | awk 'NR > 1' || true)

# ─── Build AdaptiveCard body elements

build_facts() {
  # Reads raw turso output (space-separated rows), emits a JSON FactSet element
  local raw="$1" title_col="$2" value_col="$3"
  local facts=""
  while read -r f1 f2 rest; do
    [[ -z "$f1" ]] && continue
    local t v
    t=$(echo "$f1" | xargs)
    v=$(echo "$f2" | xargs)
    facts+=$(jq -n --arg t "$t" --arg v "$v" '{"title":$t,"value":$v}')","
  done <<< "$raw"
  facts="${facts%,}"
  echo "{\"type\":\"FactSet\",\"facts\":[$facts]}"
}

BODY_ELEMENTS="[]"

# Header
BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
  --arg company "$COMPANY" --arg date "$DATE_DISPLAY" \
  '. + [
    {"type":"TextBlock","text":"Morning Brief","size":"Medium","weight":"Bolder","color":"Accent"},
    {"type":"TextBlock","text":($company + " · " + $date),"size":"Small","isSubtle":true,"spacing":"None"}
  ]')

# Decisions section
if [[ -z "$DECISIONS_RAW" ]]; then
  BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
    '. + [
      {"type":"TextBlock","text":"Decisions","size":"Small","weight":"Bolder","separator":true,"spacing":"Medium"},
      {"type":"TextBlock","text":"No decisions in the last 24h","size":"Small","isSubtle":true}
    ]')
else
  FACTS=$(build_facts "$DECISIONS_RAW" 1 2)
  BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
    --argjson facts "$FACTS" \
    '. + [
      {"type":"TextBlock","text":"Decisions","size":"Small","weight":"Bolder","separator":true,"spacing":"Medium"},
      $facts
    ]')
fi

# Queue section
if [[ -z "$QUEUE_RAW" ]]; then
  BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
    '. + [
      {"type":"TextBlock","text":"Queue","size":"Small","weight":"Bolder","separator":true,"spacing":"Medium"},
      {"type":"TextBlock","text":"No pending items","size":"Small","isSubtle":true}
    ]')
else
  FACTS=$(build_facts "$QUEUE_RAW" 1 2)
  BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
    --argjson facts "$FACTS" \
    '. + [
      {"type":"TextBlock","text":"Queue","size":"Small","weight":"Bolder","separator":true,"spacing":"Medium"},
      $facts
    ]')
fi

# Activity section
if [[ -z "$ACTIVITY_RAW" ]]; then
  BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
    '. + [
      {"type":"TextBlock","text":"Agent activity","size":"Small","weight":"Bolder","separator":true,"spacing":"Medium"},
      {"type":"TextBlock","text":"No agent calls in the last 24h","size":"Small","isSubtle":true}
    ]')
else
  FACTS=$(build_facts "$ACTIVITY_RAW" 1 2)
  BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
    --argjson facts "$FACTS" \
    '. + [
      {"type":"TextBlock","text":"Agent activity","size":"Small","weight":"Bolder","separator":true,"spacing":"Medium"},
      $facts
    ]')
fi

# ─── Assemble and POST AdaptiveCard
CARD=$(jq -n --argjson body "$BODY_ELEMENTS" '{
  "type": "AdaptiveCard",
  "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
  "version": "1.4",
  "body": $body
}')

curl -s -X POST "$TEAMS_URL" \
  -H "Content-Type: application/json" \
  -d "$CARD" \
  -o /dev/null 2>&1 || echo "[morning-brief] WARN: Teams delivery failed" >&2

echo "[morning-brief] OK — sent brief for $DATE_DISPLAY"
exit 0
