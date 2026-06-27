#!/usr/bin/env bash
# tests/helpers/test-turso-backup-archival.sh
# Regression test for the permanent-retention (ARCHIVAL-) tagging in
# helpers/turso-backup.sh. The old `category='spec'` grep matched nothing —
# 'spec' is not a real category and `.dump` emits category as a positional
# quoted value, not `category='…'`. This test extracts the ACTUAL grep pattern
# from turso-backup.sh and asserts it tags a spec-bearing dump and skips a
# spec-free one.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
ck(){ if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; PASS=$((PASS+1));
      else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Extract the real archival-detection regex from the script (no drift).
PAT=$(grep -oE 'grep -qE "[^"]+"' "$ROOT/helpers/turso-backup.sh" | head -1 \
      | sed -E 's/grep -qE "//; s/"$//')
[[ -n "$PAT" ]] || { echo "FAIL: could not extract grep pattern"; exit 1; }
echo "  (pattern under test: $PAT)"

mk_dump(){ # $1=db $2=category  → echoes dump path
  local db="$TMP/$2.db" out="$TMP/$2.sql"
  sqlite3 "$db" < "$ROOT/scripts/schema.sql"
  sqlite3 "$db" "INSERT INTO decisions (agent,title,category,status) VALUES ('cos','t','$2','proposed');"
  sqlite3 "$db" ".dump" > "$out"; echo "$out"
}

SPEC_DUMP=$(mk_dump x pr-spec)
NONSPEC_DUMP=$(mk_dump y model-override)

grep -qE "$PAT" "$SPEC_DUMP"    && r=match || r=nomatch
ck "spec-class dump (pr-spec) → ARCHIVAL tagged" "match" "$r"
grep -qE "$PAT" "$NONSPEC_DUMP" && r=match || r=nomatch
ck "non-spec dump (model-override) → NOT tagged" "nomatch" "$r"

# also confirm a couple of other real spec categories match
for c in install-spec eng-platform-spec deployment-spec; do
  d=$(mk_dump "z$c" "$c"); grep -qE "$PAT" "$d" && r=match || r=nomatch
  ck "spec-class dump ($c) → tagged" "match" "$r"
done

echo "==============================="
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
