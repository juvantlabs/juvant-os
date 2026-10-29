#!/usr/bin/env bash
# hooks/lib/secrets.sh
# Instance secrets accessor — decisions#305 B1b (CEO ruling 2026-10-29: a
# separate secrets file behind the hook gate, not the OS keychain — portable
# across macOS, Linux and CI, no OS coupling, no unlock prompts for launchd).
#
# Secrets (DB tokens, notification webhooks / bot tokens, GitHub tokens) live in
# `.juvant/secrets.json` — gitignored, chmod 600, next to .juvant/config.json —
# never in config.json, which the Skill and every agent read freely. The file is
# read ONLY by hook / helper processes through this accessor; the PreToolUse
# Track 2h gate denies every agent (main thread included) Read / Grep / Edit /
# Write on it and every Bash command that names it or reads .juvant/ wholesale.
#
# secrets.json mirrors config.json's paths for the keys it holds, e.g.
#   { "db": { "auth_token": "…", "read_token": "…" },
#     "notifications": { "telegram_bot_token": "…", "telegram_chat_id": "…",
#                        "teams_webhooks": { "approvals": "…", "ops": "…" } },
#     "projects": { "<slug>": { "db": { "auth_token": "…" } } },
#     "github_token": "…",
#     "m365_oauth": { "client_secret": "…" } }
# Beyond the named paths, any key shaped like a credential (client_secret,
# *_secret, *_token, password, api_key, private_key …) counts as a secret
# (BUG-084).
#
# Location: $JUVANT_SECRETS, else secrets.json in the same directory as the
# config file in use (so a test's JUVANT_CONFIG fixture gets its own secrets).
#
# Legacy (ONE minor version): a secret not found in secrets.json is read from
# config.json with a deprecation warning on stderr. `bash scripts/migrate-secrets.sh`
# moves them.
#
# API:
#   juvant_secret_get <jq-expr> [config-file]   → prints the value or nothing
#   juvant_secrets_file [config-file]           → path of the secrets file
#   juvant_secret_paths_in <file>               → secret jq paths present in a file
#                                                 (one per line; for migration and
#                                                 the SessionStart leftover check)

_juvant_secrets_default_cfg() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s' "${JUVANT_CONFIG:-$here/../../.juvant/config.json}"
}

juvant_secrets_file() {
  local cfg="${1:-$(_juvant_secrets_default_cfg)}"
  printf '%s' "${JUVANT_SECRETS:-$(dirname "$cfg")/secrets.json}"
}

juvant_secret_get() {
  local expr="$1" cfg="${2:-$(_juvant_secrets_default_cfg)}" sec v
  sec=$(juvant_secrets_file "$cfg")
  if [[ -f "$sec" ]]; then
    v=$(jq -r "(${expr}) // empty" "$sec" 2>/dev/null || true)
    if [[ -n "$v" && "$v" != "null" ]]; then printf '%s' "$v"; return 0; fi
  fi
  if [[ -f "$cfg" ]]; then
    v=$(jq -r "(${expr}) // empty" "$cfg" 2>/dev/null || true)
    if [[ -n "$v" && "$v" != "null" ]]; then
      [[ "${JUVANT_SECRETS_QUIET:-0}" == 1 ]] || \
        echo "[secrets] DEPRECATED: a secret (${expr}) was read from $(basename "$cfg") — move it to .juvant/secrets.json with 'bash scripts/migrate-secrets.sh' (decisions#305 B1b)." >&2
      printf '%s' "$v"
    fi
  fi
  return 0
}

# Every config path that holds a secret (the migration moves exactly these).
juvant_secret_paths_in() {
  jq -r '
    [ paths(scalars) as $p
      | select(
          ($p == ["db","auth_token"]) or ($p == ["db","read_token"]) or ($p == ["turso_token"]) or
          ($p == ["notifications","telegram_bot_token"]) or
          # BUG-088: the chat id is the other half of the alert destination —
          # agent-writable in config.json, it could silently redirect alerts.
          ($p == ["notifications","telegram_chat_id"]) or
          ($p[0:2] == ["notifications","teams_webhooks"]) or
          ($p == ["github_token"]) or
          ($p[0] == "projects" and (($p[2:] == ["db","auth_token"]) or ($p[2:] == ["db","read_token"])
                                   or ($p[2:] == ["auth_token"]) or ($p[2:] == ["db_token"])
                                   or ($p[2:4] == ["notifications","teams_webhooks"]))) or
          # BUG-084: any other key shaped like a credential, wherever it sits
          # (e.g. .m365_oauth.client_secret, .m365.client_secret). Non-empty
          # strings only; word-anchored so max_tokens / token_budget stay put.
          ((($p[-1] | type) == "string") and
           ($p[-1] | test("^(client_secret|secret|token|password|passwd|api_?key|private_key)$|_(secret|token|password|passwd|api_?key|private_key)$"; "i")) and
           ((getpath($p) | type) == "string") and ((getpath($p) | length) > 0)))
      | $p ] | unique | .[] | tojson' "$1" 2>/dev/null || true
}
