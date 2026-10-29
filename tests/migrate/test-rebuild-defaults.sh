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
               INSERT INTO agent_tool_matrix (role,mcp_servers) VALUES ('cfo','[]');
               INSERT INTO knowledge_base (category,title,content) VALUES ('technical','gap','g');
               DELETE FROM knowledge_base WHERE title='gap';"
KB0=$(sqlite3 "$DB" "SELECT group_concat(id||':'||title||':'||coalesce(approved_by,'NULL'),'|') FROM knowledge_base;")
seq() { sqlite3 "$1" "SELECT coalesce((SELECT seq FROM sqlite_sequence WHERE name='$2'),0);"; }
SEQ0=$(seq "$DB" knowledge_base)

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
eq  "AUTOINCREMENT sequence carried over (deleted top id not reused)" "$SEQ0" "$(seq "$DB" knowledge_base)"
sqlite3 "$DB" "INSERT INTO knowledge_base (category,title,content) VALUES ('technical','c','z');"
eq  "next id continues after the old high-water mark" "$((SEQ0 + 1))" "$(sqlite3 "$DB" "SELECT id FROM knowledge_base WHERE title='c';")"
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

echo "== local: a failed step rolls the whole rebuild back =="
R4="$TMP/inst4"; stage "$R4"; DB4="$R4/.juvant/state.db"
sqlite3 "$DB4" < "$TMP/old.sql"
sqlite3 "$DB4" "INSERT INTO knowledge_base (category,title,content) VALUES ('technical','a','x');"
# A trigger that aborts the copy into the rebuild table (an injected failure).
sqlite3 "$DB4" "CREATE TABLE knowledge_base__bug085_guard (x); CREATE TRIGGER inject BEFORE INSERT ON knowledge_base__bug085_guard BEGIN SELECT RAISE(ABORT,'x'); END;"
# shellcheck disable=SC2016  # the $t / $cols are migrate.sh's own, matched literally
sed -i.bak 's/INSERT INTO \${t}__bug085 (\$cols) SELECT \$cols FROM \$t/INSERT INTO ${t}__bug085 ($cols) SELECT $cols FROM $t; INSERT INTO knowledge_base__bug085_guard VALUES (1)/' "$R4/scripts/migrate.sh"
out=$(bash "$R4/scripts/migrate.sh" --rebuild-defaults 2>&1); rc=$?
if [[ "$rc" -ne 0 ]]; then ok "local failure → non-zero exit"; else no "local failure exited 0"; fi
has "reports the rollback" "$out" "rolled back"
eq  "original table untouched (default + row)" "'ceo'|1" "$(dflt "$DB4" knowledge_base)|$(sqlite3 "$DB4" "SELECT count(*) FROM knowledge_base;")"
eq  "no leftover rebuild table" "0" "$(sqlite3 "$DB4" "SELECT count(*) FROM sqlite_master WHERE name = 'knowledge_base__bug085';")"

echo "== turso provider: ONE atomic libsql batch (H23 / BUG-091) =="
R3="$TMP/inst3"; mkdir -p "$R3/scripts" "$R3/.juvant" "$TMP/bin3"
cp "$REPO/scripts/migrate.sh" "$REPO/scripts/schema.sql" "$R3/scripts/"
DB3="$TMP/turso.db"
jq -n '{db:{provider:"turso",url:"libsql://test.fake",auth_token:"T"}}' > "$R3/.juvant/config.json"
cp "$REPO/tests/hooks/fake-turso.sh" "$TMP/bin3/turso"; cp "$REPO/tests/hooks/fake-libsql-curl.sh" "$TMP/bin3/curl"; chmod +x "$TMP/bin3"/*
sqlite3 "$DB3" < "$TMP/old.sql"
sqlite3 "$DB3" "INSERT INTO knowledge_base (category,title,content) VALUES ('technical','a','x');
                INSERT INTO knowledge_base (category,title,content) VALUES ('technical','b','y');
                INSERT INTO knowledge_base (category,title,content) VALUES ('technical','gap','g');
                DELETE FROM knowledge_base WHERE title='gap';
                INSERT INTO agent_tool_matrix (role,mcp_servers) VALUES ('cfo','[]');"
SEQ3=$(seq "$DB3" knowledge_base); ROWS3=$(sqlite3 "$DB3" "SELECT count(*) FROM knowledge_base;")
tmig() { PATH="$TMP/bin3:$PATH" JUVANT_TEST_DB_FILE="$DB3" bash "$R3/scripts/migrate.sh" "$@" 2>&1; }
out=$(FAKE_BATCH_FAIL_AT="RENAME TO" tmig --rebuild-defaults); rc=$?
if [[ "$rc" -ne 0 ]]; then ok "ACCEPTANCE: forced failure between copy and RENAME → migrate exits non-zero"; else no "forced failure exited 0"; fi
has "...and says it rolled back" "$out" "rolled back"
eq  "ACCEPTANCE: original table in place with ALL rows and its default" "$ROWS3|'ceo'" \
  "$(sqlite3 "$DB3" "SELECT count(*) FROM knowledge_base;")|$(dflt "$DB3" knowledge_base)"
eq  "no leftover rebuild table after the rollback" "0" "$(sqlite3 "$DB3" "SELECT count(*) FROM sqlite_master WHERE name LIKE '%__bug085';")"
out=$(tmig --rebuild-defaults); rc=$?
eq  "normal turso run exits 0" "0" "$rc"
if [[ "$out" == *"cannot commit"* ]]; then no "ACCEPTANCE: no 'cannot commit' error"; else ok "ACCEPTANCE: no 'cannot commit' error"; fi
has "both tables rebuilt" "$out" "Rebuilt agent_tool_matrix"
eq  "default gone, rows kept" "NULL|$ROWS3" "$(dflt "$DB3" knowledge_base)|$(sqlite3 "$DB3" "SELECT count(*) FROM knowledge_base;")"
eq  "ACCEPTANCE: sqlite_sequence for the table unchanged" "$SEQ3" "$(seq "$DB3" knowledge_base)"

echo "───────────────────────────────────"
echo "  migrate rebuild-defaults: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
