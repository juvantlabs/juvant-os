#!/usr/bin/env bash
# scripts/sync-hooks.sh
# FEAT-050 — Reconcile the framework hook-registration block into
# .claude/settings.json from the canonical template, preserving all
# instance-specific keys.
#
# Problem: the `hooks` block in .claude/settings.json is framework
# boilerplate (identical across all instances), but settings.json also
# holds instance-specific config (permissions.allow / additionalDirectories,
# channels, enabledPlugins). Because the whole file is on the upstream-sync
# "never touched" list, framework fixes to the hooks block (e.g. BUG-045)
# cannot reach existing adopters via juv-upstream-sync — each instance had
# to be patched by hand.
#
# Fix: keep the canonical hooks block in a whitelisted template
# (scripts/templates/hooks-registration.json) and reconcile it into
# settings.json with jq — strict JSON in, strict JSON out, ONLY the `.hooks`
# key replaced. Everything else is preserved byte-for-byte by jq's identity
# on untouched keys. Idempotent: a second run is a no-op.
#
# The canonical hooks block is instance-agnostic — each registration
# resolves its script via $CLAUDE_PROJECT_DIR at runtime (BUG-045), so no
# per-instance substitution is needed.
#
# Usage:
#   bash scripts/sync-hooks.sh [--dry-run]
#
# Called by:
#   - juv-upstream-sync post-apply step (when the template changed).
#   - On demand, any time settings.json's hooks block drifts from canonical.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TEMPLATE="$SCRIPT_DIR/templates/hooks-registration.json"
SETTINGS="$REPO_ROOT/.claude/settings.json"
DRY_RUN=0

for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=1
done

if ! command -v jq &>/dev/null; then
  echo "[sync-hooks] FATAL: jq is required but not found" >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "[sync-hooks] FATAL: canonical template not found at $TEMPLATE" >&2
  exit 1
fi
if ! jq empty "$TEMPLATE" &>/dev/null; then
  echo "[sync-hooks] FATAL: template is not valid JSON: $TEMPLATE" >&2
  exit 1
fi

if [[ ! -f "$SETTINGS" ]]; then
  echo "[sync-hooks] SKIP: no .claude/settings.json at $SETTINGS — nothing to reconcile" >&2
  exit 0
fi
if ! jq empty "$SETTINGS" &>/dev/null; then
  echo "[sync-hooks] FATAL: .claude/settings.json is not valid JSON — refusing to touch it" >&2
  exit 1
fi

CANONICAL_HOOKS=$(jq -S '.hooks' "$TEMPLATE")
CURRENT_HOOKS=$(jq -S '.hooks // null' "$SETTINGS")

if [[ "$CANONICAL_HOOKS" == "$CURRENT_HOOKS" ]]; then
  echo "[sync-hooks] hooks block already matches canonical template — no change"
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[sync-hooks] DRY RUN — hooks block differs from canonical; would reconcile:"
  diff <(echo "$CURRENT_HOOKS") <(echo "$CANONICAL_HOOKS") | sed 's/^/  /' || true
  exit 0
fi

# Replace ONLY .hooks with the canonical block; preserve every other key.
UPDATED=$(jq --argjson hooks "$(jq '.hooks' "$TEMPLATE")" '.hooks = $hooks' "$SETTINGS")

# Validate before writing — defence in depth.
if ! echo "$UPDATED" | jq empty &>/dev/null; then
  echo "[sync-hooks] FATAL: jq transform produced invalid JSON — refusing to write" >&2
  exit 1
fi

# Atomic write.
TMP="$SETTINGS.tmp.$$"
echo "$UPDATED" > "$TMP"
mv "$TMP" "$SETTINGS"

echo "[sync-hooks] reconciled .claude/settings.json hooks block from canonical template ($(jq '.hooks | length' "$TEMPLATE") events). Other keys preserved."
