#!/usr/bin/env bash
# helpers/kb-coverage.sh
# Knowledge_base coverage audit per OP-007 + handbook ADR 0004 § audit-reconcile.
#
# For a given project (slug), enumerate the canonical decision-bearing
# sources in juvantio/<project>-pm and diff against DISTINCT source_ref
# values in knowledge_base. Surface gaps for material decisions that
# should be in KB but aren't.
#
# Usage:
#   ./helpers/kb-coverage.sh <project-slug>
#   ./helpers/kb-coverage.sh hardys
#
# Exit codes: 0 = in sync, 1 = gap detected, 2 = error.
#
# Sources enumerated (canonical "material decisions" per OP-007):
#   - All ADR files in <project>-pm/docs/decisions/ADR-*.md
#   - All ARCH-* GitHub issues (open + closed)
#   - All non-README files in <project>-pm/docs/analysis/
#   - All non-README files in <project>-pm/docs/research/
#
# Sources EXCLUDED (not material decisions per spec):
#   - <project>-pm/docs/technical/* (operational reference, not decisions)
#   - <project>-pm/docs/templates/* (meta, not decisions)
#   - M-* / P-* / R-* / TECH-* / OP-* GitHub issues (work-tracking,
#     not material decisions — promoted ad-hoc via CHRO flow if any
#     contain rich rationale)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

PROJECT="${1:-}"
if [[ -z "$PROJECT" ]]; then
  echo "Usage: $0 <project-slug>" >&2
  exit 2
fi

TURSO_DB_NAME=$(jq -r '.turso_db_name // ""' "$CONFIG" 2>/dev/null || echo "")
PM_REPO=$(jq -r --arg p "$PROJECT" '.projects[$p].pm_repo // ""' "$CONFIG" 2>/dev/null || echo "")
if [[ -z "$TURSO_DB_NAME" || -z "$PM_REPO" ]]; then
  echo "[kb-coverage] FATAL: missing turso_db_name or projects.${PROJECT}.pm_repo in $CONFIG" >&2
  exit 2
fi

echo "[kb-coverage] Project: $PROJECT (pm_repo: $PM_REPO)"

# 1. Enumerate canonical sources

# 1a. ADR files
# Canonical source_ref form is short — ADR-NNN — not the full filename slug
# ADR-NNN-title-words. Reason: ADR filenames may rename if titles are
# refined; short form is stable across renames + matches the schema example
# (scripts/schema.sql §knowledge_base source_ref docstring).
ADRS=$(gh api "repos/$PM_REPO/contents/docs/decisions" 2>/dev/null \
  | jq -r '.[] | select(.name | startswith("ADR-")) | .name' 2>/dev/null \
  | sed -E 's|\.md$||' \
  | sed -E 's|^(ADR-[0-9]+).*$|\1|' \
  | sed "s|^|$PM_REPO/docs/decisions/|" \
  | sort -u)

# 1b. ARCH-* issues
ARCH_ISSUES=$(gh issue list --repo "$PM_REPO" --search "ARCH" --state all --limit 200 \
  --json number,title 2>/dev/null \
  | jq -r '.[] | select(.title | startswith("ARCH")) | "\(.number)"' 2>/dev/null \
  | sed "s|^|$PM_REPO#|" \
  | sort -u)

# 1c. Analysis + research docs
ANALYSIS=$(gh api "repos/$PM_REPO/contents/docs/analysis" 2>/dev/null \
  | jq -r '.[] | select(.name | endswith(".md")) | select(.name != "README.md") | .name' 2>/dev/null \
  | sed -E 's|\.md$||' \
  | sed "s|^|$PM_REPO/docs/analysis/|" \
  | sort -u || true)
RESEARCH=$(gh api "repos/$PM_REPO/contents/docs/research" 2>/dev/null \
  | jq -r '.[] | select(.name | endswith(".md")) | select(.name != "README.md") | .name' 2>/dev/null \
  | sed -E 's|\.md$||' \
  | sed "s|^|$PM_REPO/docs/research/|" \
  | sort -u || true)

CANONICAL=$(printf "%s\n%s\n%s\n%s\n" "$ADRS" "$ARCH_ISSUES" "$ANALYSIS" "$RESEARCH" | grep -v '^$' | sort -u)

CANONICAL_COUNT=$(echo "$CANONICAL" | wc -l | tr -d ' ')
echo "[kb-coverage] Canonical sources: $CANONICAL_COUNT (ADRs + ARCH issues + analysis + research)"

# 2. Enumerate KB rows for this project
# `turso db shell` prints a "SOURCE REF" header line and pads each
# value with trailing spaces for column alignment. Skip header
# (tail -n +2) and trim trailing whitespace before sort/comm-ing.
KB_REFS=$(turso db shell "$TURSO_DB_NAME" \
  "SELECT DISTINCT source_ref FROM knowledge_base WHERE source_project='$PROJECT' AND source_ref IS NOT NULL;" \
  2>/dev/null | tail -n +2 | sed 's/[[:space:]]*$//' | sort -u)

KB_COUNT=$(echo "$KB_REFS" | grep -c '.' || true)
echo "[kb-coverage] KB rows for $PROJECT (with source_ref): $KB_COUNT"

# 3. Diff
MISSING=$(comm -23 <(echo "$CANONICAL") <(echo "$KB_REFS"))
ORPHAN=$(comm -13 <(echo "$CANONICAL") <(echo "$KB_REFS"))
MISSING_COUNT=$(echo "$MISSING" | grep -c '.' || true)
ORPHAN_COUNT=$(echo "$ORPHAN" | grep -c '.' || true)

echo ""
echo "=== Coverage report — $PROJECT ==="
echo ""
if [[ "$MISSING_COUNT" -eq 0 && "$ORPHAN_COUNT" -eq 0 ]]; then
  echo "✓ IN SYNC. All canonical sources have a KB row, no orphan references."
  exit 0
fi

if [[ "$MISSING_COUNT" -gt 0 ]]; then
  echo "⚠️  $MISSING_COUNT canonical source(s) NOT in KB (gap):"
  echo "$MISSING" | grep -v '^$' | sed 's|^|  - |'
fi
echo ""
if [[ "$ORPHAN_COUNT" -gt 0 ]]; then
  echo "⚠️  $ORPHAN_COUNT KB row(s) reference a source NOT in canonical list (orphan):"
  echo "$ORPHAN" | grep -v '^$' | sed 's|^|  - |'
  echo ""
  echo "Note: orphans may be legitimate (e.g. M-* issues promoted ad-hoc via CHRO"
  echo "flow per OP-007), but verify each. If a row references a deleted/renamed"
  echo "source, supersede with category='retracted' rationale."
fi

echo ""
echo "Remediation:"
echo "  - Missing: route via CHRO knowledge-promotion flow (CHRO proposes → CA"
echo "    validates → CEO approves → CRO commits as KB row with source_ref)."
echo "  - Orphans: review each in 'decisions' category='kb-orphan-review'."

exit 1
