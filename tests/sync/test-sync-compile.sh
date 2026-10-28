#!/usr/bin/env bash
# tests/sync/test-sync-compile.sh
#
# Guards the upstream-sync / compile machinery against the drift this PR
# fixed:
#   1. Whitelist completeness — every framework hook/helper must appear in
#      the JUVANT_OS.md "Framework whitelist", or upstream-sync silently
#      never offers it to adopters (how hooks/lib/track-tokens.sh was missed).
#   2. compile-templates.sh --check-only must never mutate — in particular
#      combined with --rewrite-meta (which ignores CHECK_ONLY).
#   3. The documented v0-matrix scope counts must match the actual JSON, so
#      the "11 company + 9 project" drift can't silently return.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 1

for dep in jq python3; do
  command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }
done

PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

md5of(){ md5 -q "$1" 2>/dev/null || md5sum "$1" | awk '{print $1}'; }

# ── 1. Whitelist completeness ───────────────────────────────────────────────
echo "== whitelist completeness =="
WL=$(awk '/\*\*Framework whitelist\*\*/{f=1} f&&/^```$/{c++} f&&c==1{print} c==2{exit}' JUVANT_OS.md)
miss=0
for f in $(git ls-files 'hooks/*.sh' 'hooks/lib/*.sh' 'helpers/*.sh'); do
  if ! printf '%s' "$WL" | grep -qF "$f"; then
    # helpers are sometimes listed by basename across the two columns; accept either.
    printf '%s' "$WL" | grep -qF "$(basename "$f")" || { echo "    not whitelisted: $f"; miss=$((miss+1)); }
  fi
done
[[ "$miss" -eq 0 ]] && ok "every hooks/*.sh, hooks/lib/*.sh, helpers/*.sh is in the framework whitelist" \
                    || no "$miss framework file(s) absent from the whitelist"

# Specifically pin the file this PR added (regression anchor).
printf '%s' "$WL" | grep -qF "hooks/lib/track-tokens.sh" \
  && ok "hooks/lib/track-tokens.sh is whitelisted" \
  || no "hooks/lib/track-tokens.sh missing from whitelist"
# decisions#300: shared pause-window lib sourced by the CSO audit + two helpers.
printf '%s' "$WL" | grep -qF "hooks/lib/pause-windows.sh" \
  && ok "hooks/lib/pause-windows.sh is whitelisted" \
  || no "hooks/lib/pause-windows.sh missing from whitelist"

# decisions#300 item 10: framework-owned tests travel with the hooks/helpers
# they test (a test fake must mirror reality). Every tracked file under
# tests/hooks/, tests/helpers/, tests/sync/ must be whitelisted by FULL path
# (no basename fallback — basenames like run-tests.sh collide across dirs).
# decisions#302: "framework-owned" means "present in the upstream tree".
# Instance-local tests (JUVANT_OS.md: e.g. tests/hooks/test-<instance>-*.sh,
# never touched by sync) are not in that tree and must not be flagged. The
# reference tree is HEAD in the framework repo itself (origin is canonical),
# else the adopter's upstream/main; with neither, the check is skipped.
_origin=$(git remote get-url origin 2>/dev/null || echo "")
if [[ "$_origin" =~ (^|[/:])juvantlabs/juvant-os(\.git)?$ ]]; then
  _ref="HEAD"
elif git rev-parse --verify -q upstream/main >/dev/null 2>&1; then
  _ref="upstream/main"
else
  _ref=""
fi
if [[ -z "$_ref" ]]; then
  ok "SKIP test-whitelist completeness: no framework reference tree (not the framework repo, no upstream/main ref)"
else
  tmiss=0; tlocal=0
  for f in $(git ls-files 'tests/hooks/*' 'tests/helpers/*' 'tests/sync/*'); do
    if ! git cat-file -e "$_ref:$f" 2>/dev/null; then tlocal=$((tlocal+1)); continue; fi
    printf '%s\n' "$WL" | grep -qE "(^|[[:space:]])${f//./\\.}([[:space:]]|$)" \
      || { echo "    test not whitelisted: $f"; tmiss=$((tmiss+1)); }
  done
  [[ "$tmiss" -eq 0 ]] && ok "every framework file under tests/{hooks,helpers,sync}/ is whitelisted by full path (ref=$_ref; $tlocal instance-local skipped)" \
                       || no "$tmiss framework test file(s) absent from the whitelist (ref=$_ref)"
