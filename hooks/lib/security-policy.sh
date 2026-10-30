#!/usr/bin/env bash
# hooks/lib/security-policy.sh
# Instance security policy loader — decisions#305 (B1a, security_audit_log#159),
# ADR 0034 (supersedes ADR 0025 clause 5 only).
#
# The sensitive-space rules (`space_access`), the connector tool allowlist
# (`connector_tool_allowlist`, decisions#306), the per-agent shared-mailbox
# rules (`shared_mailboxes`, Track 2g — BUG-083) and the alert routing
# (`alert_routing`) live in a COMMITTED file, `security/policy.json`, in the
# instance repo — never in `.juvant/config.json` (gitignored: no history, no
# review, no attribution, editable by any agent) and never in an upstream-synced
# file. No secrets in it: webhook URLs / tokens stay in .juvant/config.json.
#
# The hook reads the policy from the instance's `origin/main`, never from the
# working tree:
#   GIT_NO_REPLACE_OBJECTS=1 git cat-file -p refs/remotes/origin/main:security/policy.json
# • the FULL ref name — a local branch or tag literally named `origin/main`
#   would otherwise shadow the remote-tracking ref;
# • GIT_NO_REPLACE_OBJECTS — `git replace` can't substitute the blob.
# Local edits, local commits and branch switches therefore have no effect on
# enforcement; a policy change is a reviewed merge to main + fetch.
#
# States (JUVANT_POLICY_STATE):
#   ok       policy read from origin/main and structurally valid
#   absent   no policy file ever existed on origin/main (and no leftover
#            config.json rules) → the consumers are a no-op, as before
#   unmigrated  no policy file, but `.security.space_access` rules are left in
#            .juvant/config.json — never read (that location was removed in
#            v1.16.1), so the rules were never migrated → FAIL CLOSED
#   invalid  policy present but unparseable / structurally invalid  → FAIL CLOSED
#   deleted  no policy file at origin/main, but git history shows one existed
#            → FAIL CLOSED
#   test     explicit test mode (JUVANT_POLICY_TEST=1 + JUVANT_POLICY_FILE)
# FAIL CLOSED = the caller denies every `mcp__` call, writes a high row, alerts.
#
# JUVANT_CONFIG never changes where the POLICY comes from. Tests opt in with
# JUVANT_POLICY_TEST=1 and JUVANT_POLICY_FILE=<path> (an env the agent can't set
# for the hook process; the SessionStart integrity check flags it if it appears
# in .claude/settings.json `env`).
#
# API:
#   juvant_policy_load <repo_root>  → sets JUVANT_POLICY_STATE, JUVANT_POLICY_JSON
#                                     (normalised compact JSON, "{}" when none),
#                                     JUVANT_POLICY_BLOB (blob sha or "").
#   juvant_policy_validate <json>   → 0 if structurally valid, else prints the
#                                     first problem and returns 1.

# The JUVANT_POLICY_* globals set below are consumed by the sourcing hook.
# shellcheck disable=SC2034
JUVANT_POLICY_PATH="security/policy.json"
JUVANT_POLICY_REF="refs/remotes/origin/main"

