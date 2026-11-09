#!/usr/bin/env bash
# setup.sh — create a juvant-os v2 company repo. Run it from a clone of
# juvant-os at a v2 tag:
#
#   bash setup.sh <company-dir> [--company NAME] [--ceo NAME] [--cos NAME]
#                 [--language LANG] [--legal NAME] [--finance NAME] [--ethics NAME]
#                 [--country CODE]   e.g. it: installs framework/countries/it/ if it exists
#
# Copies the templates (CLAUDE.md, manifesto.md, roles/, .claude/settings.json,
# .gitignore) once, installs the framework into .claude/ through the update
# script, and creates memory/ and state/. Placeholders it isn't given stay as
# {{…}}: the Chief of Staff fills them with the CEO in the first session.
# Refuses on a juvant-os v1 instance, on an existing v2 install, and on any
# template file that already exists. Nothing is committed.
#
#   bash setup.sh --project-repo <repo> --company-dir <company-repo> --project <slug>
#                 [--shared-with "<who>"]
#
# The same as asking the Chief of Staff to link a repository to a project (the
# project-repo skill, which this calls): useful in scripts and migrations.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FW="$HERE/framework"

if [[ "${1:-}" == "--project-repo" ]]; then
  PR=""; CD=""; SLUG=""; SHARED=""
  while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || { echo "setup: $1 needs a value" >&2; exit 2; }
    case "$1" in
      --project-repo) PR="$2" ;; --company-dir) CD="$2" ;; --project) SLUG="$2" ;; --shared-with) SHARED="$2" ;;
      *) echo "setup: unknown option $1" >&2; exit 2 ;;
    esac
    shift 2
  done
  [[ -n "$PR" && -n "$CD" && -n "$SLUG" ]] || { echo "setup: --project-repo needs --company-dir and --project" >&2; exit 2; }
  [[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]{0,60}$ ]] || { echo "setup: bad project slug '$SLUG'" >&2; exit 2; }
  [[ -f "$CD/.claude/skills/project-repo/project-repo.sh" ]] || { echo "setup: $CD is not a juvant-os v2 company repo" >&2; exit 1; }
  # One implementation: the company's own project-repo skill (the CoS runs the same one).
  if [[ -n "$SHARED" ]]; then
    exec bash "$CD/.claude/skills/project-repo/project-repo.sh" install "$PR" --project "$SLUG" --shared-with "$SHARED"
  fi
  exec bash "$CD/.claude/skills/project-repo/project-repo.sh" install "$PR" --project "$SLUG"
fi

[[ $# -ge 1 && "$1" != -* ]] || { sed -n '2,20p' "$0" >&2; exit 2; }
TARGET="$1"; shift
declare -a SUBS=(); COUNTRY=""
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || { echo "setup: $1 needs a value" >&2; exit 2; }
  case "$1" in
    --company) SUBS+=("COMPANY=$2") ;;
    --ceo) SUBS+=("CEO_NAME=$2") ;;
    --cos) SUBS+=("COS_NAME=$2") ;;
    --language) SUBS+=("CEO_LANGUAGE=$2") ;;
    --legal) SUBS+=("LEGAL_NAME=$2") ;;
    --finance) SUBS+=("FINANCE_NAME=$2") ;;
    --ethics) SUBS+=("ETHICS_NAME=$2") ;;
    --country) COUNTRY="$2" ;;
    *) echo "setup: unknown option $1" >&2; exit 2 ;;
  esac
  shift 2
done

[[ -z "$COUNTRY" || "$COUNTRY" =~ ^[a-z]{2}(-[a-z]+)?$ ]] || { echo "setup: bad country code '$COUNTRY' (use a lowercase ISO code such as it, fr, de)" >&2; exit 2; }
mkdir -p "$TARGET"; TARGET="$(cd "$TARGET" && pwd)"
[[ -d "$TARGET/.juvant" ]] && { echo "setup: $TARGET is a juvant-os v1 instance (.juvant/ exists). Migrate it instead." >&2; exit 1; }
[[ -f "$TARGET/.claude/juvant-os.json" ]] && { echo "setup: juvant-os v2 is already installed in $TARGET. Use the update skill." >&2; exit 1; }

