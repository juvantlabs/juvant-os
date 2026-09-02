#!/usr/bin/env bash
# tests/migrate/test-dry-run-no-write.sh
#
# BUG-064 (SAFETY): `migrate.sh --dry-run` must NOT write in the default
# schema-apply mode. Previously the flag was parsed but never consulted there,
# so a dry-run applied the schema (incl. trigger DROP/CREATE) and printed
# "Schema applied successfully." — inverting the dry-run contract.
#
# migrate.sh resolves its config/schema from $SCRIPT_DIR/.. (no JUVANT_CONFIG
# override), so it is staged into a temp ROOT.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for dep in sqlite3 jq; do
  command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }
done

PASS=0; FAIL=0
ok(){ echo "    PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$2' got '$3')"; fi; }
has(){ if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing: $3)"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then no "$1 (unexpectedly present: $3)"; else ok "$1"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/.juvant"
cp "$REPO/scripts/migrate.sh" "$REPO/scripts/schema.sql" "$TMP/scripts/"
DB="$TMP/.juvant/state.db"; : > "$DB"
jq -n --arg u "file:$DB" '{db:{provider:"local",url:$u}}' > "$TMP/.juvant/config.json"
tables(){ sqlite3 "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';"; }
trigs(){ sqlite3 "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger';"; }

# 1. --dry-run on an empty DB → no write, labelled, no success message.
out=$(bash "$TMP/scripts/migrate.sh" --dry-run 2>&1); rc=$?
eq   "dry-run exits 0" "0" "$rc"
eq   "dry-run applied NOTHING (0 tables)" "0" "$(tables)"
has  "dry-run output is labelled [dry-run]" "$out" "[dry-run]"
hasnt "dry-run does NOT claim success" "$out" "applied successfully"

# 2. Real apply (no flag) → writes.
bash "$TMP/scripts/migrate.sh" >/dev/null 2>&1
[[ "$(tables)" -gt 0 ]] && ok "real apply writes the schema (tables present)" \
  || no "real apply did not write ($(tables) tables)"

# 3. --dry-run on the populated DB → triggers NOT dropped/recreated.
#    (apply_schema_patches_* does DROP TRIGGER + CREATE TRIGGER — the sharpest
#    "not additive-only" write a dry-run must not perform.)
_before=$(trigs)
out3=$(bash "$TMP/scripts/migrate.sh" --dry-run 2>&1)
eq   "dry-run leaves triggers untouched (no DROP/CREATE)" "$_before" "$(trigs)"
hasnt "dry-run on populated DB still does not claim success" "$out3" "applied successfully"

echo "───────────────────────────────────"
echo "  migrate --dry-run: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
