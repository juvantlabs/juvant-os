#!/usr/bin/env bash
# hooks/lib/alert.sh
# One security-alert sender for every hook and helper (BUG-087 / BUG-088,
# juvant-os-pm#190 / #191; adopter findings security_audit_log#158 / #159).
#
# Destinations (#191). Every alert destination comes from the gated secrets
# file (hooks/lib/secrets.sh) — the Teams `approvals` webhook, the Telegram bot
# token AND the Telegram chat id. The chat id used to be read from
# .juvant/config.json, which any agent with Write/Edit can change: a redirected
# chat id silently sends the CEO's security alerts elsewhere. It is now a
# secret path (`bash scripts/migrate-secrets.sh` moves it; `set-secret.sh` is
# add-only, so it can't be redirected from inside Claude Code). Until it is
# migrated the accessor falls back to config.json with a deprecation warning;
# `juvant_alert_channel_ready` (the alert_routing.required gate) accepts ONLY
# the gated file, so a sensitive-space op fails closed until it is migrated.
#
# Receipts (#190). Alerts used to be fire-and-forget with no recorded outcome.
# Each send now runs in a detached background subshell (never on the gating
# path) and appends ONE receipt line per channel attempt to
# .juvant/alert-receipts.jsonl (Track 2f-protected):
#   {"ts":…,"alert_id":…,"source":…,"channel":"teams|telegram",
#    "status":"delivered|failed","http":<code>,"curl_rc":<rc>}
# — never the alert text, the webhook URL or the token. `alert_id` links the
# receipt to its audit row: callers embed `alert=<id>` in the row's finding.
# A FAILED attempt also writes a high security_audit_log row
# (category 'alert-delivery-failed', inline, never spooled), so a lost alert is
# visible in the DB too, not only on disk. The Telegram token never appears in
# a curl argv (passed via `--config -`, as in hooks/lib/db.sh).
#
# API:
#   juvant_alert_id                         → a fresh id (prints it)
#   juvant_alert_channel_ready <ch> [cfg]   → 0 if <ch> (teams|telegram) has its
#                                             FULL destination in the gated file
#   juvant_alert_send <msg> <alert_id> <source> [cfg]
#                                           → fire-and-forget to every configured
#                                             channel; returns immediately
# Env: JUVANT_ALERT_RECEIPTS overrides the receipts path (tests);
#      JUVANT_ALERT_SYNC=1 waits for the sends (tests only).

_juvant_alert_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F juvant_secret_get >/dev/null 2>&1 && [[ -f "$_juvant_alert_here/secrets.sh" ]]; then
  # shellcheck disable=SC1091
  . "$_juvant_alert_here/secrets.sh"
fi

_juvant_alert_cfg() { printf '%s' "${1:-${JUVANT_CONFIG:-$_juvant_alert_here/../../.juvant/config.json}}"; }

juvant_alert_receipts_file() {
  printf '%s' "${JUVANT_ALERT_RECEIPTS:-$(dirname "$(_juvant_alert_cfg "${1:-}")")/alert-receipts.jsonl}"
}

juvant_alert_id() {
  printf 'al-%s-%s%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$$" "$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || echo 0)"
}

# Value from the gated secrets file ONLY (no config.json fallback).
_juvant_alert_gated() {
  local sec; sec=$(juvant_secrets_file "$(_juvant_alert_cfg "${2:-}")")
  [[ -f "$sec" ]] || return 0
  jq -r "(${1}) // empty" "$sec" 2>/dev/null || true
}

juvant_alert_channel_ready() {
  local ch="$1" cfg; cfg=$(_juvant_alert_cfg "${2:-}")
  case "$ch" in
    teams)    [[ -n "$(_juvant_alert_gated '.notifications.teams_webhooks.approvals' "$cfg")" ]] ;;
    telegram) [[ -n "$(_juvant_alert_gated '.notifications.telegram_bot_token' "$cfg")" \
                 && -n "$(_juvant_alert_gated '.notifications.telegram_chat_id' "$cfg")" ]] ;;
    *) return 1 ;;
  esac
}

_juvant_alert_receipt() { # <file> <alert_id> <source> <channel> <http> <curl_rc>
  local status="failed"
  [[ "$6" == "0" && "$5" =~ ^2[0-9][0-9]$ ]] && status="delivered"
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg id "$2" --arg src "$3" --arg ch "$4" \
         --arg st "$status" --arg http "$5" --arg rc "$6" \
    '{ts:$ts, alert_id:$id, source:$src, channel:$ch, status:$st, http:($http|tonumber? // 0), curl_rc:($rc|tonumber? // -1)}' \
    >> "$1" 2>/dev/null || true
  chmod 600 "$1" 2>/dev/null || true
  if [[ "$status" == "failed" ]] && declare -F juvant_db_exec >/dev/null 2>&1; then
    local f
    f=$(printf 'alert delivery FAILED: alert=%s channel=%s http=%s curl_rc=%s source=%s (BUG-087)' "$2" "$4" "$5" "$6" "$3" | LC_ALL=C sed "s/'/''/g")
    JUVANT_DB_EXEC_NO_SPOOL=1 juvant_db_exec "INSERT INTO security_audit_log
      (auditor, scope, audit_type, layer, finding, severity, category, status)
      VALUES ('hook:alert', 'company', 'incident', 'agents', '${f}', 'high', 'alert-delivery-failed', 'open');" \
      >/dev/null 2>&1 || true
  fi
}

juvant_alert_send() {
  local msg="$1" id="$2" src="$3" cfg wh tok chat rf card
  cfg=$(_juvant_alert_cfg "${4:-}")
  rf=$(juvant_alert_receipts_file "$cfg")
  wh=$(JUVANT_SECRETS_QUIET=1 juvant_secret_get '.notifications.teams_webhooks.approvals' "$cfg")
  tok=$(JUVANT_SECRETS_QUIET=1 juvant_secret_get '.notifications.telegram_bot_token' "$cfg")
  chat=$(juvant_secret_get '.notifications.telegram_chat_id' "$cfg" 2>/dev/null)
  [[ -n "$wh" || ( -n "$tok" && -n "$chat" ) ]] || return 0
  # ONE detached job sends the channels in turn (never on the gating path);
  # sequential so receipt appends and failure rows never race each other.
  (
    if [[ -n "$wh" ]]; then
      card=$(jq -n --arg msg "$msg" '{type:"AdaptiveCard","$schema":"http://adaptivecards.io/schemas/adaptive-card.json",version:"1.4",body:[{type:"TextBlock",text:$msg,wrap:true}]}')
      http=$(printf 'url = "%s"\n' "$wh" | curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
               -X POST --config - -H "Content-Type: application/json" -d "$card" 2>/dev/null); rc=$?
      _juvant_alert_receipt "$rf" "$id" "$src" teams "${http:-000}" "$rc"
    fi
    if [[ -n "$tok" && -n "$chat" ]]; then
      http=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$tok" | curl -s -o /dev/null -w '%{http_code}' \
               --connect-timeout 5 --max-time 10 -X POST --config - -d "chat_id=${chat}" --data-urlencode "text=${msg}" 2>/dev/null); rc=$?
      _juvant_alert_receipt "$rf" "$id" "$src" telegram "${http:-000}" "$rc"
    fi
  ) </dev/null >/dev/null 2>&1 &
  if [[ "${JUVANT_ALERT_SYNC:-0}" == "1" ]]; then wait "$!" 2>/dev/null || true; fi
  return 0
}