pairs=(
  "templates/CLAUDE.md:CLAUDE.md"
  "templates/manifesto.md:manifesto.md"
  "templates/roles/legal.md:roles/legal.md"
  "templates/roles/finance.md:roles/finance.md"
  "templates/roles/ethics.md:roles/ethics.md"
  "templates/settings.json:.claude/settings.json"
  "templates/gitignore:.gitignore"
)
for p in "${pairs[@]}"; do
  [[ -e "$TARGET/${p##*:}" ]] && { echo "setup: $TARGET/${p##*:} already exists. Move it away first; setup never overwrites." >&2; exit 1; }
done
for p in "${pairs[@]}"; do
  mkdir -p "$(dirname "$TARGET/${p##*:}")"
  cp "$FW/${p%%:*}" "$TARGET/${p##*:}"
done

# Fill the placeholders we were given (literal replacement, any characters).
if [[ ${#SUBS[@]} -gt 0 ]]; then
  python3 - "$TARGET" "${SUBS[@]}" <<'PY'
import sys, pathlib
root = pathlib.Path(sys.argv[1])
subs = dict(a.split("=", 1) for a in sys.argv[2:])
for rel in ("CLAUDE.md", "manifesto.md", "roles/legal.md", "roles/finance.md", "roles/ethics.md"):
    p = root / rel
    text = p.read_text(encoding="utf-8")
    for k, v in subs.items():
        text = text.replace("{{" + k + "}}", v)
    p.write_text(text, encoding="utf-8")
PY
fi

mkdir -p "$TARGET/memory/decisions" "$TARGET/memory/knowledge" "$TARGET/memory/journal" "$TARGET/state" "$TARGET/docs"
[[ -e "$TARGET/docs/README.md" ]] || printf '# Documents\n\nLong documents of the company: ADRs, policies, standards, evaluations. Decisions in memory/decisions/ link to them.\n' > "$TARGET/docs/README.md"
[[ -e "$TARGET/memory/README.md" ]] || cp "$FW/templates/memory-README.md" "$TARGET/memory/README.md"
[[ -e "$TARGET/memory/map.md" ]] || printf '# Where things live\n\nNever put secrets here.\n\n| What | Where |\n|---|---|\n' > "$TARGET/memory/map.md"
for d in decisions knowledge journal; do [[ -e "$TARGET/memory/$d/.gitkeep" ]] || : > "$TARGET/memory/$d/.gitkeep"; done
[[ -e "$TARGET/state/.gitkeep" ]] || : > "$TARGET/state/.gitkeep"

if [[ -n "$COUNTRY" ]]; then
  bash "$FW/skills/update/update.sh" --from "$FW" --target "$TARGET" --country "$COUNTRY" | grep -i 'country' || true
else
  bash "$FW/skills/update/update.sh" --from "$FW" --target "$TARGET" >/dev/null
  echo "setup: no country pack chosen. Skills stay country-neutral; add one later with: bash .claude/skills/update/update.sh --country <code> <tag>"
fi

left=$(grep -ho '{{[A-Z_]*}}' "$TARGET/CLAUDE.md" "$TARGET/manifesto.md" "$TARGET"/roles/*.md 2>/dev/null | sort -u | tr '\n' ' ' || true)
echo "setup: juvant-os v2 installed in $TARGET ($(sed -n 's/.*"version": "\(.*\)".*/\1/p' "$TARGET/.claude/juvant-os.json"))."
[[ -n "$left" ]] && echo "setup: placeholders to fill in the first session: $left"
echo "setup: next: cd $TARGET && git init (if new), then start the Chief of Staff with a fixed name so collaborator sessions can reach it: claude --name cos --remote-control. Nothing is committed yet."
