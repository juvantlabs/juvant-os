#!/usr/bin/env bash
# scripts/migrate-secrets.sh
# Move secrets out of .juvant/config.json into .juvant/secrets.json
# (decisions#305 B1b). Idempotent; never prints a secret value.
#
# What moves (hooks/lib/secrets.sh juvant_secret_paths_in): .db.auth_token,
# .db.read_token, .turso_token, .notifications.telegram_bot_token,
# .notifications.teams_webhooks.*, .github_token, and per project
# .projects.<slug>.{db.auth_token, db.read_token, auth_token, db_token,
# notifications.teams_webhooks.*}.
#
# Steps: merge those paths into secrets.json (created 0600; existing secret
# values win over config copies), verify every moved value reads back
# identically from secrets.json, and only then delete the paths from
# config.json. Both files are written atomically.
#
# Usage:
#   bash scripts/migrate-secrets.sh [--dry-run]
#   (JUVANT_CONFIG / JUVANT_SECRETS override the file locations, as in the hooks)
#
# Exit: 0 done / nothing to do · 1 error (config untouched).

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="${JUVANT_CONFIG:-$ROOT/.juvant/config.json}"
# shellcheck disable=SC1091
. "$ROOT/hooks/lib/secrets.sh"
SECRETS="$(juvant_secrets_file "$CONFIG")"
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1

command -v jq >/dev/null 2>&1 || { echo "migrate-secrets: jq is required" >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "migrate-secrets: no config at $CONFIG — nothing to do"; exit 0; }

paths_json=$(juvant_secret_paths_in "$CONFIG" | jq -s -c '.')
count=$(jq 'length' <<< "$paths_json")
if [[ "$count" -eq 0 ]]; then
  echo "migrate-secrets: no secrets left in $(basename "$CONFIG") — nothing to do"
  exit 0
fi
echo "migrate-secrets: ${count} secret path(s) in $(basename "$CONFIG"):"
jq -r '.[] | map(tostring) | join(".") | "  - " + .' <<< "$paths_json"
if [[ "$DRY" -eq 1 ]]; then echo "migrate-secrets: --dry-run — no file changed"; exit 0; fi

# 1. Build the merged secrets object (existing secrets.json values win).
moved=$(jq -c --argjson ps "$paths_json" '. as $root | reduce $ps[] as $p ({}; setpath($p; ($root | getpath($p))))' "$CONFIG")
existing='{}'
[[ -f "$SECRETS" ]] && existing=$(cat "$SECRETS")
merged=$(jq -n --argjson a "$moved" --argjson b "$existing" '$a * $b')

tmp_s="$SECRETS.tmp.$$"
printf '%s\n' "$merged" | jq . > "$tmp_s"
chmod 600 "$tmp_s"
mv "$tmp_s" "$SECRETS"

# 2. Verify every moved value reads back from secrets.json (or was already
#    there with a value of its own — then the config copy is stale and dropped).
bad=0
while IFS= read -r p; do
  if ! jq -e --argjson p "$p" 'getpath($p) != null' "$SECRETS" >/dev/null 2>&1; then
    echo "migrate-secrets: ERROR — $(jq -r 'map(tostring) | join(".")' <<< "$p") missing from secrets.json after write" >&2
    bad=1
  fi
done < <(jq -c '.[]' <<< "$paths_json")
[[ "$bad" -eq 0 ]] || { echo "migrate-secrets: config.json left untouched" >&2; exit 1; }

# 3. Remove them from config.json.
tmp_c="$CONFIG.tmp.$$"
jq --argjson ps "$paths_json" 'delpaths($ps)' "$CONFIG" > "$tmp_c"
chmod --reference="$CONFIG" "$tmp_c" 2>/dev/null || chmod 600 "$tmp_c"
mv "$tmp_c" "$CONFIG"

echo "migrate-secrets: moved ${count} secret(s) to $(basename "$SECRETS") (mode 600) and removed them from $(basename "$CONFIG")."
echo "migrate-secrets: least privilege — consider a read-only DB token for reads:"
echo "  turso db tokens create <db> --read-only   → store it as .db.read_token in $(basename "$SECRETS") (from your own terminal)"
