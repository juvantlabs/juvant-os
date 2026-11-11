#!/usr/bin/env bash
# .claude/skills/update/update.sh — install or update juvant-os v2 in a company repo.
#
#   update.sh                           install the latest published GitHub release (v2+, not pre-release)
#   update.sh <tag>                     install that release (it must be a published
#                                       GitHub release, pre-releases included)
#   options:  --target <company-dir>    default: the git toplevel of the current dir
#             --repo <github-url>       default: $JUVANT_OS_REPO or the public repo
#             --country <code>          install that country pack (e.g. it); default:
#                                       the country already recorded, if any
#
# Only official releases install: never a branch, never main. No published
# release newer than the installed one means there is nothing to update.
# (--from <framework-dir> exists only for setup.sh and the tests, which set
# JUVANT_OS_SETUP=1.)
#
# Copies every path in framework/FILES except templates/ into .claude/, removes
# framework files that the new version no longer ships, installs the company's
# country pack (framework/countries/<code>/ into .claude/country/), and records
# version and country in .claude/juvant-os.json. The company's own files (CLAUDE.md, manifesto.md,
# roles/, memory/, state/) are never touched. In .claude/settings.json only the
# hard-limits hook registration is checked: tools it must see are added to its
# matcher (a registration removed altogether is only reported), nothing else changes. Nothing is committed: review `git status` and commit.
set -euo pipefail
# The whole script sits in one { } block: bash parses it all before running, so
# installing a new version of this very file mid-run cannot derail it.
{

REPO_URL="${JUVANT_OS_REPO:-https://github.com/juvantlabs/juvant-os.git}"
FROM=""; TAG=""; TARGET=""; COUNTRY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --repo) REPO_URL="$2"; shift 2 ;;
    --country) COUNTRY="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    -*) echo "update: unknown option $1" >&2; exit 2 ;;
    *) TAG="$1"; shift ;;
  esac
done
if [[ -n "$FROM" && "${JUVANT_OS_SETUP:-}" != 1 ]]; then
  echo "update: juvant-os installs only from an official GitHub release, never from a local folder or a branch. Run update.sh [<tag>]." >&2; exit 2
fi
TARGET="${TARGET:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
TARGET="$(cd "$TARGET" && pwd)"

if [[ -d "$TARGET/.juvant" ]]; then
  echo "update: $TARGET is a juvant-os v1 instance (.juvant/ exists). v2 doesn't install over v1: migrate first." >&2; exit 1
fi

TMP=""
# shellcheck disable=SC2329  # called by the EXIT trap
cleanup() { [[ -n "$TMP" ]] && rm -rf "$TMP"; return 0; }
trap cleanup EXIT
if [[ -n "$FROM" ]]; then
  FW="$(cd "$FROM" && pwd)"
  VERSION="$(git -C "$FW" describe --tags --always 2>/dev/null || echo local)"
