#!/usr/bin/env bash
# setup.sh and the update script: fresh install, refusals, placeholders, and an
# update between two tags of a local framework repo that changes only FILES paths.
set -uo pipefail
export JUVANT_OS_DEV=1  # setup from this working copy, not a release
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS+1)); }
no() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
g() { git -c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=main "$@"; }

echo "== setup"
C="$T/acme"
# shellcheck disable=SC2034  # read inside check()'s eval
out=$(bash "$ROOT/setup.sh" "$C" --company "Acme & Co" --ceo "Ada Rossi" --cos Nora --language Italian 2>&1); rc=$?
check "setup exits 0" "[[ $rc == 0 ]]"
check "CLAUDE.md filled (special characters kept)" "grep -q 'Acme & Co — Chief of Staff' '$C/CLAUDE.md' && grep -q 'You are Nora' '$C/CLAUDE.md'"
check "unfilled placeholders listed" "[[ \"\$out\" == *'{{LEGAL_NAME}}'* ]]"
check "framework in .claude/" "[[ -f '$C/.claude/hooks/juvant_hooks.py' && -f '$C/.claude/agents/legal.md' && -f '$C/.claude/skills/decision/SKILL.md' ]]"
check "settings from the template" "cmp -s '$ROOT/framework/templates/settings.json' '$C/.claude/settings.json'"
check "memory README installed" "[[ -f '$C/memory/README.md' ]] && cmp -s '$ROOT/framework/templates/memory-README.md' '$C/memory/README.md'"
check "memory and state created" "[[ -d '$C/memory/decisions' && -d '$C/memory/journal' && -f '$C/memory/map.md' && -d '$C/state' ]]"
check "version recorded" "grep -q '\"version\"' '$C/.claude/juvant-os.json'"
check "templates not copied into .claude/" "[[ ! -e '$C/.claude/templates' ]]"

echo "== setup refusals"
bash "$ROOT/setup.sh" "$C" >/dev/null 2>&1; check "second setup refused" "[[ $? == 1 ]]"
mkdir -p "$T/v1/.juvant"; bash "$ROOT/setup.sh" "$T/v1" >/dev/null 2>&1; check "v1 instance refused" "[[ $? == 1 && ! -e '$T/v1/CLAUDE.md' ]]"
mkdir -p "$T/mine"; echo "my own" > "$T/mine/CLAUDE.md"; bash "$ROOT/setup.sh" "$T/mine" >/dev/null 2>&1
check "existing CLAUDE.md never overwritten" "[[ \$? == 1 && \$(cat '$T/mine/CLAUDE.md') == 'my own' ]]"

echo "== country packs"
K="$T/withit"; bash "$ROOT/setup.sh" "$K" --country it >/dev/null 2>&1
check "setup --country it records the country" "grep -q '\"country\": \"it\"' '$K/.claude/juvant-os.json' && grep -q '\"country_pack\": \"framework\"' '$K/.claude/juvant-os.json'"
check "Italian pack installed" "[[ -f '$K/.claude/country/legal.md' && -f '$K/.claude/country/finance.md' && -f '$K/.claude/country/locale.md' ]]"
check "no temporary pack files installed" "! ls '$K/.claude/country/' | grep -q '^_'"
N="$T/withde"; bash "$ROOT/setup.sh" "$N" --country de >/dev/null 2>&1
check "unknown country: recorded, no pack" "grep -q '\"country\": \"de\"' '$N/.claude/juvant-os.json' && grep -q '\"country_pack\": \"none\"' '$N/.claude/juvant-os.json' && [[ ! -d '$N/.claude/country' ]]"
check "no --country: no pack" "[[ ! -d '$C/.claude/country' ]] && grep -q '\"country\": \"\"' '$C/.claude/juvant-os.json'"
bash "$ROOT/setup.sh" "$T/badcc" --country 'it;rm' >/dev/null 2>&1; check "bad country code refused" "[[ \$? != 0 ]]"

