#!/usr/bin/env bash
# The FILES check must pass on the real tree and fail on each kind of mismatch.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/tests/check-files.sh"
PASS=0; FAIL=0
expect() { # expect <label> <want-rc> <dir>
  bash "$CHECK" "$3" >/dev/null 2>&1; local rc=$?
  if [[ "$rc" == "$2" ]]; then echo "  ok   $1"; PASS=$((PASS+1)); else echo "  FAIL $1 (rc $rc, want $2)"; FAIL=$((FAIL+1)); fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

expect "real framework/ matches FILES" 0 "$ROOT/framework"

cp -R "$ROOT/framework" "$T/extra"; : > "$T/extra/hooks/stray.sh"
expect "unlisted file fails" 1 "$T/extra"

cp -R "$ROOT/framework" "$T/missing"; echo "agents/ghost.md" >> "$T/missing/FILES"
expect "listed but absent fails" 1 "$T/missing"

cp -R "$ROOT/framework" "$T/dupe"; echo "README.md" >> "$T/dupe/FILES"
expect "duplicate entry fails" 1 "$T/dupe"

cp -R "$ROOT/framework" "$T/nofiles"; rm "$T/nofiles/FILES"
expect "missing FILES fails" 1 "$T/nofiles"

echo "test-check-files: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
