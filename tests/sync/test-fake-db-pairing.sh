#!/usr/bin/env bash
# tests/sync/test-fake-db-pairing.sh
#
# G6 (decisions#303): since decisions#276 the cloud DB layer (hooks/lib/db.sh)
# reads AND writes over the libsql HTTP /v2/pipeline API (curl), not only the
# turso CLI. A test that fakes `turso` but not `curl` silently sends its writes
# to the real network path (they fail and spool) and passes for the wrong
# reason. Static guard: every test that installs tests/hooks/fake-turso.sh must
# also install tests/hooks/fake-libsql-curl.sh.
#
# Run:  bash tests/sync/test-fake-db-pairing.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 1

PASS=0; FAIL=0
for f in $(git ls-files 'tests/*.sh'); do
  case "$f" in tests/hooks/fake-turso.sh|tests/hooks/fake-libsql-curl.sh|tests/sync/test-fake-db-pairing.sh) continue ;; esac
  if grep -q 'fake-turso' "$f"; then
    if grep -q 'fake-libsql-curl' "$f"; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1)); echo "  FAIL $f fakes turso but not curl (fake-libsql-curl.sh)"
    fi
  fi
done
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