else
  # The release must exist on GitHub, published (not a draft).
  SLUG="${JUVANT_OS_RELEASE_SLUG:-$(sed -nE 's#^(https://|git@)github\.com[/:]([^/]+/[^/]+)$#\2#p' <<< "${REPO_URL%.git}")}"
  [[ -n "$SLUG" ]] || { echo "update: $REPO_URL is not a GitHub repository: releases can't be checked" >&2; exit 2; }
  API="${JUVANT_OS_API:-https://api.github.com}/repos/$SLUG/releases"
  published() { # <tag> [stable]: prints the tag if it is a published release (stable: not a pre-release)
    curl -fsSL "$API/tags/$1" 2>/dev/null | python3 -c '
import json, sys
try: r = json.load(sys.stdin)
except Exception: sys.exit(1)
ok = not r.get("draft") and r.get("tag_name") == sys.argv[1] and not (sys.argv[2:] and r.get("prerelease"))
print(sys.argv[1]) if ok else sys.exit(1)' "$@"
  }
  if [[ -n "$TAG" ]]; then
    published "$TAG" >/dev/null || { echo "update: $TAG is not a published release of $SLUG: nothing to install" >&2; exit 1; }
  else
    # Latest v2+ release: newest version tags first, the first published stable release wins.
    # (GitHub's own "latest" can point at a v1 release.)
    for t in $(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null | sed 's#.*refs/tags/##' | python3 -c '
import re, sys
v = [(tuple(map(int, m.groups())), t) for t in sys.stdin.read().split() if (m := re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", t)) and int(m.group(1)) >= 2]
print("\n".join(t for _, t in sorted(v, reverse=True)[:20]))'); do
      TAG="$(published "$t" stable)" && break || TAG=""
    done
    [[ -n "$TAG" ]] || { echo "update: $SLUG has no published v2 release: nothing to update."; exit 0; }
  fi
  if [[ -z "$COUNTRY" && -f "$TARGET/.claude/juvant-os.json" ]] && grep -q "\"version\": \"$TAG\"" "$TARGET/.claude/juvant-os.json"; then
    echo "update: juvant-os $TAG is already installed: nothing to update."; exit 0
  fi
  TMP="$(mktemp -d)"
  git clone -q --depth 1 --branch "$TAG" "$REPO_URL" "$TMP/src" 2>/dev/null \
    || { echo "update: cannot fetch $TAG from $REPO_URL" >&2; exit 1; }
  FW="$TMP/src/framework"; VERSION="$TAG"
fi
COMMIT="$(git -C "$FW" rev-parse --short HEAD 2>/dev/null || echo unknown)"
[[ -f "$FW/FILES" ]] || { echo "update: $FW/FILES missing: not a juvant-os v2 framework" >&2; exit 1; }

listed() { grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$1" | grep -v -e '^templates/' -e '^countries/' || true; }
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

# Country pack: the code passed now, else the one recorded at the last install.
if [[ -z "$COUNTRY" && -f "$TARGET/.claude/juvant-os.json" ]]; then
  COUNTRY="$(sed -n 's/.*"country": "\([a-z-]*\)".*/\1/p' "$TARGET/.claude/juvant-os.json")"
fi
[[ -z "$COUNTRY" || "$COUNTRY" =~ ^[a-z]{2}(-[a-z]+)?$ ]] || { echo "update: bad country code '$COUNTRY'" >&2; exit 2; }
PACK="none"
if [[ -n "$COUNTRY" ]]; then
  rm -rf "$TARGET/.claude/country"
  if [[ -d "$FW/countries/$COUNTRY" ]]; then
    mkdir -p "$TARGET/.claude/country"
    for f in "$FW/countries/$COUNTRY/"*.md; do [[ "$(basename "$f")" == _* ]] || cp "$f" "$TARGET/.claude/country/"; done
    PACK="framework"
  fi
fi

# The hard limits only see the tools their hook is registered for.
if [[ -f "$TARGET/.claude/settings.json" ]]; then
  CLAUDE_PROJECT_DIR="$TARGET" python3 "$TARGET/.claude/hooks/juvant_hooks.py" fix-registration \
    || echo "update: WARNING: couldn't check the hard-limits hook registration in .claude/settings.json. Ask the Chief of Staff to check it." >&2
fi

mkdir -p "$TARGET/.claude/juvant-os"
cp "$FW/FILES" "$OLD_FILES"
printf '{\n  "version": "%s",\n  "commit": "%s",\n  "country": "%s",\n  "country_pack": "%s",\n  "installed": "%s"\n}\n' \
  "$VERSION" "$COMMIT" "$COUNTRY" "$PACK" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TARGET/.claude/juvant-os.json"

echo "update: juvant-os $VERSION ($COMMIT): $copied framework files installed, $removed removed."
if [[ -n "$COUNTRY" && "$PACK" == none ]]; then
  echo "update: no framework country pack for '$COUNTRY'. The Chief of Staff can draft one with the CEO (country-pack skill) in country/."
elif [[ -n "$COUNTRY" ]]; then
  echo "update: country pack '$COUNTRY' installed in .claude/country/."
fi
if git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$TARGET" status --short -- .claude
fi
echo "update: nothing committed. Review the changes, then commit them."
exit 0
}
