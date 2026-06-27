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
cd "$REPO"

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
