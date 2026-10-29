#!/usr/bin/env bash
# scripts/set-secret.sh
# Add ONE secret to .juvant/secrets.json (decisions#305 B1b) — the sanctioned
# way for the init wizard (or an operator) to store a token while the
# PreToolUse secrets gate (Track 2h) denies every tool access to the file.
#
#   printf '%s' "<value>" | bash scripts/set-secret.sh <jq-path>
#   e.g.  … | bash scripts/set-secret.sh .db.read_token
#         … | bash scripts/set-secret.sh '.notifications.teams_webhooks.ops'
#
# ADD-ONLY: an existing value is never replaced from here. Replacing a secret
# (rotating a token, changing where alerts go) is done by the CEO editing the
# file from their own terminal, outside Claude Code — otherwise an agent could
# silently redirect the alert channel or break the DB token.
# The value is read from stdin and never printed.
#
# Exit: 0 stored · 1 refused / error.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="${JUVANT_CONFIG:-$ROOT/.juvant/config.json}"
# shellcheck disable=SC1091
. "$ROOT/hooks/lib/secrets.sh"
SECRETS="$(juvant_secrets_file "$CONFIG")"

path="${1:-}"
if ! [[ "$path" =~ ^(\.[A-Za-z_][A-Za-z0-9_-]*|\[\"[A-Za-z0-9_-]+\"\])+$ ]]; then
  echo "set-secret: usage: printf '%s' <value> | bash scripts/set-secret.sh <.jq.path>" >&2; exit 1
fi
value=$(cat)
[[ -n "$value" ]] || { echo "set-secret: empty value on stdin — refused" >&2; exit 1; }

[[ -f "$SECRETS" ]] || { printf '{}\n' > "$SECRETS"; chmod 600 "$SECRETS"; }
if jq -e "(${path}) != null" "$SECRETS" >/dev/null 2>&1; then
  echo "set-secret: ${path} already has a value — refused (add-only; replace it from your own terminal)" >&2
  exit 1
fi
tmp="$SECRETS.tmp.$$"
jq --arg v "$value" "${path} = \$v" "$SECRETS" > "$tmp"
chmod 600 "$tmp"; mv "$tmp" "$SECRETS"
echo "set-secret: stored ${path} (value not shown)"
