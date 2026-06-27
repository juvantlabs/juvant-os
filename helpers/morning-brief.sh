#!/usr/bin/env bash
# helpers/morning-brief.sh
# Helper 1 of FEAT-007 (Agent Helpers pattern).
#
# Daily 08:00 brief — sends a structured AdaptiveCard to the Teams ops channel.
# Per ADR 0004 + FEAT-007: pure SQL aggregate + curl, no Claude Code spawn.
#
# Sections:
#   Decisions    — titles + status; rationale snippet for 'proposed' items only
#   Queue        — pending/escalated inbound_queue items
#   System health — calls + ok% + friction count per agent (last 24h)
#   Kill switch  — only when active
#   Scope violations — Type B denials only (scope boundary, authorship, orchestrator)
#                      allow-list friction is folded into System health as 'friction'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

# BUG-027: run-ID stamp + prune log to last 7 runs.
_LOG="$SCRIPT_DIR/../.juvant/logs/morning-brief.log"
if [[ -f "$_LOG" ]]; then
  _total=$(grep -c '^=== RUN ' "$_LOG" 2>/dev/null || true)
  if [[ "${_total:-0}" -gt 7 ]]; then
    _skip=$(( _total - 7 ))
    awk -v skip="$_skip" '/^=== RUN /{n++} n>skip{print}' \
      "$_LOG" > "${_LOG}.tmp" && mv "${_LOG}.tmp" "$_LOG"
  fi
fi
echo "=== RUN $(date -u +%Y%m%dT%H%M%SZ) ===" >> "$_LOG"

# Route DB access through hooks/lib/db.sh: provider-agnostic (turso/azure/
# aws/gcp cloud OR local sqlite), timeout-bounded (BUG-046), reading the
# canonical `.db.url` key with `.turso_url` fallback. The old
# `jq -r '.turso_url'` read FATAL-exited on v0.8 instances whose config
# moved the endpoint under `.db.*`; the prior `command -v turso` PATH guard
# also wrongly FATAL-exited local-sqlite adopters (which need sqlite3, not
# turso). Either way the daily brief never sent.
export JUVANT_CONFIG="$CONFIG"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../hooks/lib/db.sh"
juvant_db_resolve
if [[ -z "${JUVANT_DB_PROVIDER:-}" ]]; then
  echo "[morning-brief] FATAL: no DB provider configured (.db.provider / .db.url / .turso_url absent in $CONFIG)" >&2
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

