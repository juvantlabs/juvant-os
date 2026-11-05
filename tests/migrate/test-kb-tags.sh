#!/usr/bin/env bash
# tests/migrate/test-kb-tags.sh
# BUG-074 — knowledge_base.tags: a fresh DB has it, an old-shape DB gains it with
# its rows intact, a re-run is clean, and the search agents run works.
#
# migrate.sh resolves its config/schema from $SCRIPT_DIR/.., so it is staged
# into a temp ROOT (as in test-schema-apply-order.sh).

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for dep in sqlite3 jq; do
  command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }
done

PASS=0; FAIL=0
ok(){ echo "    PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$2' got '$3')"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
stage() { # <dir>
  mkdir -p "$1/scripts" "$1/.juvant"
  cp "$REPO/scripts/migrate.sh" "$REPO/scripts/schema.sql" "$1/scripts/"
  jq -n --arg u "file:$1/.juvant/state.db" '{db:{provider:"local",url:$u}}' > "$1/.juvant/config.json"
}
has_tags() { sqlite3 "$1" "SELECT COUNT(*) FROM pragma_table_info('knowledge_base') WHERE name='tags';"; }

echo "== fresh DB =="
R="$TMP/fresh"; stage "$R"
bash "$R/scripts/migrate.sh" >/dev/null 2>&1; eq "exit 0" "0" "$?"
eq "has tags" "1" "$(has_tags "$R/.juvant/state.db")"

echo "== old-shape DB =="
R="$TMP/old"; stage "$R"
DB="$R/.juvant/state.db"
sqlite3 "$DB" "CREATE TABLE knowledge_base (
    id INTEGER PRIMARY KEY AUTOINCREMENT, category TEXT NOT NULL, title TEXT NOT NULL,
    content TEXT NOT NULL, source_project TEXT, source_ref TEXT, promoted_by TEXT,
    approved_by TEXT, scope TEXT DEFAULT 'company', created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
  INSERT INTO knowledge_base (category,title,content,source_project) VALUES ('technical','kept','body','apollo');"
eq "fixture has no tags" "0" "$(has_tags "$DB")"
bash "$R/scripts/migrate.sh" >/dev/null 2>&1; eq "exit 0" "0" "$?"
eq "gains tags" "1" "$(has_tags "$DB")"
eq "row kept" "kept|body|apollo|NULL" \
  "$(sqlite3 "$DB" "SELECT title, content, source_project, coalesce(tags,'NULL') FROM knowledge_base;")"
bash "$R/scripts/migrate.sh" >/dev/null 2>&1; eq "re-run exit 0" "0" "$?"
eq "one row after re-run" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM knowledge_base;")"

echo "== the search agents run =="
sqlite3 "$DB" "INSERT INTO knowledge_base (category,title,content,source_project,tags)
  VALUES ('technical','rb','{\"status\":\"active\"}','apollo','runbook,infra'),
         ('technical','old','{\"status\":\"deprecated\"}','apollo','runbook'),
         ('technical','other','{\"status\":\"active\"}','zeus','runbook');"
eq "tag, project and JSON status" "rb" "$(sqlite3 "$DB" "SELECT title FROM knowledge_base
  WHERE source_project='apollo' AND tags LIKE '%runbook%' AND json_extract(content, '\$.status')='active';")"

echo ""
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
