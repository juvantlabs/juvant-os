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

# decisions#303 R2: the template also carries framework permission DENIES
# (`permissions_deny`) for paths the hook gate protects — the audit spool
# family, its backups, the drain helper, security/policy.json. They are MERGED
# into .permissions.deny: missing entries are appended, instance entries are
# kept, order preserved, nothing removed. Not applied in the framework repo
# itself (origin = juvantlabs/juvant-os) unless JUVANT_FRAMEWORK_DEV=0: an
# Edit/Write permission deny is absolute — it has no framework-dev exemption —
# and would block framework development of the very files it protects.
_origin=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")
APPLY_DENY=1
case "${JUVANT_FRAMEWORK_DEV:-auto}" in
  1) APPLY_DENY=0 ;;
  0) APPLY_DENY=1 ;;
  *) [[ "$_origin" =~ (^|[/:])juvantlabs/juvant-os(\.git)?$ ]] && APPLY_DENY=0 ;;
esac
# The stale framework comment claimed .juvant/config.json was "explicitly
# denied" — it never was (decisions#303). Rewrite only that framework-authored
# sentence; any instance wording is left alone.
STALE='.juvant/config.json and .env* are explicitly denied (token-bearing).'
FIXED='.env* and credentials* are denied (token-bearing); the audit spool, its backups, the drain helper and security/policy.json are denied via the framework permissions_deny merge (decisions#303). .juvant/config.json is NOT denied — the Skill writes it at bootstrap.'

UPDATED=$(jq --argjson hooks "$(jq '.hooks' "$TEMPLATE")" \
             --argjson deny "$(jq '.permissions_deny // []' "$TEMPLATE")" \
             --argjson apply "$APPLY_DENY" \
             --arg stale "$STALE" --arg fixed "$FIXED" '
  .hooks = $hooks
  | if $apply == 1 and ($deny | length) > 0 then
      .permissions.deny = ((.permissions.deny // []) as $cur
                           | $cur + [ $deny[] | select(. as $d | $cur | index($d) | not) ])
    else . end
  | if (.permissions._comment // "" | type) == "string" and (.permissions._comment // "" | contains($stale)) then
      .permissions._comment |= (split($stale) | join($fixed))
    else . end
' "$SETTINGS")

if [[ "$(echo "$UPDATED" | jq -S .)" == "$(jq -S . "$SETTINGS")" ]]; then
  echo "[sync-hooks] hooks block and framework denies already match canonical template — no change"
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[sync-hooks] DRY RUN — settings differ from canonical; would reconcile:"
  diff <(jq -S '{hooks, permissions}' "$SETTINGS") <(echo "$UPDATED" | jq -S '{hooks, permissions}') | sed 's/^/  /' || true
  exit 0
fi

# Validate before writing — defence in depth.
if ! echo "$UPDATED" | jq empty &>/dev/null; then
  echo "[sync-hooks] FATAL: jq transform produced invalid JSON — refusing to write" >&2
  exit 1
fi

# Atomic write.
TMP="$SETTINGS.tmp.$$"
echo "$UPDATED" > "$TMP"
mv "$TMP" "$SETTINGS"

echo "[sync-hooks] reconciled .claude/settings.json from canonical template ($(jq '.hooks | length' "$TEMPLATE") hook events; framework denies merged=$APPLY_DENY). Other keys preserved."
