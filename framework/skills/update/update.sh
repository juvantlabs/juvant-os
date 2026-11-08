#!/usr/bin/env bash
# .claude/skills/update/update.sh — install or update juvant-os v2 in a company repo.
#
#   update.sh <tag>                     fetch juvant-os at <tag> and update this repo
#   update.sh --from <framework-dir>    use a local framework/ folder (setup, tests)
#   options:  --target <company-dir>    default: the git toplevel of the current dir
#             --repo <git-url>          default: $JUVANT_OS_REPO or the public repo
#
# Copies every path in framework/FILES except templates/ into .claude/, removes
# framework files that the new version no longer ships, and records the version
# in .claude/juvant-os.json. The company's own files (CLAUDE.md, manifesto.md,
# roles/, memory/, state/, .claude/settings.json) are never touched. Nothing is
# committed: review `git status` and commit.
set -euo pipefail

REPO_URL="${JUVANT_OS_REPO:-https://github.com/juvantlabs/juvant-os.git}"
FROM=""; TAG=""; TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --repo) REPO_URL="$2"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) echo "update: unknown option $1" >&2; exit 2 ;;
    *) TAG="$1"; shift ;;
  esac
done
[[ -n "$FROM" || -n "$TAG" ]] || { echo "update: give a tag (e.g. v2.0.0) or --from <framework-dir>" >&2; exit 2; }
TARGET="${TARGET:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
TARGET="$(cd "$TARGET" && pwd)"

if [[ -d "$TARGET/.juvant" ]]; then
  echo "update: $TARGET is a juvant-os v1 instance (.juvant/ exists). v2 doesn't install over v1: migrate first." >&2; exit 1
fi

TMP=""
cleanup() { [[ -n "$TMP" ]] && rm -rf "$TMP"; return 0; }
trap cleanup EXIT
if [[ -n "$FROM" ]]; then
  FW="$(cd "$FROM" && pwd)"
  VERSION="$(git -C "$FW" describe --tags --always 2>/dev/null || echo local)"
else
  TMP="$(mktemp -d)"
  git clone -q --depth 1 --branch "$TAG" "$REPO_URL" "$TMP/src" 2>/dev/null \
    || { echo "update: cannot fetch $TAG from $REPO_URL" >&2; exit 1; }
  FW="$TMP/src/framework"; VERSION="$TAG"
fi
COMMIT="$(git -C "$FW" rev-parse --short HEAD 2>/dev/null || echo unknown)"
[[ -f "$FW/FILES" ]] || { echo "update: $FW/FILES missing: not a juvant-os v2 framework" >&2; exit 1; }

listed() { grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$1" | grep -v '^templates/' || true; }
dest_of() {
  case "$1" in
    README.md) echo ".claude/juvant-os/README.md" ;;
    agents/*|hooks/*|skills/*|dashboard/*) echo ".claude/$1" ;;
    *) return 1 ;;
  esac
}

NEW="$(listed "$FW/FILES")"
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  [[ -f "$FW/$p" ]] || { echo "update: $p is in FILES but missing from the framework" >&2; exit 1; }
  dest_of "$p" >/dev/null || { echo "update: no install location for $p" >&2; exit 1; }
done <<< "$NEW"

OLD_FILES="$TARGET/.claude/juvant-os/FILES"
removed=0
if [[ -f "$OLD_FILES" ]]; then
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    grep -qxF "$p" <<< "$NEW" && continue
    d="$(dest_of "$p" || true)"
    if [[ -n "$d" && -f "$TARGET/$d" ]]; then rm -f "$TARGET/$d"; removed=$((removed+1)); fi
  done <<< "$(listed "$OLD_FILES")"
fi

copied=0
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  d="$(dest_of "$p")"
  mkdir -p "$(dirname "$TARGET/$d")"
  cp "$FW/$p" "$TARGET/$d"; copied=$((copied+1))
done <<< "$NEW"

mkdir -p "$TARGET/.claude/juvant-os"
cp "$FW/FILES" "$OLD_FILES"
printf '{\n  "version": "%s",\n  "commit": "%s",\n  "installed": "%s"\n}\n' \
  "$VERSION" "$COMMIT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TARGET/.claude/juvant-os.json"

echo "update: juvant-os $VERSION ($COMMIT): $copied framework files installed, $removed removed."
if git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$TARGET" status --short -- .claude
fi
echo "update: nothing committed. Review the changes, then commit them."
