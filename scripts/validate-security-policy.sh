#!/usr/bin/env bash
# scripts/validate-security-policy.sh
# Validate an instance security policy (security/policy.json — decisions#305,
# ADR 0034) with the SAME structural rules the PreToolUse hook applies before it
# trusts the file (hooks/lib/security-policy.sh juvant_policy_validate). An
# invalid policy makes the hook FAIL CLOSED (every mcp__ call denied), so run
# this in the instance's CI on every PR that touches the file.
#
# Usage:
#   bash scripts/validate-security-policy.sh [path]          # default security/policy.json
#   bash scripts/validate-security-policy.sh [--repo <dir>] --ref <git-ref>   # e.g. origin/main
#
# --ref reads the policy from <git-ref> in the repo given by --repo; without
# --repo, the git repo of the CURRENT directory, falling back to the repo this
# script lives in. (The script can be run from a framework checkout against an
# instance repo: `cd ~/instance && bash ~/juvant-os/scripts/validate-security-policy.sh --ref origin/main`
# or `--repo ~/instance`.) The ref is resolved the way the hook resolves it:
# `origin/main` → refs/remotes/origin/main, with GIT_NO_REPLACE_OBJECTS=1.
#
# Exit: 0 valid · 1 invalid · 2 usage / file missing.
# Reference schema (documentation): docs/schemas/security-policy.schema.json.
#
# Example instance CI step (GitHub Actions):
#   - name: Validate security policy
#     if: hashFiles('security/policy.json') != ''
#     run: bash scripts/validate-security-policy.sh security/policy.json

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
. "$REPO_ROOT/hooks/lib/security-policy.sh"

command -v jq >/dev/null 2>&1 || { echo "validate-security-policy: jq is required" >&2; exit 2; }

target_repo=""
if [[ "${1:-}" == "--repo" ]]; then
  target_repo="${2:-}"; shift 2 || true
  if [[ -z "$target_repo" ]] || ! git -C "$target_repo" rev-parse --git-dir >/dev/null 2>&1; then
    echo "validate-security-policy: --repo needs a git repository" >&2; exit 2
  fi
fi
if [[ "${1:-}" == "--ref" ]]; then
  ref="${2:-}"
  [[ -n "$ref" ]] || { echo "usage: $0 [--repo <dir>] --ref <git-ref>" >&2; exit 2; }
  if [[ -z "$target_repo" ]]; then
    target_repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "$REPO_ROOT")
  fi
  # Same resolution as the hook: a remote-tracking name must not be shadowed
  # by a local branch or tag of the same name.
  [[ "$ref" =~ ^origin/ ]] && ref="refs/remotes/$ref"
  if ! raw=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$target_repo" cat-file -p "${ref}:security/policy.json" 2>/dev/null); then
    echo "validate-security-policy: no security/policy.json at ${ref} in ${target_repo}" >&2; exit 2
  fi
  label="${target_repo}@${ref}:security/policy.json"
else
  f="${1:-$REPO_ROOT/security/policy.json}"
  [[ -f "$f" ]] || { echo "validate-security-policy: file not found: $f" >&2; exit 2; }
  raw=$(cat "$f"); label="$f"
fi

if err=$(juvant_policy_validate "$raw"); then
  n_sp=$(printf '%s' "$raw" | jq '(.space_access // []) | length')
  has_conn=$(printf '%s' "$raw" | jq -r 'if has("connector_tool_allowlist") then "yes" else "no" end')
  req=$(printf '%s' "$raw" | jq -r '(.alert_routing.required // []) | join(",")')
  echo "OK — ${label}: ${n_sp} space_access rule(s); connector allowlist: ${has_conn}; required alert channels: ${req:-none}"
  exit 0
fi
echo "INVALID — ${label}: ${err}" >&2
echo "The PreToolUse hook would FAIL CLOSED on this policy (every mcp__ call denied)." >&2
exit 1
