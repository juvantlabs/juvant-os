#!/usr/bin/env bash
# scripts/sync-project-globs.sh
# FEAT-039 / FEAT-049 — Auto-extend .claude/settings.json Read/Grep/Glob permission
# globs to cover registered project working trees.
#
# Problem: ** globs in settings.json are evaluated relative to the session
# cwd (company root). Subagents that need to Read/Grep/Glob sibling project
# working trees (e.g. /Users/<user>/Projects/<project-slug>/) are denied because
# the path is outside the relative glob scope.
#
# Fix: for each project in .juvant/config.json, take its `working_tree` plus any
# `additional_working_trees[]` (e.g. a `-pm` planning repo — FEAT-049) and, for
# each path, emit absolute Read/Grep/Glob entries in permissions.allow AND add
# the path to permissions.additionalDirectories. Both are
# required (BUG-042): the allow-list removes the permission *prompt*, but
# project subagents run in a filesystem *sandbox* confined to cwd +
# additionalDirectories + /tmp — without the directory in
# additionalDirectories, the sibling-repo read is denied at the sandbox
# layer regardless of the allow-list.
# Edit/Write are NOT added here — defaultMode:acceptEdits already covers
# them, and write security lives in hooks/bash-policy.json + agent_tool_matrix.
#
# Idempotent — safe to run multiple times.
#
# Strict-JSON / state-sidecar approach (BUG-044, supersedes BUG-032 sentinels):
# Claude Code parses .claude/settings.json as STRICT JSON — no `//` comments,
# no trailing commas. Earlier revisions of this script wrote JSONC-style
# sentinel comments (`// [sync-project-globs:start]` / `:end` / `:addir:start` /
# `:addir:end`) and a trailing comma after every managed entry, which `/doctor`
# (and any strict-JSON consumer) rejects as "Invalid or malformed JSON". The
# bet on JSONC tolerance did not hold: the first real sync on a consumer
# instance broke `.claude/settings.json`.
#
# This revision manages auto-entries by **pattern via jq**, not by comment-
# sentinel text surgery. A small state sidecar tracks the set of working-tree
# paths previously managed by this script so stale entries get cleaned up
# when a project is removed:
#
#   .juvant/.sync-project-globs.state.json
#       { "version": 1, "managed_paths": ["/abs/path/one", ...] }
#
# Algorithm per run:
#   1. Compute NEW = working_tree + additional_working_trees[] for every project.
#   2. Load OLD from the state sidecar (empty if absent).
#   3. Migration (no sidecar yet): also treat as OLD any absolute path
#      appearing as Read(/abs/**) / Grep(/abs/**) / Glob(/abs/**) in the
#      current permissions.allow — these are the entries the pre-BUG-044
#      script (sentinel or pre-sentinel) installed.
#   4. REMOVE = OLD ∪ migration-inferred. Drop the corresponding entries
#      from permissions.allow and the corresponding bare-path entries from
#      permissions.additionalDirectories.
#   5. Add NEW entries to both arrays (create additionalDirectories if absent).
#   6. Dedupe both arrays preserving first-occurrence order — manual entries
#      stay where the operator put them.
#   7. Write strict JSON. Write the new state sidecar with NEW.
#
# Manual entries (non-absolute globs in allow, absolute paths in
# additionalDirectories that this script never installed) are preserved
# untouched — the script only removes paths it tracked itself or inherited
# from the documented pre-migration shape.
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
STATE="$REPO_ROOT/.juvant/.sync-project-globs.state.json"
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

# ── Step 1: collect NEW set of working-tree paths from config ─────────────
# Each project contributes: working_tree (if non-empty) + additional_working_trees[].
# Uses while-read loop for bash 3.2 compatibility (BUG-031).
NEW_PATHS=()
while IFS= read -r line; do
  NEW_PATHS+=("$line")
