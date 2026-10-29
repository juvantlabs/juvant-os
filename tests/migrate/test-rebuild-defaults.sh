#!/usr/bin/env bash
# tests/migrate/test-rebuild-defaults.sh
#
# BUG-085 / H19 (juvant-os-pm#193): on a DB created before v1.14.3,
# knowledge_base.approved_by and agent_tool_matrix.approved_by still DEFAULT
# 'ceo' — CREATE TABLE IF NOT EXISTS never alters a live table. `migrate.sh
# --rebuild-defaults` rebuilds them without the default; without the flag the
# stale default is only reported. Acceptance: on an upgraded DB, an INSERT that
# omits approved_by stores NULL — and no row is lost.

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

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
stage() { # <dir> — staged ROOT with a local-provider config
  mkdir -p "$1/scripts" "$1/.juvant"
  cp "$REPO/scripts/migrate.sh" "$REPO/scripts/schema.sql" "$1/scripts/"
  jq -n --arg u "file:$1/.juvant/state.db" '{db:{provider:"local",url:$u}}' > "$1/.juvant/config.json"
}
# The pre-v1.14.3 shape: the same schema with DEFAULT 'ceo' on the two columns.
old_schema() {
  awk '/^CREATE TABLE IF NOT EXISTS (knowledge_base|agent_tool_matrix) \(/ {f=1}
       f && /^  approved_by[[:space:]]+TEXT,$/ {sub(/TEXT,$/, "TEXT DEFAULT '"'"'ceo'"'"',")}
       /^\);/ {f=0} {print}' "$REPO/scripts/schema.sql"
}
dflt() { sqlite3 "$1" "SELECT coalesce(dflt_value,'NULL') FROM pragma_table_info('$2') WHERE name='approved_by';"; }

R="$TMP/inst"; stage "$R"; DB="$R/.juvant/state.db"
old_schema > "$TMP/old.sql"
sqlite3 "$DB" < "$TMP/old.sql"
eq "fixture: knowledge_base.approved_by DEFAULT 'ceo'" "'ceo'" "$(dflt "$DB" knowledge_base)"
sqlite3 "$DB" "INSERT INTO knowledge_base (category,title,content) VALUES ('technical','a','x');
               INSERT INTO knowledge_base (category,title,content,approved_by) VALUES ('technical','b','y',NULL);
               INSERT INTO agent_tool_matrix (role,mcp_servers) VALUES ('cfo','[]');"
KB0=$(sqlite3 "$DB" "SELECT group_concat(id||':'||title||':'||coalesce(approved_by,'NULL'),'|') FROM knowledge_base;")

echo "== without --rebuild-defaults: reported, not changed =="
out=$(bash "$R/scripts/migrate.sh" 2>&1); rc=$?
eq  "migrate exits 0" "0" "$rc"
has "stale default reported" "$out" "still DEFAULT 'ceo'"
eq  "default untouched without the flag" "'ceo'" "$(dflt "$DB" knowledge_base)"

echo "== with --rebuild-defaults =="
out=$(bash "$R/scripts/migrate.sh" --rebuild-defaults 2>&1); rc=$?
eq  "migrate --rebuild-defaults exits 0" "0" "$rc"
has "knowledge_base rebuilt" "$out" "Rebuilt knowledge_base"
has "agent_tool_matrix rebuilt" "$out" "Rebuilt agent_tool_matrix"
has "schema verified afterwards" "$out" "Verified:"
eq  "knowledge_base.approved_by has no default" "NULL" "$(dflt "$DB" knowledge_base)"
eq  "agent_tool_matrix.approved_by has no default" "NULL" "$(dflt "$DB" agent_tool_matrix)"
eq  "every existing row kept, values unchanged" "$KB0" \
  "$(sqlite3 "$DB" "SELECT group_concat(id||':'||title||':'||coalesce(approved_by,'NULL'),'|') FROM knowledge_base;")"
sqlite3 "$DB" "INSERT INTO knowledge_base (category,title,content) VALUES ('technical','c','z');"
eq  "ACCEPTANCE: INSERT omitting approved_by stores NULL" "NULL" \
  "$(sqlite3 "$DB" "SELECT coalesce(approved_by,'NULL') FROM knowledge_base WHERE title='c';")"
eq  "the table's triggers are back (global-scope guard)" "2" \
  "$(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND tbl_name='knowledge_base';")"
eq  "no leftover rebuild table" "0" "$(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE name LIKE '%__bug085';")"
out=$(bash "$R/scripts/migrate.sh" --rebuild-defaults 2>&1); rc=$?
eq  "re-run is a no-op (exit 0, nothing rebuilt)" "0|no" "$rc|$([[ "$out" == *Rebuilt* ]] && echo yes || echo no)"

echo "== refuses when the live table has a column the canonical DDL lacks =="
R2="$TMP/inst2"; stage "$R2"; DB2="$R2/.juvant/state.db"
sqlite3 "$DB2" < "$TMP/old.sql"
sqlite3 "$DB2" "ALTER TABLE knowledge_base ADD COLUMN instance_extra TEXT; INSERT INTO knowledge_base (category,title,content,instance_extra) VALUES ('technical','a','x','keep me');"
out=$(bash "$R2/scripts/migrate.sh" --rebuild-defaults 2>&1); rc=$?
if [[ "$rc" -ne 0 ]]; then ok "non-zero exit"; else no "exited 0"; fi
has "names the column it would lose" "$out" "instance_extra"
eq  "table left as it was (default + extra column intact)" "'ceo'|keep me" \
  "$(dflt "$DB2" knowledge_base)|$(sqlite3 "$DB2" "SELECT instance_extra FROM knowledge_base;")"

echo "───────────────────────────────────"
echo "  migrate rebuild-defaults: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
