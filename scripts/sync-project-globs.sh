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
# Idempotent — safe to run multiple times.
#
# Sentinel-comment approach (BUG-032):
# The script manages ONLY the content between two sentinel comment lines:
#   // [sync-project-globs:start]
#   ...auto-generated entries...
#   // [sync-project-globs:end]
# Entries outside the sentinels are never touched. Manually-curated paths,
# PM repos, and any other absolute-path entries added by hand are preserved.
#
# First run on an existing instance (no sentinels present): strips the old
# absolute-path block (Read/Grep/Glob starting with /) and inserts the
# sentinel-wrapped block. Any manually-added absolute entries will need to
# be re-added once after this migration; subsequent runs preserve them.
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
# Uses while-read loop for bash 3.2 compatibility (BUG-031).
WORKING_TREES=()
while IFS= read -r line; do
  WORKING_TREES+=("$line")
done < <(
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

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[sync-project-globs] DRY RUN — would manage sentinel block with:"
  echo "$NEW_GLOBS_JSON" | jq -r '.[]' | sed 's/^/  /'
  exit 0
fi

# Apply sentinel-aware text surgery via Python (bash 3.2-safe, no extra deps).
#
# Sentinel mode (block already present): replace only the content between
# // [sync-project-globs:start] and // [sync-project-globs:end].
#
# First-run migration mode (no sentinels): strip the old absolute-path
# Read/Grep/Glob entries, re-serialize, and append the sentinel block.
UPDATED_SETTINGS=$(python3 - "$SETTINGS" "$NEW_GLOBS_JSON" <<'PYEOF'
import json, re, sys

path    = sys.argv[1]
entries = json.loads(sys.argv[2])

START = "// [sync-project-globs:start]"
END   = "// [sync-project-globs:end]"

ENTRY_INDENT = "      "  # 6 spaces: 2-space jq indent × 3 levels

def build_block(entries, indent=ENTRY_INDENT):
    lines = [f"{indent}{START}"]
    for e in entries:
        lines.append(f'{indent}"{e}",')
    lines.append(f"{indent}{END}")
    return "\n".join(lines)

text = open(path).read()

if START in text and END in text:
    # Sentinel block present — replace only its contents, preserve indent.
    idx    = text.index(START)
    lstart = text.rfind('\n', 0, idx) + 1
    indent = text[lstart:idx]
    pat = re.compile(
        re.escape(indent) + re.escape(START) + r'.*?' + re.escape(indent) + re.escape(END),
        re.DOTALL
    )
    result = pat.sub(build_block(entries, indent), text)
else:
    # First-run migration: parse as clean JSON, strip old auto-absolute entries,
    # re-serialize, splice in sentinel block.
    data  = json.loads(text)
    allow = data.get("permissions", {}).get("allow", [])
    kept  = [e for e in allow if not re.match(r'^(Read|Grep|Glob)\(/', str(e))]
    data.setdefault("permissions", {})["allow"] = kept
    base  = json.dumps(data, indent=2)

    new_block = build_block(entries, ENTRY_INDENT)

    if kept:
        # Insert ",\n<block>" before the closing "    ]" of allow array.
        result = re.sub(r'(\n    \])', ',\n' + new_block + r'\1', base, count=1)
    else:
        # Empty allow array: replace [] with [\n<block>\n    ].
        result = re.sub(
            r'"allow":\s*\[\s*\]',
            '"allow": [\n' + new_block + '\n    ]',
            base, count=1
        )

print(result, end="")
PYEOF
)

echo "$UPDATED_SETTINGS" > "$SETTINGS"
echo "[sync-project-globs] updated $SETTINGS (sentinel block replaced)"
echo "[sync-project-globs] managed entries:"
echo "$NEW_GLOBS_JSON" | jq -r '.[]' | sed 's/^/  /'