done < <(
  jq -r '
    .projects
    | to_entries[]
    | .value
    | [ (.working_tree // empty) ] + (.additional_working_trees // [])
    | .[]
    | select(length > 0)
  ' "$CONFIG" 2>/dev/null || true
)

if [[ "${#NEW_PATHS[@]}" -eq 0 ]]; then
  echo "[sync-project-globs] no projects with working_tree configured — nothing to add"
  # Still proceed: the operator may have just removed the last project, in
  # which case we should still strip previously-managed entries from settings.
fi

if [[ "${#NEW_PATHS[@]}" -gt 0 ]]; then
  echo "[sync-project-globs] found ${#NEW_PATHS[@]} project working tree(s):"
  for wt in "${NEW_PATHS[@]}"; do
    echo "  $wt"
  done
fi

# ── Step 2: serialize NEW as a JSON array for jq ──────────────────────────
# Bash 3.2-safe: `printf` on an empty array still emits a newline, which jq
# would turn into [""]. Guard the empty case explicitly.
if [[ "${#NEW_PATHS[@]}" -eq 0 ]]; then
  NEW_PATHS_JSON='[]'
else
  NEW_PATHS_JSON=$(printf '%s\n' "${NEW_PATHS[@]}" | jq -R . | jq -s 'unique')
fi

# ── Step 3: load OLD set from the state sidecar ───────────────────────────
if [[ -f "$STATE" ]]; then
  OLD_PATHS_JSON=$(jq '.managed_paths // []' "$STATE")
else
  OLD_PATHS_JSON='[]'
fi

# ── Step 4: migration — infer prior-script-managed paths from settings ────
# Any entry in permissions.allow of shape (Read|Grep|Glob)(/abs/**) was
# installed by an earlier revision of this script (sentinel-era or pre-
# sentinel). Add their /abs prefix to REMOVE so the migration cleanly
# rewrites the block without leaving duplicates.
MIGRATION_PATHS_JSON=$(jq '
  .permissions.allow // []
  | map(capture("^(?:Read|Grep|Glob)\\((?<p>/[^)]*)/\\*\\*\\)$"; "x") | .p)
  | unique
' "$SETTINGS")

REMOVE_PATHS_JSON=$(jq -n \
  --argjson old "$OLD_PATHS_JSON" \
  --argjson mig "$MIGRATION_PATHS_JSON" \
  '($old + $mig) | unique')

# ── Step 5: dry-run report ────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[sync-project-globs] DRY RUN — would remove paths previously managed:"
  echo "$REMOVE_PATHS_JSON" | jq -r '.[]' | sed 's/^/  /'
  echo "[sync-project-globs] DRY RUN — would add (or re-add) Read/Grep/Glob entries for:"
  echo "$NEW_PATHS_JSON" | jq -r '.[]' | sed 's/^/  /'
  echo "[sync-project-globs] DRY RUN — would add (or re-add) additionalDirectories entries for:"
  echo "$NEW_PATHS_JSON" | jq -r '.[]' | sed 's/^/  /'
  exit 0
fi

# ── Step 6: transform settings.json via jq (strict JSON in, strict JSON out) ─
# Notes on the jq program:
# - `.permissions //= {}` and `.permissions.additionalDirectories //= []`
#   create the keys if absent, preserving everything else.
# - For each removed path P we drop:
#     * any entry in permissions.allow equal to "Read(P/**)" / "Grep(P/**)" / "Glob(P/**)"
#     * any entry in permissions.additionalDirectories equal to P
# - We then append the new entries.
# - `unique_by(.)` would re-sort; instead we use a small reducer to dedupe
#   while preserving first-occurrence order — manual entries keep their slot.
UPDATED_SETTINGS=$(jq \
  --argjson remove "$REMOVE_PATHS_JSON" \
  --argjson add "$NEW_PATHS_JSON" \
  '
  # Build the set of allow-list strings to drop, derived from `remove`.
  ($remove | map(["Read(\(.)/**)", "Grep(\(.)/**)", "Glob(\(.)/**)"]) | add // []) as $drop_allow
  | ($add    | map(["Read(\(.)/**)", "Grep(\(.)/**)", "Glob(\(.)/**)"]) | add // []) as $add_allow
  | .permissions //= {}
  | .permissions.allow //= []
  | .permissions.additionalDirectories //= []
  | .permissions.allow = (
      (.permissions.allow | map(select(IN($drop_allow[]) | not)))
      + $add_allow
    )
  | .permissions.additionalDirectories = (
      (.permissions.additionalDirectories | map(select(IN($remove[]) | not)))
      + $add
    )
  # Dedupe both arrays preserving first-occurrence order.
  | .permissions.allow = (
      reduce .permissions.allow[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end)
    )
  | .permissions.additionalDirectories = (
      reduce .permissions.additionalDirectories[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end)
    )
  ' "$SETTINGS")

# Validate the jq output is strict JSON before writing — defence in depth.
if ! echo "$UPDATED_SETTINGS" | jq empty &>/dev/null; then
  echo "[sync-project-globs] FATAL: jq transform produced invalid JSON — refusing to write" >&2
  exit 1
fi

# Atomic write: temp file then mv.
TMP="$SETTINGS.tmp.$$"
echo "$UPDATED_SETTINGS" > "$TMP"
mv "$TMP" "$SETTINGS"

# ── Step 7: persist the state sidecar with NEW for the next run ───────────
mkdir -p "$(dirname "$STATE")"
STATE_TMP="$STATE.tmp.$$"
jq -n --argjson paths "$NEW_PATHS_JSON" \
  '{version: 1, managed_paths: $paths}' > "$STATE_TMP"
mv "$STATE_TMP" "$STATE"

echo "[sync-project-globs] updated $SETTINGS (strict JSON, pattern-managed entries)"
if [[ "${#NEW_PATHS[@]}" -gt 0 ]]; then
  echo "[sync-project-globs] managed permissions.allow entries:"
  echo "$NEW_PATHS_JSON" | jq -r '.[] | "  Read(\(.)/**)\n  Grep(\(.)/**)\n  Glob(\(.)/**)"'
  echo "[sync-project-globs] managed permissions.additionalDirectories entries:"
  echo "$NEW_PATHS_JSON" | jq -r '.[]' | sed 's/^/  /'
else
  echo "[sync-project-globs] no working trees configured — any previously-managed entries have been removed"
fi
echo "[sync-project-globs] state sidecar: $STATE"
