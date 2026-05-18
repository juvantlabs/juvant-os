#!/usr/bin/env bash
# scripts/sync-project-globs.sh
# FEAT-039 — Auto-extend .claude/settings.json Read/Grep/Glob permission
# globs to cover registered project working trees.
#
# Problem: ** globs in settings.json are evaluated relative to the session
# cwd (company root). Subagents that need to Read/Grep/Glob sibling project
# working trees (e.g. /Users/antonio/Projects/hardys/) are denied because
# the path is outside the relative glob scope.
#
# Fix: for each project in .juvant/config.json that has a `working_tree`
# field, emit absolute Read/Grep/Glob entries in permissions.allow.
# Edit/Write are NOT added here — defaultMode:acceptEdits already covers
# them, and write security lives in hooks/bash-policy.json + agent_tool_matrix.
#
# Idempotent — safe to run multiple times. Preserves all non-absolute-path
# entries (WebFetch, Bash, relative globs). Strips and rebuilds only the
# auto-generated absolute-path block on each run.
#
# Usage:
#   bash scripts/sync-project-globs.sh [--dry-run]
#
# Called automatically by:
#   - Project init (Step 2 in JUVANT_OS.md project setup)
#   - `juvant project add <slug>` skill procedure
#   - Upstream sync (if sync-project-globs.sh itself was updated)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG="$REPO_ROOT/.juvant/config.json"
SETTINGS="$REPO_ROOT/.claude/settings.json"
DRY_RUN=0

for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=1
done

if [[ ! -f "$CONFIG" ]]; then
  echo "[sync-project-globs] SKIP: no .juvant/config.json found" >&2
  exit 0
fi

if [[ ! -f "$SETTINGS" ]]; then
  echo "[sync-project-globs] FATAL: .claude/settings.json not found at $SETTINGS" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "[sync-project-globs] FATAL: jq is required but not found" >&2
  exit 1
fi

# Collect working_tree values for all registered projects.
# A project is eligible if it has a non-empty working_tree field.
mapfile -t WORKING_TREES < <(
  jq -r '
    .projects
    | to_entries[]
    | .value.working_tree // empty
    | select(length > 0)
  ' "$CONFIG" 2>/dev/null || true
)

if [[ "${#WORKING_TREES[@]}" -eq 0 ]]; then
  echo "[sync-project-globs] no projects with working_tree configured — nothing to add"
  exit 0
fi

echo "[sync-project-globs] found ${#WORKING_TREES[@]} project working tree(s):"
for wt in "${WORKING_TREES[@]}"; do
  echo "  $wt"
done

# Build the JSON array of new absolute-path glob entries.
NEW_GLOBS_JSON="[]"
for wt in "${WORKING_TREES[@]}"; do
  NEW_GLOBS_JSON=$(jq -n \
    --argjson existing "$NEW_GLOBS_JSON" \
    --arg wt "$wt" \
    '$existing + ["Read(\($wt)/**)", "Grep(\($wt)/**)", "Glob(\($wt)/**)"]'
  )
done

# Rebuild permissions.allow:
#   keep entries that are NOT absolute-path Read/Grep/Glob
#   (identified by matching Read(/...), Grep(/...), Glob(/...))
#   then append the freshly generated absolute entries.
UPDATED_SETTINGS=$(jq \
  --argjson new_globs "$NEW_GLOBS_JSON" \
  '
    .permissions.allow = (
      [
        .permissions.allow[]
        | select(
            test("^(Read|Grep|Glob)\\(/") | not
          )
      ]
      + $new_globs
    )
  ' "$SETTINGS")

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[sync-project-globs] DRY RUN — would write:"
  echo "$UPDATED_SETTINGS" | jq '.permissions.allow'
  exit 0
fi

echo "$UPDATED_SETTINGS" > "$SETTINGS"
echo "[sync-project-globs] updated $SETTINGS with ${#WORKING_TREES[@]} working tree(s)"
echo "[sync-project-globs] added entries:"
echo "$NEW_GLOBS_JSON" | jq -r '.[]' | sed 's/^/  /'
