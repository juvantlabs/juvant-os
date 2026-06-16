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
# field, emit absolute Read/Grep/Glob entries in permissions.allow AND add
# the working-tree path to permissions.additionalDirectories. Both are
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

# Build two JSON arrays:
#   GLOBS — Read/Grep/Glob allow-list entries. Removes the permission *prompt*.
#   DIRS  — bare working-tree paths for permissions.additionalDirectories.
#           Extends the harness filesystem *sandbox* (project subagents run
#           confined to cwd + additionalDirectories + /tmp). The allow-list
#           alone is NOT sufficient: it silences the prompt, but the sandbox
#           still denies a sibling-repo read for subagents. Both are required
#           (BUG-042).
NEW_GLOBS_JSON="[]"
NEW_DIRS_JSON="[]"
for wt in "${WORKING_TREES[@]}"; do
  NEW_GLOBS_JSON=$(jq -n \
    --argjson existing "$NEW_GLOBS_JSON" \
    --arg wt "$wt" \
    '$existing + ["Read(\($wt)/**)", "Grep(\($wt)/**)", "Glob(\($wt)/**)"]'
  )
  NEW_DIRS_JSON=$(jq -n \
    --argjson existing "$NEW_DIRS_JSON" \
    --arg wt "$wt" \
    '$existing + [$wt]'
  )
done
PAYLOAD_JSON=$(jq -n --argjson globs "$NEW_GLOBS_JSON" --argjson dirs "$NEW_DIRS_JSON" \
  '{globs: $globs, dirs: $dirs}')

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[sync-project-globs] DRY RUN — would manage permissions.allow with:"
  echo "$NEW_GLOBS_JSON" | jq -r '.[]' | sed 's/^/  /'
  echo "[sync-project-globs] DRY RUN — would manage permissions.additionalDirectories with:"
  echo "$NEW_DIRS_JSON" | jq -r '.[]' | sed 's/^/  /'
  exit 0
fi

# Apply sentinel-aware text surgery via Python (bash 3.2-safe, no extra deps).
#
# Sentinel mode (block already present): replace only the content between
# // [sync-project-globs:start] and // [sync-project-globs:end].
#
# First-run migration mode (no sentinels): strip the old absolute-path
# Read/Grep/Glob entries, re-serialize, and append the sentinel block.
UPDATED_SETTINGS=$(python3 - "$SETTINGS" "$PAYLOAD_JSON" <<'PYEOF'
import json, re, sys

path    = sys.argv[1]
payload = json.loads(sys.argv[2])
globs   = payload["globs"]
dirs    = payload["dirs"]

A_START = "// [sync-project-globs:start]"
A_END   = "// [sync-project-globs:end]"
D_START = "// [sync-project-globs:addir:start]"
D_END   = "// [sync-project-globs:addir:end]"

ENTRY_INDENT = "      "  # 6 spaces: array entries
KEY_INDENT   = "    "    # 4 spaces: keys under "permissions"

def build_block(start, end, items, indent=ENTRY_INDENT):
    lines = [f"{indent}{start}"]
    for e in items:
        lines.append(f'{indent}"{e}",')
    lines.append(f"{indent}{end}")
    return "\n".join(lines)

text = open(path).read()

# ── permissions.allow — Read/Grep/Glob globs (BUG-032 sentinel approach) ──
if A_START in text and A_END in text:
    # Sentinel block present — replace only its contents, preserve indent.
    idx    = text.index(A_START)
    lstart = text.rfind('\n', 0, idx) + 1
    indent = text[lstart:idx]
    pat = re.compile(
        re.escape(indent) + re.escape(A_START) + r'.*?' + re.escape(indent) + re.escape(A_END),
        re.DOTALL
    )
    text = pat.sub(build_block(A_START, A_END, globs, indent), text)
else:
    # First-run migration: parse as clean JSON, strip old auto-absolute entries,
    # re-serialize, splice in sentinel block.
    data  = json.loads(text)
    allow = data.get("permissions", {}).get("allow", [])
    kept  = [e for e in allow if not re.match(r'^(Read|Grep|Glob)\(/', str(e))]
    data.setdefault("permissions", {})["allow"] = kept
    base  = json.dumps(data, indent=2)
    new_block = build_block(A_START, A_END, globs)
    if kept:
        # Insert ",\n<block>" before the closing "]" of the "allow" array
        # SPECIFICALLY — not the first "    ]" in the document, which may be
        # a preceding array (e.g. additionalDirectories) (BUG-042).
        am      = re.search(r'"allow"\s*:\s*\[', base)
        a_close = base.index('\n    ]', am.end() - 1)
        text    = base[:a_close] + ',\n' + new_block + base[a_close:]
    else:
        # Empty allow array: replace [] with [\n<block>\n    ].
        text = re.sub(
            r'"allow":\s*\[\s*\]',
            '"allow": [\n' + new_block + '\n    ]',
            base, count=1
        )

# ── permissions.additionalDirectories — sandbox extension (BUG-042) ──
# Pure text surgery (comment-safe): this runs after the allow block above,
# whose // sentinel comments make the file invalid strict JSON, so we must
# never re-parse here.
if D_START in text and D_END in text:
    idx    = text.index(D_START)
    lstart = text.rfind('\n', 0, idx) + 1
    indent = text[lstart:idx]
    pat = re.compile(
        re.escape(indent) + re.escape(D_START) + r'.*?' + re.escape(indent) + re.escape(D_END),
        re.DOTALL
    )
    text = pat.sub(build_block(D_START, D_END, dirs, indent), text)
else:
    addir_block = build_block(D_START, D_END, dirs)
    m = re.search(r'"additionalDirectories"\s*:\s*\[', text)
    if m:
        # Array exists without our sentinel — splice block in, preserve manual entries.
        open_idx  = m.end() - 1
        close_idx = text.index(']', open_idx)
        inner     = text[open_idx + 1:close_idx]
        if inner.strip() == "":
            new_inner = "\n" + addir_block + "\n" + KEY_INDENT
        else:
            trimmed   = inner.rstrip()
            sep       = "" if trimmed.endswith(",") else ","
            new_inner = trimmed + sep + "\n" + addir_block + "\n" + KEY_INDENT
        text = text[:open_idx + 1] + new_inner + text[close_idx:]
    else:
        # Key absent — create it as the first child of "permissions".
        pm = re.search(r'"permissions"\s*:\s*\{[ \t]*\n', text)
        if not pm:
            sys.stderr.write("[sync-project-globs] FATAL: cannot locate permissions object to add additionalDirectories\n")
            sys.exit(1)
        insert = KEY_INDENT + '"additionalDirectories": [\n' + addir_block + '\n' + KEY_INDENT + '],\n'
        text = text[:pm.end()] + insert + text[pm.end():]

print(text, end="")
PYEOF
)

echo "$UPDATED_SETTINGS" > "$SETTINGS"
echo "[sync-project-globs] updated $SETTINGS (allow + additionalDirectories sentinel blocks)"
echo "[sync-project-globs] managed permissions.allow:"
echo "$NEW_GLOBS_JSON" | jq -r '.[]' | sed 's/^/  /'
echo "[sync-project-globs] managed permissions.additionalDirectories:"
echo "$NEW_DIRS_JSON" | jq -r '.[]' | sed 's/^/  /'