# ─── Decisions (last 24h) — title | status | rationale snippet (proposed only)
# Single concatenated column (internal '|' delimiter). Strip the CSV
# delimiter (',') and quote ('"') from the free-text rationale so the row
# stays one unquoted CSV field — juvant_db_query_csv is header-normalized,
# so no awk header skip is needed.
DECISIONS_RAW=$(juvant_db_query_csv "
SELECT REPLACE(REPLACE(title || '|' || status || '|' ||
  COALESCE(CASE WHEN status='proposed' THEN substr(rationale,1,100) ELSE '' END,''), ',', ';'), '\"', '')
FROM decisions
WHERE created_at > '$SINCE'
ORDER BY created_at DESC LIMIT 8;
" 2>/dev/null || true)

# ─── Pending queue
QUEUE_RAW=$(juvant_db_query_csv "
SELECT agent_owner, COUNT(*) FROM inbound_queue
WHERE status IN ('pending','escalated')
GROUP BY agent_owner ORDER BY COUNT(*) DESC;
" 2>/dev/null || true)

# ─── System health: calls | ok | denied per agent (last 24h)
HEALTH_RAW=$(juvant_db_query_csv "
SELECT agent || '|' || COUNT(*) || '|' ||
  SUM(CASE WHEN status='success' THEN 1 ELSE 0 END) || '|' ||
  SUM(CASE WHEN status='denied'  THEN 1 ELSE 0 END)
FROM agent_actions_log
WHERE started_at > '$SINCE'
GROUP BY agent ORDER BY COUNT(*) DESC;
" 2>/dev/null || true)

# ─── Kill switch (only if active)
KILLSWITCH_RAW=$(juvant_db_query_csv "
SELECT REPLACE(COALESCE(reason,'-'), ',', ';'), COALESCE(set_at,'-')
FROM agent_kill_switch WHERE id=1 AND active=1;
" 2>/dev/null || true)

# ─── Scope violations: Type B denials only — not allow-list friction
VIOLATIONS_RAW=$(juvant_db_query_csv "
SELECT REPLACE(REPLACE(agent || '|' || deny_reason || '|' || COUNT(*), ',', ';'), '\"', '')
FROM agent_actions_log
WHERE status='denied' AND started_at > '$SINCE'
  AND deny_reason NOT LIKE '%not in agent%allow-list%'
GROUP BY agent, deny_reason ORDER BY COUNT(*) DESC;
" 2>/dev/null || true)

# ─── CSO audit staleness (fail-safe: surface in brief when last full audit is stale)
AUDIT_STALENESS_DAYS=$(juvant_db_query "
SELECT CAST(julianday('now') - julianday(MAX(created_at)) AS INTEGER)
FROM security_audit_log
WHERE audit_type IN ('5-layer','bootstrap_baseline');
" 2>/dev/null | { grep -E '^[0-9]+$' || true; } | tail -1 | tr -d ' ' || true)
AUDIT_STALENESS_DAYS="${AUDIT_STALENESS_DAYS:-99}"

# ─── Helpers

trim() { echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

shorten_violation() {
  local r="$1"
  if   [[ "$r" == *"SCOPE BOUNDARY"* ]];       then echo "Scope boundary"
  elif [[ "$r" == *"AUTHORSHIP VIOLATION"* ]];  then echo "Authorship §4d"
  elif [[ "$r" == *"ORCHESTRATOR BOUNDARY"* ]]; then echo "Orchestrator §9"
  else echo "${r:0:55}"
  fi
}

# Reads 2-column CSV (juvant_db_query_csv, header-normalized), emits a JSON
# FactSet element.
build_facts() {
  local raw="$1" facts="" f1 f2 rest
  while IFS=',' read -r f1 f2 rest; do
    [[ -z "$f1" ]] && continue
    facts+=$(jq -n --arg t "$(trim "$f1")" --arg v "$(trim "$f2")" \
      '{"title":$t,"value":$v}'),
  done <<< "$raw"
  facts="${facts%,}"
  echo "{\"type\":\"FactSet\",\"facts\":[$facts]}"
}

# ─── Build AdaptiveCard body elements

BODY_ELEMENTS="[]"

# Header
BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
  --arg company "$COMPANY" --arg date "$DATE_DISPLAY" \
  '. + [
    {"type":"TextBlock","text":"Morning Brief","size":"Medium","weight":"Bolder","color":"Accent"},
    {"type":"TextBlock","text":($company + " · " + $date),"size":"Small","isSubtle":true,"spacing":"None"}
  ]')

# ─── Decisions section
if [[ -z "$DECISIONS_RAW" ]]; then
  BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
    '. + [
      {"type":"TextBlock","text":"Decisions","size":"Small","weight":"Bolder","separator":true,"spacing":"Medium"},
      {"type":"TextBlock","text":"No decisions in the last 24h","size":"Small","isSubtle":true}
    ]')
else
  _facts=""
  while IFS='|' read -r _title _status _rationale; do
    _title=$(trim "$_title")
    _status=$(trim "$_status")
    _rationale=$(trim "$_rationale")
    [[ -z "$_title" ]] && continue
    if [[ "$_status" == "proposed" && -n "$_rationale" ]]; then
      _value="proposed — ${_rationale}…"
    else
      _value="$_status"
    fi
    _facts+=$(jq -n --arg t "$_title" --arg v "$_value" '{"title":$t,"value":$v}'),
  done <<< "$DECISIONS_RAW"
  _facts="${_facts%,}"
  BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
    --argjson facts "{\"type\":\"FactSet\",\"facts\":[$_facts]}" \
    '. + [
      {"type":"TextBlock","text":"Decisions","size":"Small","weight":"Bolder","separator":true,"spacing":"Medium"},
      $facts
    ]')
fi

# ─── Queue section
if [[ -z "$QUEUE_RAW" ]]; then
  BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
    '. + [
      {"type":"TextBlock","text":"Queue","size":"Small","weight":"Bolder","separator":true,"spacing":"Medium"},
      {"type":"TextBlock","text":"No pending items","size":"Small","isSubtle":true}
    ]')
else
  FACTS=$(build_facts "$QUEUE_RAW")
  BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
    --argjson facts "$FACTS" \
    '. + [
      {"type":"TextBlock","text":"Queue","size":"Small","weight":"Bolder","separator":true,"spacing":"Medium"},
      $facts
    ]')
fi

# ─── System health section
if [[ -z "$HEALTH_RAW" ]]; then
  BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
    '. + [
      {"type":"TextBlock","text":"System health","size":"Small","weight":"Bolder","separator":true,"spacing":"Medium"},
      {"type":"TextBlock","text":"No agent calls in the last 24h","size":"Small","isSubtle":true}
    ]')
else
  _facts=""
  while IFS='|' read -r _agent _calls _ok _denied; do
    _agent=$(trim "$_agent")
    _calls=$(trim "$_calls" | tr -d ' ')
    _ok=$(trim "$_ok" | tr -d ' ')
    _denied=$(trim "$_denied" | tr -d ' ')
    [[ -z "$_agent" ]] && continue
    [[ ! "$_calls" =~ ^[0-9]+$ || "$_calls" -eq 0 ]] && continue
    [[ ! "$_ok"    =~ ^[0-9]+$ ]] && _ok=0
    [[ ! "$_denied" =~ ^[0-9]+$ ]] && _denied=0
    _ok_pct=$(( _ok * 100 / _calls ))
    _value="${_calls} calls · ${_ok_pct}% ok"
    if [[ "$_denied" -gt 0 ]]; then
      _value="${_value} · ${_denied} friction"
    fi
    if [[ "$_ok_pct" -lt 85 ]]; then
      _value="⚠️ ${_value}"
    fi
    _facts+=$(jq -n --arg t "$_agent" --arg v "$_value" '{"title":$t,"value":$v}'),
  done <<< "$HEALTH_RAW"
  _facts="${_facts%,}"
  BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
    --argjson facts "{\"type\":\"FactSet\",\"facts\":[$_facts]}" \
    '. + [
      {"type":"TextBlock","text":"System health","size":"Small","weight":"Bolder","separator":true,"spacing":"Medium"},
      $facts
    ]')
