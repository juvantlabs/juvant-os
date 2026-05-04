#!/usr/bin/env bash
# helpers/agent-killswitch.sh
# CEO control surface for the agent_kill_switch table.
# Per handbook ADR 0004 Track 4.
#
# Usage:
#   agent-killswitch.sh on "<reason>" [agent-role…]
#       Activate. Affects all agents if no roles specified, else
#       only the listed roles. Reason is logged + surfaced in the
#       deny message to any blocked session.
#   agent-killswitch.sh off
#       Clear the kill switch.
#   agent-killswitch.sh status
#       Print current state.
#
# Examples:
#   agent-killswitch.sh on "anomaly: CFO doing 50 calls/min"
#   agent-killswitch.sh on "draft review pending" cfo cmo
#   agent-killswitch.sh status
#   agent-killswitch.sh off
#
# Auth: this script is for the CEO. v1.0 has no per-user gating —
# anyone with shell access to this directory + Turso write
# credentials can flip the switch. v1.1+ adds inbound Telegram
# bot /stop command for off-host CEO control.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

if [[ ! -f "$CONFIG" ]]; then
  echo "[killswitch] FATAL: $CONFIG missing" >&2
  exit 1
fi

TURSO_URL=$(jq -r '.turso_url // ""' "$CONFIG")
if [[ -z "$TURSO_URL" ]]; then
  echo "[killswitch] FATAL: turso_url missing from $CONFIG" >&2
  exit 1
fi

CMD="${1:-}"
shift || true

case "$CMD" in
  on)
    REASON="${1:-no reason given}"
    shift || true
    AFFECTED_JSON="NULL"
    if [[ $# -gt 0 ]]; then
      # Build JSON array from remaining args
      AFFECTED_ARR=$(printf '%s\n' "$@" | jq -R -c -s 'split("\n") | map(select(. != ""))')
      AFFECTED_ESC="${AFFECTED_ARR//\'/\'\'}"
      AFFECTED_JSON="'$AFFECTED_ESC'"
    fi
    REASON_ESC="${REASON//\'/\'\'}"
    NOW=$(date -u +"%Y-%m-%d %H:%M:%S")
    turso db shell "$TURSO_URL" "UPDATE agent_kill_switch
      SET active=1,
          set_by='ceo',
          set_at='$NOW',
          reason='$REASON_ESC',
          affected_agents=$AFFECTED_JSON
      WHERE id=1;"
    echo "[killswitch] ON — reason: $REASON"
    if [[ "$AFFECTED_JSON" == "NULL" ]]; then
      echo "[killswitch]    affecting: ALL agents"
    else
      echo "[killswitch]    affecting: $*"
    fi
    ;;

  off)
    turso db shell "$TURSO_URL" "UPDATE agent_kill_switch
      SET active=0,
          set_by=NULL,
          set_at=NULL,
          reason=NULL,
          affected_agents=NULL
      WHERE id=1;"
    echo "[killswitch] OFF — agents may start sessions normally"
    ;;

  status)
    turso db shell "$TURSO_URL" "SELECT
      CASE WHEN active=1 THEN 'ACTIVE' ELSE 'inactive' END,
      COALESCE(set_by, '-'),
      COALESCE(set_at, '-'),
      COALESCE(reason, '-'),
      COALESCE(affected_agents, 'all')
    FROM agent_kill_switch WHERE id=1;"
    ;;

  *)
    cat <<USAGE >&2
Usage: $0 on "<reason>" [agent-role…]
       $0 off
       $0 status

Agent action kill switch — per handbook ADR 0004 Track 4.
USAGE
    exit 2
    ;;
esac