juvant_policy_validate() {
  local j="$1" err
  err=$(printf '%s' "$j" | jq -r '
    def str: type == "string";
    def strarr: type == "array" and all(.[]; type == "string");
    if type != "object" then "top level must be an object"
    elif (.version // 1) != 1 then "unsupported version (expected 1)"
    elif has("space_access") and (.space_access | type != "array") then "space_access must be an array"
    elif any(.space_access[]?; (type != "object") or ((.tool_prefix // "") | str | not) or ((.tool_prefix // "") == "")
             or ((.allowlist // []) | strarr | not) or ((.drive_ids // []) | strarr | not)
             or ((.path_patterns // []) | strarr | not))
      then "each space_access entry needs a non-empty tool_prefix and string arrays allowlist/drive_ids/path_patterns"
    elif has("connector_tool_allowlist") and (.connector_tool_allowlist | type != "object") then "connector_tool_allowlist must be an object"
    elif has("connector_tool_allowlist") and (((.connector_tool_allowlist.tool_prefix // "") | str | not) or ((.connector_tool_allowlist.tool_prefix // "") == "")
             or ((.connector_tool_allowlist.allow // []) | strarr | not)
             or ((.connector_tool_allowlist.read_resource_uri_prefixes // []) | strarr | not))
      then "connector_tool_allowlist needs tool_prefix and string arrays allow/read_resource_uri_prefixes"
    elif has("secrets_paths") and ((.secrets_paths | strarr | not) or any(.secrets_paths[]; . == "" or . == "*" or . == "**" or . == "*/*"))
      then "secrets_paths must be an array of non-empty path globs (not a catch-all like \"*\")"
    elif has("shared_mailboxes") and (.shared_mailboxes | type != "object") then "shared_mailboxes must be an object"
    elif has("shared_mailboxes") and ((.shared_mailboxes.by_agent // null) | type != "object")
      then "shared_mailboxes.by_agent must be an object (role → array of {upn, scope})"
    elif has("shared_mailboxes") and any(.shared_mailboxes.by_agent[]; (type != "array")
             or any(.[]; (type != "object") or ((.upn // "") | str | not) or ((.upn // "") == "")
                         or ((.scope // "read") | IN("read", "readwrite") | not)))
      then "each shared_mailboxes.by_agent entry needs a non-empty upn and scope read|readwrite"
    elif has("shared_mailboxes") and ((.shared_mailboxes.main_thread // "explicit") | IN("explicit", "ceo_present_read", "deny") | not)
      then "shared_mailboxes.main_thread must be explicit|ceo_present_read|deny"
    elif has("shared_mailboxes") and (((.shared_mailboxes.tool_prefix // "x") | str | not) or ((.shared_mailboxes.tool_prefix // "x") == ""))
      then "shared_mailboxes.tool_prefix must be a non-empty string"
    elif has("shared_mailboxes") and ((.shared_mailboxes.own_mailbox // {}) | (type != "object")
             or ((.main_thread // "readwrite") | IN("read", "readwrite", "deny") | not)
             or ((.agents // "read") | IN("read", "readwrite", "deny") | not))
      then "shared_mailboxes.own_mailbox.{main_thread,agents} must be read|readwrite|deny"
    elif has("alert_routing") and (.alert_routing | type != "object") then "alert_routing must be an object"
    elif has("alert_routing") and ((.alert_routing.required // []) | (strarr and all(.[]; . == "teams" or . == "telegram")) | not)
      then "alert_routing.required must be a subset of [\"teams\",\"telegram\"]"
    else "" end' 2>/dev/null) || err="not valid JSON"
  if [[ -n "$err" ]]; then printf '%s\n' "$err"; return 1; fi
  return 0
}

juvant_policy_load() {
  local root="$1" raw err cfg
  JUVANT_POLICY_STATE="absent"; JUVANT_POLICY_JSON="{}"; JUVANT_POLICY_BLOB=""
  if [[ "${JUVANT_POLICY_TEST:-0}" == "1" ]]; then
    echo "[security-policy] WARN: JUVANT_POLICY_TEST=1 — policy read from \$JUVANT_POLICY_FILE (test mode only)" >&2
    if [[ -n "${JUVANT_POLICY_FILE:-}" && -f "$JUVANT_POLICY_FILE" ]]; then
      raw=$(cat "$JUVANT_POLICY_FILE")
      if err=$(juvant_policy_validate "$raw"); then
        JUVANT_POLICY_STATE="test"; JUVANT_POLICY_JSON=$(printf '%s' "$raw" | jq -c .)
      else
        JUVANT_POLICY_STATE="invalid"; JUVANT_POLICY_ERR="$err"
      fi
      return 0
    fi
    # Test mode without a file falls through to the leftover check below.
  elif git -C "$root" rev-parse --verify -q "$JUVANT_POLICY_REF" >/dev/null 2>&1; then
    JUVANT_POLICY_BLOB=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$root" rev-parse -q --verify "$JUVANT_POLICY_REF:$JUVANT_POLICY_PATH" 2>/dev/null || echo "")
    if [[ -n "$JUVANT_POLICY_BLOB" ]]; then
      raw=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$root" cat-file -p "$JUVANT_POLICY_BLOB" 2>/dev/null) || raw=""
      if err=$(juvant_policy_validate "$raw"); then
        JUVANT_POLICY_STATE="ok"; JUVANT_POLICY_JSON=$(printf '%s' "$raw" | jq -c .)
      else
        JUVANT_POLICY_STATE="invalid"; JUVANT_POLICY_ERR="$err"
      fi
      return 0
    fi
    if [[ -n "$(GIT_NO_REPLACE_OBJECTS=1 git -C "$root" log -1 --format=%H "$JUVANT_POLICY_REF" -- "$JUVANT_POLICY_PATH" 2>/dev/null)" ]]; then
      JUVANT_POLICY_STATE="deleted"; JUVANT_POLICY_ERR="security/policy.json was removed from origin/main"
      return 0
    fi
  fi
  # The config.json location (.security.space_access) is never read — removed
  # in v1.16.1. Rules left there with no policy file were never migrated: fail
  # closed rather than drop the perimeter silently.
  cfg="${JUVANT_CONFIG:-$root/.juvant/config.json}"
  if [[ -f "$cfg" ]] && jq -e '(.security.space_access // []) | length > 0' "$cfg" >/dev/null 2>&1; then
    JUVANT_POLICY_STATE="unmigrated"
    JUVANT_POLICY_ERR="sensitive-space rules are only in .juvant/config.json .security.space_access, which is no longer read (removed in v1.16.1) — move them into security/policy.json via a reviewed PR to main"
  fi
  return 0
}