echo "== project code repo"
PRJ="$T/helix-code"; mkdir -p "$PRJ"; echo "# Helix" > "$PRJ/README.md"
bash "$ROOT/setup.sh" --project-repo "$PRJ" --company-dir "$C" --project helix >/dev/null 2>&1; rc=$?
check "project repo setup exits 0" "[[ $rc == 0 ]]"
check "hooks and settings installed" "[[ -f '$PRJ/.claude/hooks/juvant_hooks.py' && -f '$PRJ/.claude/settings.json' ]]"
check "company manifesto copied" "cmp -s '$C/manifesto.md' '$PRJ/.claude/company-manifesto.md'"
check "project CLAUDE.md points to the project memory" "grep -q 'memory/projects/helix/' '$PRJ/.claude/CLAUDE.md' && grep -q '@company-manifesto.md' '$PRJ/.claude/CLAUDE.md'"
check "own README untouched" "[[ \$(cat '$PRJ/README.md') == '# Helix' ]]"
SH="$T/helix-pm"; mkdir -p "$SH"
bash "$ROOT/setup.sh" --project-repo "$SH" --company-dir "$C" --project helix --shared-with 'the co-founders "A&B"' >/dev/null 2>&1
check "shared repo recorded (quotes kept as valid JSON)" "python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))[\"shared_with\"] == \"the co-founders \\\"A&B\\\"\"' '$SH/.claude/juvant-os-project.json'"
check "shared repo CLAUDE.md warns the reader is external" "grep -q 'This repository is shared with' '$SH/.claude/CLAUDE.md'"
check "unshared repo has no shared warning" "! grep -q 'shared with' '$PRJ/.claude/CLAUDE.md'"
check "company repo gets docs/" "[[ -f '$C/docs/README.md' ]]"
PRS="$C/.claude/skills/project-repo/project-repo.sh"
bash "$PRS" sharing "$PRJ" "the auditors" >/dev/null
check "sharing on: record and notice" "grep -q '\"shared_with\": \"the auditors\"' '$PRJ/.claude/juvant-os-project.json' && grep -q 'shared with the auditors' '$PRJ/.claude/CLAUDE.md'"
bash "$PRS" sharing "$PRJ" "the auditors and the bank" >/dev/null
check "sharing changed: one notice only" "[[ \$(grep -c 'This repository is shared with' '$PRJ/.claude/CLAUDE.md') == 1 ]] && grep -q 'the auditors and the bank' '$PRJ/.claude/CLAUDE.md'"
bash "$PRS" sharing "$PRJ" none >/dev/null
check "sharing off: record empty, notice gone" "grep -q '\"shared_with\": \"\"' '$PRJ/.claude/juvant-os-project.json' && ! grep -q 'This repository is shared with' '$PRJ/.claude/CLAUDE.md'"
bash "$PRS" sharing "$T/plain" "x" >/dev/null 2>&1; check "sharing on a repo without setup refused" "[[ \$? != 0 ]]"
bash "$PRS" install "$C" --project x >/dev/null 2>&1; check "install into the company repo itself refused" "[[ \$? != 0 ]]"
bash "$ROOT/setup.sh" --project-repo "$PRJ" --company-dir "$C" --project helix >/dev/null 2>&1; check "second project setup refused" "[[ \$? == 1 ]]"
bash "$ROOT/setup.sh" --project-repo "$T/plain" --company-dir "$T/plain" --project x >/dev/null 2>&1; check "non-company dir refused" "[[ \$? != 0 ]]"
bash "$ROOT/setup.sh" --project-repo "$PRJ" --company-dir "$C" --project 'Bad Slug' >/dev/null 2>&1; check "bad slug refused" "[[ \$? == 2 ]]"

