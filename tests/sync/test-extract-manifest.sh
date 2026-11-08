#!/usr/bin/env bash
# tests/sync/test-extract-manifest.sh
#
# scripts/extract-manifest.sh (BUG-103): every shipped agent file round-trips
# through --insert into a real SQLite manifests table and --check matches the
# stored content byte for byte; quotes and percent signs survive; bad input
# prints no SQL.
#
# Run:  bash tests/sync/test-extract-manifest.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
X="$ROOT_DIR/scripts/extract-manifest.sh"
TMPROOT=$(mktemp -d /tmp/juvant-extract-manifest-XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
t_assert() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); echo "  ok   $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL $1 (expected '$2', got '$3')"; fi
}

DB="$TMPROOT/t.db"
cat > "$TMPROOT/schema.sql" <<'SQL'
CREATE TABLE manifests (id INTEGER PRIMARY KEY, agent TEXT, content TEXT,
  version TEXT, status TEXT, tier INTEGER, deadline TEXT,
  tier1_bootstrap INTEGER, precondition_bypassed TEXT, created_at TEXT);
SQL
sqlite3 "$DB" < "$TMPROOT/schema.sql"

# Shipped agents, plus a fixture with quotes, %, a '---' rule in the body and
# no trailing newline.
mkdir -p "$TMPROOT/agents"
printf -- "---\nname: tricky\n---\n\n# It's 100%% %%s\n\n---\n\nO'Brien said ''hi''\n\\\\n literal" \
  > "$TMPROOT/agents/tricky.md"

pairs=()
for f in "$ROOT_DIR"/agents/company/*.md "$ROOT_DIR"/agents/projects/*.md \
         "$ROOT_DIR"/agents/components/*.md "$TMPROOT/agents/tricky.md"; do
  [[ -f "$f" ]] || continue
  pairs+=("$(basename "$f" .md)" "$f")
done
n_agents=$(( ${#pairs[@]} / 2 ))

bash "$X" --insert "${pairs[@]}" > "$TMPROOT/m.sql"
t_assert "--insert exits 0" 0 $?
sqlite3 "$DB" < "$TMPROOT/m.sql"
t_assert "SQL loads" 0 $?
t_assert "one row per agent" "$n_agents" "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM manifests;')"
t_assert "rows are pending v1.0 tier 1" "$n_agents" \
  "$(sqlite3 "$DB" "SELECT COUNT(*) FROM manifests WHERE status='pending' AND version='1.0' AND tier=1 AND tier1_bootstrap=0;")"

i=0; bad=0
while [[ $i -lt ${#pairs[@]} ]]; do
  a="${pairs[$i]}"; f="${pairs[$((i + 1))]}"
  sqlite3 "$DB" "SELECT content FROM manifests WHERE agent = '$a';" > "$TMPROOT/$a.txt"
  bash "$X" --check "$f" "$TMPROOT/$a.txt" 2>/dev/null || { bad=$((bad + 1)); echo "    mismatch: $a"; }
  i=$((i + 2))
done
t_assert "stored content matches every body" 0 "$bad"

t_assert "body starts with the agent heading or comments, not ---" 0 \
  "$(sqlite3 "$DB" "SELECT COUNT(*) FROM manifests WHERE ltrim(content, char(10)) LIKE '---%';")"
t_assert "no frontmatter key in body" 0 \
  "$(sqlite3 "$DB" "SELECT COUNT(*) FROM manifests WHERE content LIKE 'name:%' OR content LIKE '%' || char(10) || 'mcpServers:%';")"
t_assert "quotes and percent survive" 1 \
  "$(sqlite3 "$DB" "SELECT COUNT(*) FROM manifests WHERE agent='tricky' AND instr(content, 'It''s 100% %s') > 0 AND instr(content, 'O''Brien said ''''hi''''') > 0 AND instr(content, '\\n literal') > 0;")"

# --check detects a summary.
printf 'A short summary.\n' > "$TMPROOT/summary.txt"
bash "$X" --check "$ROOT_DIR/agents/company/cfo.md" "$TMPROOT/summary.txt" 2>/dev/null
t_assert "--check rejects a summary" 1 $?

# Bad input prints no SQL.
printf 'no frontmatter\n' > "$TMPROOT/plain.md"
out=$(bash "$X" --insert cfo "$ROOT_DIR/agents/company/cfo.md" bad "$TMPROOT/plain.md" 2>/dev/null); rc=$?
t_assert "file without frontmatter → exit 3" 3 "$rc"
t_assert "…and no partial SQL" "" "$out"
printf -- '---\nname: e\n---\n\n  \n' > "$TMPROOT/empty.md"
bash "$X" "$TMPROOT/empty.md" >/dev/null 2>&1
t_assert "empty body → exit 3" 3 $?
out=$(bash "$X" --insert "x'); DROP TABLE manifests; --" "$ROOT_DIR/agents/company/cfo.md" 2>/dev/null); rc=$?
t_assert "invalid agent name → exit 2" 2 "$rc"
t_assert "…and no SQL" "" "$out"
bash "$X" --insert cfo >/dev/null 2>&1
t_assert "odd pair count → exit 2" 2 $?
bash "$X" "$TMPROOT/missing.md" >/dev/null 2>&1
t_assert "unreadable file → exit 2" 2 $?

echo
echo "extract-manifest: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