fi

# ─── Kill switch (only when active)
if [[ -n "$KILLSWITCH_RAW" ]]; then
  IFS=',' read -r reason set_at _rest <<< "$KILLSWITCH_RAW"
  reason=$(echo "$reason" | xargs)
  set_at=$(echo "$set_at" | xargs)
  BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
    --arg reason "$reason" --arg set_at "$set_at" \
    '. + [
      {"type":"TextBlock","text":"🔴 Kill switch ACTIVE","size":"Small","weight":"Bolder","color":"Attention","separator":true,"spacing":"Medium"},
      {"type":"FactSet","facts":[{"title":"Reason","value":$reason},{"title":"Set at","value":$set_at}]}
    ]')
fi

# ─── CSO audit staleness warning (only when >7d stale)
if [[ "$AUDIT_STALENESS_DAYS" -gt 7 ]]; then
  BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
    --arg days "$AUDIT_STALENESS_DAYS" \
    '. + [
      {"type":"TextBlock","text":"Security audit overdue","size":"Small","weight":"Bolder","color":"Attention","separator":true,"spacing":"Medium"},
      {"type":"FactSet","facts":[
        {"title":"Days since last 5-layer audit","value":($days + "d (threshold: 7d)")},
        {"title":"Action","value":"Dispatch CSO audit via CoS → CSO"}
      ]}
    ]')
fi

# ─── Scope violations (only when Type B denials exist)
if [[ -n "$VIOLATIONS_RAW" ]]; then
  _facts=""
  while IFS='|' read -r _agent _reason _cnt; do
    _agent=$(trim "$_agent")
    _cnt=$(trim "$_cnt" | tr -d ' ')
    [[ -z "$_agent" ]] && continue
    _label=$(shorten_violation "$(trim "$_reason")")
    _facts+=$(jq -n --arg t "${_agent}: ${_label}" --arg v "${_cnt}×" \
      '{"title":$t,"value":$v}'),
  done <<< "$VIOLATIONS_RAW"
  _facts="${_facts%,}"
  BODY_ELEMENTS=$(echo "$BODY_ELEMENTS" | jq \
    --argjson facts "{\"type\":\"FactSet\",\"facts\":[$_facts]}" \
    '. + [
      {"type":"TextBlock","text":"⚠️ Scope violations","size":"Small","weight":"Bolder","color":"Warning","separator":true,"spacing":"Medium"},
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