echo "== update between two tags"
F="$T/fw.git"; W="$T/fw"
mkdir -p "$W"; cp -R "$ROOT/framework" "$W/framework"
g -C "$W" init -q; g -C "$W" add -A; g -C "$W" commit -qm A; g -C "$W" tag v2.0.0
g clone -q --bare "$W" "$F"
U="$T/co"; bash "$ROOT/setup.sh" "$U" >/dev/null
g -C "$U" init -q; g -C "$U" add -A; g -C "$U" commit -qm setup
echo "custom company line" >> "$U/CLAUDE.md"; echo '{"mine":true}' > "$U/.claude/settings.json"; echo "x" > "$U/roles/legal.md"
g -C "$U" commit -qam "company edits"
# Version B: one hook line changed, decision skill removed, a new skill added, a template changed.
python3 - "$W/framework/hooks/juvant_hooks.py" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace("CONTEXT_CAP = 9500", "CONTEXT_CAP = 9400"))
PY
rm -r "$W/framework/skills/decision"; mkdir -p "$W/framework/skills/brief"; printf -- '---\nname: brief\ndescription: "x"\n---\n' > "$W/framework/skills/brief/SKILL.md"
echo "changed template" >> "$W/framework/templates/CLAUDE.md"
sed -i.bak -e 's#^skills/decision/SKILL.md$#skills/brief/SKILL.md#' "$W/framework/FILES"; rm "$W/framework/FILES.bak"
g -C "$W" add -A; g -C "$W" commit -qm B; g -C "$W" tag v2.0.1; g -C "$W" push -q "$F" main --tags 2>/dev/null || g -C "$F" fetch -q "$W" 'refs/tags/*:refs/tags/*'
# Fake GitHub releases API (file://): v2.0.1 is a published release, v2.0.0 is only a tag, v2.0.2 is a draft.
A="$T/api/repos/acme/fw/releases"; mkdir -p "$A/tags"
echo '{"tag_name": "v2.0.1", "draft": false, "prerelease": false}' > "$A/tags/v2.0.1"
echo '{"tag_name": "v2.0.2", "draft": true}' > "$A/tags/v2.0.2"
# A newer pre-release and a v1 release: neither is "the latest" for update.
echo '{"tag_name": "v2.0.3", "draft": false, "prerelease": true}' > "$A/tags/v2.0.3"
echo '{"tag_name": "v1.9.0", "draft": false, "prerelease": false}' > "$A/tags/v1.9.0"
g -C "$W" tag v2.0.3; g -C "$W" tag v1.9.0; g -C "$F" fetch -q "$W" 'refs/tags/*:refs/tags/*'
export JUVANT_OS_API="file://$T/api" JUVANT_OS_RELEASE_SLUG=acme/fw
( cd "$U" && bash .claude/skills/update/update.sh v2.0.0 --repo "$F" >/dev/null 2>&1 ); check "a tag without a release is refused" "[[ $? == 1 ]] && ! grep -q v2.0.0 '$U/.claude/juvant-os.json'"
( cd "$U" && bash .claude/skills/update/update.sh v2.0.2 --repo "$F" >/dev/null 2>&1 ); check "a draft release is refused" "[[ $? == 1 ]]"
( cd "$U" && bash .claude/skills/update/update.sh --from "$W/framework" >/dev/null 2>&1 ); check "--from outside setup is refused" "[[ $? == 2 ]]"
( cd "$U" && JUVANT_OS_RELEASE_SLUG=acme/none bash .claude/skills/update/update.sh --repo "$F" 2>&1 | grep -q 'no published v2 release' ); check "no releases: nothing to update" "[[ $? == 0 ]]"
( cd "$U" && bash .claude/skills/update/update.sh --repo "$F" >/dev/null 2>&1 ); rc=$?
check "update with no tag installs the latest stable v2 release" "[[ $rc == 0 ]] && grep -q '\"version\": \"v2.0.1\"' '$U/.claude/juvant-os.json'"
check "hook updated" "grep -q 'CONTEXT_CAP = 9400' '$U/.claude/hooks/juvant_hooks.py'"
check "removed skill removed" "[[ ! -e '$U/.claude/skills/decision/SKILL.md' ]]"
check "new skill installed" "[[ -f '$U/.claude/skills/brief/SKILL.md' ]]"
check "version is the tag" "grep -q '\"version\": \"v2.0.1\"' '$U/.claude/juvant-os.json'"
changed=$(g -C "$U" status --porcelain | awk '{print $2}' | grep -v -e '^\.claude/hooks/' -e '^\.claude/skills/' -e '^\.claude/juvant-os' || true)
check "only framework paths changed (got: ${changed:-none})" "[[ -z '$changed' ]]"
check "company CLAUDE.md untouched" "grep -q 'custom company line' '$U/CLAUDE.md' && ! grep -q 'changed template' '$U/CLAUDE.md'"
check "company settings untouched" "[[ \$(cat '$U/.claude/settings.json') == '{\"mine\":true}' ]]"
check "role card untouched" "[[ \$(cat '$U/roles/legal.md') == 'x' ]]"
out=$(cd "$U" && bash .claude/skills/update/update.sh --repo "$F" 2>&1); check "latest already installed: nothing to update" "[[ $? == 0 ]] && grep -q 'already installed' <<< '$out'"
( cd "$K" && g init -q && JUVANT_OS_SETUP=1 bash .claude/skills/update/update.sh --from "$ROOT/framework" >/dev/null 2>&1 )
check "update keeps the recorded country pack" "grep -q '\"country\": \"it\"' '$K/.claude/juvant-os.json' && [[ -f '$K/.claude/country/legal.md' ]]"
check "nothing committed" "[[ \$(g -C '$U' log --oneline | wc -l | tr -d ' ') == 2 ]]"
( cd "$U" && bash .claude/skills/update/update.sh v9.9.9 --repo "$F" >/dev/null 2>&1 ); check "unknown tag fails" "[[ $? != 0 ]]"
mkdir -p "$U/.juvant"; ( cd "$U" && bash .claude/skills/update/update.sh v2.0.1 --repo "$F" >/dev/null 2>&1 ); check "update refuses on a v1 instance" "[[ $? == 1 ]]"