fi

# The tests/ entries must be an explicit file list, never a glob/dir — a glob
# would clobber instance-local tests (e.g. tests/hooks/test-<instance>-*.sh).
if printf '%s\n' "$WL" | tr -s ' \t' '\n' | grep -E '^tests/' | grep -qE '[*?]|/$'; then
  no "whitelist contains a tests/ glob or directory entry (must be explicit files)"
else
  ok "whitelist tests/ entries are explicit files (no glob, no bare dir)"
fi

# Regression anchor: the libsql transport fake that drifted on adopters.
printf '%s\n' "$WL" | grep -qF "tests/hooks/fake-libsql-curl.sh" \
  && ok "tests/hooks/fake-libsql-curl.sh is whitelisted" \
  || no "tests/hooks/fake-libsql-curl.sh missing from whitelist"

# The NEVER-touched list must not still exclude tests/ wholesale.
NEVER=$(awk '/\*\*Files NEVER touched\*\*/{f=1} f&&/^$/{exit} f' JUVANT_OS.md)
printf '%s' "$NEVER" | grep -qF '`tests/` (everything **except** the framework-owned' \
  && ok "NEVER-touched list carves out the framework-owned tests" \
  || no "NEVER-touched list still excludes tests/ wholesale (or wording drifted)"

# ── 1b. Sync lands via PR, never a direct push to main ──────────────────────
# decisions#300 item 11 / security_audit_log#146: 9 sync pushes reached main
# with no CI. The procedure must push a branch and open a PR the CEO merges.
echo "== upstream-sync PR flow =="
SYNC=$(awk '/^## Upstream sync$/{f=1;next} f&&/^## /{exit} f' JUVANT_OS.md)
[[ -n "$SYNC" ]] && ok "found the Upstream sync section" || no "Upstream sync section not found"
if printf '%s' "$SYNC" | grep -qE '^[0-9]+\. \*\*Push\*\* — `git push origin main`'; then
  no "Upstream sync still instructs a direct 'git push origin main' step"
else
  ok "Upstream sync has no direct 'git push origin main' step"
fi
printf '%s' "$SYNC" | grep -qF 'gh pr create --base main' \
  && ok "Upstream sync opens a PR against main" \
  || no "Upstream sync does not open a PR (gh pr create --base main)"
printf '%s' "$SYNC" | grep -qF 'The CEO merges' \
  && ok "Upstream sync leaves the merge to the CEO" \
  || no "Upstream sync does not state that the CEO merges"

# ── 2. compile-templates.sh --check-only never mutates ──────────────────────
echo "== compile-templates --check-only safety =="
before=$(md5of README.md)
out=$(bash scripts/compile-templates.sh --check-only --rewrite-meta 2>&1); rc=$?
after=$(md5of README.md)
[[ "$rc" -eq 2 ]] && ok "--check-only --rewrite-meta is refused (exit 2)" \
                  || no "--check-only --rewrite-meta exit was $rc (expected 2)"
printf '%s' "$out" | grep -qi "cannot be combined" \
  && ok "refusal message explains the contradiction" \
  || no "refusal message missing"
[[ "$before" == "$after" ]] && ok "--check-only --rewrite-meta left README.md untouched" \
                            || no "--check-only --rewrite-meta MUTATED README.md"

# ── 3. Documented matrix scope counts match the JSON ────────────────────────
echo "== v0 matrix count consistency =="
read -r CO PR < <(python3 -c "
import json
m=json.load(open('scripts/templates/v0-agent-tool-matrix.json'))
rows = m if isinstance(m,list) else m.get('rows', m.get('matrix', []))
from collections import Counter
c=Counter(r.get('scope','?') for r in rows)
print(c.get('company',0), c.get('project',0))
")
if grep -qE "${CO} company-scope \+\s*$" JUVANT_OS.md || grep -qE "${CO} company-scope \+" JUVANT_OS.md; then
  ok "JUVANT_OS.md states ${CO} company-scope (matches JSON)"
else
  no "JUVANT_OS.md does not state ${CO} company-scope (JSON has ${CO})"
fi
if grep -qE "^${PR} project-scope" JUVANT_OS.md; then
  ok "JUVANT_OS.md states ${PR} project-scope (matches JSON)"
else
  no "JUVANT_OS.md does not state ${PR} project-scope on its own line (JSON has ${PR})"
fi

echo "==============================="
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
