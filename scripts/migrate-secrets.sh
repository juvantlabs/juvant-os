#!/usr/bin/env bash
# scripts/migrate-secrets.sh
# Move secrets out of .juvant/config.json into .juvant/secrets.json
# (decisions#305 B1b). Idempotent; never prints a secret value.
#
# What moves (hooks/lib/secrets.sh juvant_secret_paths_in): .db.auth_token,
# .db.read_token, .turso_token, .notifications.telegram_bot_token,
# .notifications.teams_webhooks.*, .github_token, and per project
# .projects.<slug>.{db.auth_token, db.read_token, auth_token, db_token,
# notifications.teams_webhooks.*}, and any other credential-shaped key
# (client_secret, *_secret, *_token, password, api_key, … — e.g.
# .m365_oauth.client_secret; BUG-084). Files that read a moved path straight
# from config.json are listed so they can switch to juvant_secret_get.
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

# BUG-084: a script that reads a moved path straight from config.json (e.g. a
# generated MCP wrapper doing `jq -er '.m365_oauth.client_secret' config.json`)
# gets nothing once it moves. Point at every such reader; the fix is
# `. hooks/lib/secrets.sh; juvant_secret_get '<path>'` (reads the secrets file,
# falls back to config.json), as in JUVANT_OS.md's M365 wrapper template.
# A line that goes through one of the framework's gated accessors is not a
# direct reader: juvant_secret_get (secrets file, config fallback) and
# hooks/lib/alert.sh's _juvant_alert_gated (secrets file ONLY) — H24.
GATED_ACCESSORS='juvant_secret_get|_juvant_alert_gated'
readers=""
while IFS= read -r dot; do
  hits=$(grep -rnF -- "$dot" "$ROOT/scripts" "$ROOT/helpers" "$ROOT/hooks" "$ROOT/.mcp.json" 2>/dev/null \
           | grep -vE "$GATED_ACCESSORS" | grep -v '/hooks/lib/secrets.sh:' | grep -v '/scripts/migrate-secrets.sh:' \
           | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' | cut -d: -f1-2 || true)
  [[ -n "$hits" ]] && readers+="  ${dot} ← read directly by:"$'\n'"      ${hits//$'\n'/$'\n'      }"$'\n'
done < <(jq -r '.[] | select(all(.[]; type == "string")) | "." + join(".")' <<< "$paths_json")
if [[ -n "$readers" ]]; then
  echo "migrate-secrets: WARNING — these files read a secret straight from config.json and will get NOTHING after the move:"
  printf '%s' "$readers"
  echo "  Change each read to: . hooks/lib/secrets.sh; juvant_secret_get '<path>' \"\$CONFIG\""
fi
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