echo "== setup only from an official release"
R="$T/rel"; mkdir -p "$R"; cp -R "$ROOT/framework" "$ROOT/setup.sh" "$R/"
g -C "$R" init -q; g -C "$R" add -A; g -C "$R" commit -qm r0; g -C "$R" tag v2.0.0
echo "# later" >> "$R/framework/README.md"; g -C "$R" commit -qam r1; g -C "$R" tag v2.0.1
echo "# unreleased" >> "$R/framework/README.md"; g -C "$R" commit -qam r2
g clone -q --bare "$R" "$T/rel.git"
rs() { # <checkout-ref> <company-dir> [modify]
  local w="$T/relclone-$2"; g clone -q "$T/rel.git" "$w" && g -C "$w" checkout -q "$1"
  [[ -n "${3:-}" ]] && echo "# local" >> "$w/framework/README.md"
  JUVANT_OS_DEV="" JUVANT_OS_REPO="$T/rel.git" bash "$w/setup.sh" "$T/$2" >/dev/null 2>&1
}
rs v2.0.1 rel-ok; check "setup from a published release works" "[[ \$? == 0 && -f '$T/rel-ok/.claude/hooks/juvant_hooks.py' ]]"
rs main rel-main; check "setup from main is refused" "[[ \$? == 1 && ! -e '$T/rel-main/CLAUDE.md' ]]"
rs v2.0.0 rel-tag; check "setup from a tag without a release is refused" "[[ \$? == 1 && ! -e '$T/rel-tag/CLAUDE.md' ]]"
rs v2.0.1 rel-dirty modify; check "setup with local framework changes is refused" "[[ \$? == 1 && ! -e '$T/rel-dirty/CLAUDE.md' ]]"

echo "test-setup-update: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
