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
if [ -p /dev/stdin ]; then
  EVENT_JSON=$(cat -)
fi

# Load Telegram credentials
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  if [[ -f "$CONFIG" ]]; then
    TELEGRAM_BOT_TOKEN=$(jq -r '.telegram_bot_token // ""' "$CONFIG" 2>/dev/null || echo "")
    TELEGRAM_CHAT_ID=$(jq -r '.telegram_chat_id // ""' "$CONFIG" 2>/dev/null || echo "")
  fi
fi

# Resolve Teams webhook URL by channel key.
# Channel selection (in order): JUVANT_NOTIFY_CHANNEL env var -> default "approvals".
# config.json schema:
#   teams_webhooks: { approvals: <url>, ops: <url>, system: <url>, alerts: <url> }
NOTIFY_CHANNEL="${JUVANT_NOTIFY_CHANNEL:-approvals}"
TEAMS_WEBHOOK_URL=""
if [[ -f "$CONFIG" ]] && command -v jq &>/dev/null; then
  TEAMS_WEBHOOK_URL=$(jq -r --arg ch "$NOTIFY_CHANNEL" '.teams_webhooks[$ch] // ""' "$CONFIG" 2>/dev/null || echo "")
fi

# Parse message from event JSON
MESSAGE=""
ROLE="${AGENT_ROLE:-cos}"
if [[ -n "$EVENT_JSON" ]] && command -v jq &>/dev/null; then
  MESSAGE=$(echo "$EVENT_JSON" | jq -r '.message // ""' 2>/dev/null || echo "")
fi

if [[ -z "$MESSAGE" ]]; then
  MESSAGE="[Juvant OS] Agent $ROLE is waiting for your input."
fi

# Portable uppercase — bash 3.2 (macOS default) doesn't support ${var^^}
ROLE_UPPER=$(echo "$ROLE" | tr '[:lower:]' '[:upper:]')
FULL_MESSAGE="[$ROLE_UPPER] $MESSAGE"

# Push to Telegram
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
  curl -s -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${FULL_MESSAGE}" \
    -o /dev/null 2>&1 || echo "[notification] WARN: Telegram push failed." >&2
fi

# Push to Teams webhook
if [[ -n "${TEAMS_WEBHOOK_URL:-}" ]]; then
  TEAMS_PAYLOAD="{\"text\": \"${FULL_MESSAGE}\"}"
  curl -s -X POST \
    "$TEAMS_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$TEAMS_PAYLOAD" \
    -o /dev/null 2>&1 || echo "[notification] WARN: Teams push failed." >&2
fi

exit 0
