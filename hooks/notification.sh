#!/usr/bin/env bash
# hooks/notification.sh
# Claude Code hook: Notification
# Called when Claude Code needs user input or is waiting for a response.
# Pushes notification to Telegram and Teams webhook.
#
# stdin: JSON event with notification message from Claude Code
# Format: {"type":"notification","message":"...","session_id":"..."}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

# Read notification event from stdin
EVENT_JSON=""
if [ ! -t 0 ]; then
  EVENT_JSON=$(cat -)
fi

# Load Telegram credentials
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  if [[ -f "$CONFIG" ]]; then
    TELEGRAM_BOT_TOKEN=$(jq -r '.notifications.telegram_bot_token // ""' "$CONFIG" 2>/dev/null || echo "")
    TELEGRAM_CHAT_ID=$(jq -r '.notifications.telegram_chat_id // ""' "$CONFIG" 2>/dev/null || echo "")
  fi
fi

# Resolve Teams webhook URL by channel key.
# Channel: JUVANT_NOTIFY_CHANNEL (default "approvals").
# Project routing: JUVANT_NOTIFY_PROJECT=<slug> checks
#   .projects.<slug>.notifications.teams_webhooks[$ch] first,
#   then falls back to company-scope .notifications.teams_webhooks[$ch].
NOTIFY_CHANNEL="${JUVANT_NOTIFY_CHANNEL:-approvals}"
NOTIFY_PROJECT="${JUVANT_NOTIFY_PROJECT:-}"
TEAMS_WEBHOOK_URL=""
if [[ -f "$CONFIG" ]] && command -v jq &>/dev/null; then
  if [[ -n "$NOTIFY_PROJECT" ]]; then
    TEAMS_WEBHOOK_URL=$(jq -r --arg slug "$NOTIFY_PROJECT" --arg ch "$NOTIFY_CHANNEL" \
      '.projects[$slug].notifications.teams_webhooks[$ch] // ""' "$CONFIG" 2>/dev/null || echo "")
  fi
  if [[ -z "$TEAMS_WEBHOOK_URL" ]]; then
    TEAMS_WEBHOOK_URL=$(jq -r --arg ch "$NOTIFY_CHANNEL" \
      '.notifications.teams_webhooks[$ch] // ""' "$CONFIG" 2>/dev/null || echo "")
  fi
fi

# Parse message from event JSON
ROLE="${AGENT_ROLE:-}"
MESSAGE=""
if [[ -n "$EVENT_JSON" ]] && command -v jq &>/dev/null; then
  MESSAGE=$(echo "$EVENT_JSON" | jq -r '.message // ""' 2>/dev/null || echo "")
fi

if [[ -z "$MESSAGE" ]]; then
  MESSAGE="[Juvant OS] Agent ${ROLE:-cos} is waiting for your input."
fi

# Only prefix with role when explicitly set — helpers leave AGENT_ROLE unset
if [[ -n "$ROLE" ]]; then
  ROLE_UPPER=$(echo "$ROLE" | tr '[:lower:]' '[:upper:]')
  FULL_MESSAGE="[$ROLE_UPPER] $MESSAGE"
else
  FULL_MESSAGE="$MESSAGE"
fi

# Push to Telegram (skipped when JUVANT_TEAMS_ONLY=1 — e.g. long markdown briefs)
if [[ "${JUVANT_TEAMS_ONLY:-0}" != "1" ]] && [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
  # BUG-048: --connect-timeout/--max-time bound the call; without them a
  # stalled connection hangs the hook (curl has no overall timeout by default).
  curl -s --connect-timeout 5 --max-time 10 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${FULL_MESSAGE}" \
    -o /dev/null 2>&1 || echo "[notification] WARN: Telegram push failed." >&2
fi

# Push to Teams webhook (AdaptiveCard format — Power Automate "Post card" action)
if [[ -n "${TEAMS_WEBHOOK_URL:-}" ]]; then
  TEAMS_PAYLOAD=$(jq -n --arg msg "$FULL_MESSAGE" '{
    "type": "AdaptiveCard",
    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
    "version": "1.4",
    "body": [
      {
        "type": "TextBlock",
        "text": $msg,
        "wrap": true
      }
    ]
  }')
  curl -s --connect-timeout 5 --max-time 10 -X POST \
    "$TEAMS_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$TEAMS_PAYLOAD" \
    -o /dev/null 2>&1 || echo "[notification] WARN: Teams push failed." >&2
fi

exit 0
