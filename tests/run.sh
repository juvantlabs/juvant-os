#!/usr/bin/env bash
# tests/run.sh — every check CI runs: lint, the FILES check, unit tests.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
bash tests/lint.sh || fail=1
bash tests/check-files.sh || fail=1
for t in tests/unit/*.sh; do
  echo "== $t"; bash "$t" || fail=1
done
[[ "$fail" == 0 ]] && echo "ALL GREEN" || echo "FAILURES"
exit "$fail"
