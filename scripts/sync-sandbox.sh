#!/usr/bin/env bash
# scripts/sync-sandbox.sh
# ADR 0036 — reconcile the Claude Code Bash sandbox block into
# .claude/settings.json from scripts/templates/sandbox.json.
#
# Active only when .juvant/config.json feature_toggles.bash_sandbox is true.
# Writes ONLY the `.sandbox` key (every other key preserved by jq identity,
# same contract as scripts/sync-hooks.sh). network.allowedDomains is compiled
# from the template's binary_domains, restricted to binaries some role is
# allowed in hooks/bash-policy.json, plus config `sandbox.extra_domains`.
#
# With the sandbox on, agent Bash cannot write .claude/settings.json (Claude
# Code protects it) nor scripts/ — run this from your own terminal (`! bash
# scripts/sync-sandbox.sh`) or let helpers/upstream-apply.sh run it (it is
# the one command excluded from the sandbox).
#
# Usage:
#   bash scripts/sync-sandbox.sh            apply (no-op when already canonical)
#   bash scripts/sync-sandbox.sh --print    print the expected block, change nothing
#   bash scripts/sync-sandbox.sh --check    exit 1 + reasons when settings drift
#   bash scripts/sync-sandbox.sh --remove   drop the .sandbox key (toggle turned off)
# Env: JUVANT_CONFIG, JUVANT_SETTINGS (test isolation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TEMPLATE="$SCRIPT_DIR/templates/sandbox.json"
POLICY="$REPO_ROOT/hooks/bash-policy.json"
CONFIG="${JUVANT_CONFIG:-$REPO_ROOT/.juvant/config.json}"
SETTINGS="${JUVANT_SETTINGS:-$REPO_ROOT/.claude/settings.json}"
MODE="apply"
case "${1:-}" in
  ""|--apply) ;;
  --print) MODE="print" ;;
  --check) MODE="check" ;;
  --remove) MODE="remove" ;;
  *) echo "usage: $0 [--print|--check|--remove]" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "[sync-sandbox] FATAL: jq is required" >&2; exit 1; }
jq empty "$TEMPLATE" 2>/dev/null || { echo "[sync-sandbox] FATAL: template missing or not JSON: $TEMPLATE" >&2; exit 1; }

# The expected block.
_expected() {
  local bins extra
  bins=$(jq -c '. as $d | [.agent_allow[][] | if startswith("@") then ($d.tiers[ltrimstr("@")] // [])[] else . end] | unique' "$POLICY" 2>/dev/null || echo '[]')
  extra=$(jq -c '(.sandbox.extra_domains // []) | map(select(type == "string"))' "$CONFIG" 2>/dev/null || echo '[]')
  jq -S --argjson bins "$bins" --argjson extra "$extra" '
    . as $t
    | ([$bins[] as $b | ($t.binary_domains[$b] // [])[]] + $extra | unique) as $dom
    | $t.sandbox | .network.allowedDomains = $dom
  ' "$TEMPLATE"
}

if [[ "$MODE" == "print" ]]; then _expected; exit 0; fi

if [[ "$MODE" == "remove" ]]; then
  [[ -f "$SETTINGS" ]] || exit 0
  tmp=$(mktemp); jq 'del(.sandbox)' "$SETTINGS" > "$tmp" && cat "$tmp" > "$SETTINGS"; rm -f "$tmp"
  echo "[sync-sandbox] removed .sandbox from $SETTINGS"; exit 0
fi

TOGGLE=$(jq -r '.feature_toggles.bash_sandbox // false' "$CONFIG" 2>/dev/null || echo false)
if [[ "$TOGGLE" != "true" ]]; then
  [[ "$MODE" == "check" ]] && exit 0
  echo "[sync-sandbox] feature_toggles.bash_sandbox is not true — nothing to do (use --remove to drop an old block)"
  exit 0
fi

EXPECTED=$(_expected)

if [[ "$MODE" == "check" ]]; then
  rc=0
  if [[ ! -f "$SETTINGS" ]]; then echo "sandbox-off: $SETTINGS missing"; exit 1; fi
  ACTUAL=$(jq -S '.sandbox // null' "$SETTINGS" 2>/dev/null || echo null)
  [[ "$(jq -r '.enabled // false' <<<"$ACTUAL")" == "true" ]] || { echo "sandbox-off: sandbox.enabled is not true"; rc=1; }
  [[ "$(jq -r 'if .allowUnsandboxedCommands == false then "false" else "other" end' <<<"$ACTUAL")" == "false" ]] \
    || { echo "sandbox-off: sandbox.allowUnsandboxedCommands is not false"; rc=1; }
  while IFS= read -r p; do
    jq -e --arg p "$p" '(.filesystem.denyWrite // []) | index($p)' <<<"$ACTUAL" >/dev/null 2>&1 \
      || { echo "sandbox-off: denyWrite misses $p"; rc=1; }
  done < <(jq -r '.filesystem.denyWrite[]' <<<"$EXPECTED")
  # Anything excluded beyond the canonical helper runs unsandboxed.
  while IFS= read -r e; do
    jq -e --arg e "$e" '.excludedCommands | index($e)' <<<"$EXPECTED" >/dev/null 2>&1 \
      || { echo "sandbox-off: extra excludedCommands entry '$e'"; rc=1; }
  done < <(jq -r '(.excludedCommands // [])[]' <<<"$ACTUAL")
  # A local override (personal file, applies over the shared one).
  _local="$(dirname "$SETTINGS")/settings.local.json"
  if [[ -f "$_local" ]] && jq -e 'has("sandbox")' "$_local" >/dev/null 2>&1; then
    echo "sandbox-off: .claude/settings.local.json overrides the sandbox block"; rc=1
  fi
  exit "$rc"
fi

# apply
[[ -f "$SETTINGS" ]] || { mkdir -p "$(dirname "$SETTINGS")"; echo '{}' > "$SETTINGS"; }
jq empty "$SETTINGS" 2>/dev/null || { echo "[sync-sandbox] FATAL: $SETTINGS is not valid JSON" >&2; exit 1; }
if [[ "$(jq -S '.sandbox // null' "$SETTINGS")" == "$EXPECTED" ]]; then
  echo "[sync-sandbox] OK — sandbox block already canonical"; exit 0
fi
tmp=$(mktemp)
jq --argjson sb "$EXPECTED" '.sandbox = $sb' "$SETTINGS" > "$tmp" && cat "$tmp" > "$SETTINGS"
rm -f "$tmp"
echo "[sync-sandbox] OK — sandbox block written to $SETTINGS ($(jq '.network.allowedDomains | length' <<<"$EXPECTED") allowed domains)"
