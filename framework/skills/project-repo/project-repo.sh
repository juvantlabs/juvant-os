#!/usr/bin/env bash
# .claude/skills/project-repo/project-repo.sh — give a project's repository the
# company's hard limits, and record who outside the company reads it.
#
#   project-repo.sh install <repo> --project <slug> [--shared-with "<who>"]
#   project-repo.sh sharing <repo> "<who>"      mark the repo as read outside the company
#   project-repo.sh sharing <repo> none          mark it internal again
#   project-repo.sh status  <repo>
#
# Runs from the company repo's own .claude/ (the installed framework is the
# source: no juvant-os clone needed). install copies the framework files, the
# company's settings, a copy of the manifesto, a project .claude/CLAUDE.md and
# .claude/juvant-os-project.json. In a shared repo the hooks block pushing to the
# default branch and merging PRs, and allow only draft PRs. Nothing is committed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
COMPANY="$(cd "$HERE/../../.." && pwd)"
die() { echo "project-repo: $*" >&2; exit 1; }
[[ -f "$COMPANY/.claude/juvant-os.json" && -f "$COMPANY/manifesto.md" ]] \
  || die "run me from a juvant-os v2 company repo (.claude/skills/project-repo/); $COMPANY isn't one"

cmd="${1:-}"; repo="${2:-}"
[[ -n "$cmd" && -n "$repo" ]] || { sed -n '2,15p' "$0" >&2; exit 2; }
[[ -d "$repo" ]] || die "$repo doesn't exist"
repo="$(cd "$repo" && pwd)"
[[ "$repo" != "$COMPANY" ]] || die "that's the company repo itself"
shift 2

# Record and CLAUDE.md notice, written with Python for safe quoting.
write_record() { # <slug> <shared>
  python3 - "$repo" "$COMPANY" "$1" "$2" <<'PY'
import json, os, re, sys
repo, company, slug, shared = sys.argv[1:5]
p = os.path.join(repo, ".claude", "juvant-os-project.json")
rec = {}
if os.path.exists(p):
    with open(p, encoding="utf-8") as f:
        rec = json.load(f)
if slug:
    rec["project"] = slug
rec["company_repo"] = company
rec["shared_with"] = "" if shared.lower() == "none" else shared.strip()
with open(p, "w", encoding="utf-8") as f:
    json.dump(rec, f, indent=2, ensure_ascii=False)
    f.write("\n")
c = os.path.join(repo, ".claude", "CLAUDE.md")
text = open(c, encoding="utf-8").read()
start, end = "<!-- juvant-os:shared -->", "<!-- /juvant-os:shared -->"
text = re.sub(re.escape(start) + r".*?" + re.escape(end) + r"\n?", "", text, flags=re.S)
if rec["shared_with"]:
    notice = (f"{start}\n- **This repository is shared with {rec['shared_with']}.** Everything written here is read by them: "
              "write as for an external reader, never copy the company's memory, internal notes or opinions about partners here. "
              f"Work on a branch and open a draft PR; the CEO merges. The hooks enforce it.\n{end}\n")
    text = text.replace("- **The manifesto here is a copy.**", notice + "- **The manifesto here is a copy.**", 1)
with open(c, "w", encoding="utf-8") as f:
    f.write(text)
print(rec["shared_with"] or "internal")
PY
}

case "$cmd" in
  install)
    slug=""; shared=""
    while [[ $# -gt 0 ]]; do
      [[ $# -ge 2 ]] || die "$1 needs a value"
      case "$1" in --project) slug="$2" ;; --shared-with) shared="$2" ;; *) die "unknown option $1" ;; esac
      shift 2
    done
    [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,60}$ ]] || die "give --project <slug> (lowercase, hyphens)"
    [[ -d "$repo/.""juvant" ]] && die "$repo is a juvant-os v1 repo"
    for f in .claude/juvant-os.json .claude/juvant-os-project.json .claude/settings.json .claude/CLAUDE.md; do
      [[ -e "$repo/$f" ]] && die "$repo/$f already exists. Move it away or merge by hand; I never overwrite."
    done
    mkdir -p "$repo/.claude"
    for d in agents hooks skills dashboard juvant-os country; do
      [[ -d "$COMPANY/.claude/$d" ]] && cp -R "$COMPANY/.claude/$d" "$repo/.claude/"
    done
    cp "$COMPANY/.claude/juvant-os.json" "$repo/.claude/juvant-os.json"
    cp "$COMPANY/.claude/settings.json" "$repo/.claude/settings.json"
    cp "$COMPANY/manifesto.md" "$repo/.claude/company-manifesto.md"
    company_name="$(sed -n 's/^# \(.*\) manifesto$/\1/p' "$COMPANY/manifesto.md" | head -1)"
    cat > "$repo/.claude/CLAUDE.md" <<EOF
# Project $slug of ${company_name:-the company}

This repository belongs to project \`$slug\`. The company's rules apply here:

@company-manifesto.md

- **Memory** for this project lives in the company repo, in \`memory/projects/$slug/\` (card, decisions, knowledge, journal), not here. If the company repo is checked out next to this one, read the card before starting and propose decisions and facts for it; otherwise list them at the end of the session for the Chief of Staff to record.
- **Hard limits** are the same as in the company repo and enforced by the same hooks: outbound is draft-only, no payments or invoice issuing, no secrets in files or commands, destructive changes ask the CEO.
- **The manifesto here is a copy.** The Chief of Staff refreshes it from the company repo when it changes.
EOF
    state="$(write_record "$slug" "${shared:-none}")"
    [[ -d "$COMPANY/memory/projects/$slug" ]] || echo "project-repo: note: memory/projects/$slug doesn't exist yet in the company repo (new-project skill)."
    echo "project-repo: $repo set up for project '$slug' ($state). Nothing is committed."
    ;;
  sharing)
    who="${1:-}"; [[ -n "$who" ]] || die "sharing needs \"<who>\" or none"
    [[ -f "$repo/.claude/juvant-os-project.json" ]] || die "$repo has no juvant-os project setup; run install first"
    state="$(write_record "" "$who")"
    if [[ "$state" == internal ]]; then
      echo "project-repo: $repo is now internal: the shared-repo rules no longer apply."
    else
      echo "project-repo: $repo is now shared with $state: pushes to the default branch and PR merges are blocked."
    fi
    ;;
  status)
    [[ -f "$repo/.claude/juvant-os-project.json" ]] || die "$repo has no juvant-os project setup"
    cat "$repo/.claude/juvant-os-project.json"
    ;;
  *) die "unknown command $cmd (install, sharing, status)" ;;
esac
