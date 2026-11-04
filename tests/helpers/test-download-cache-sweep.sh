#!/usr/bin/env bash
# tests/helpers/test-download-cache-sweep.sh
# FEAT-068 — retention sweep for the MCP download sandboxes: only old regular
# files of the servers' own shape go, symlinks are ignored, roots from the
# agent-writable config are guarded, N is clamped, the log holds no file name,
# and a failure reaches CoS.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for dep in jq sqlite3; do command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }; done

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok; else no "$1 (expected [$2], got [$3])"; fi; }
has(){ if [[ "$2" == *"$3"* ]]; then ok; else no "$1 (missing: $3 in: ${2:0:200})"; fi; }
hasnt(){ if [[ "$2" != *"$3"* ]]; then ok; else no "$1 (must not contain: $3)"; fi; }
exists(){ if [[ -e "$2" || -L "$2" ]]; then ok; else no "$1 (gone: $2)"; fi; }
gone(){ if [[ ! -e "$2" && ! -L "$2" ]]; then ok; else no "$1 (still there: $2)"; fi; }

T=$(mktemp -d); trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
H="$T/home"; mkdir -p "$H"
I="$T/inst"; mkdir -p "$I/helpers" "$I/hooks" "$I/.juvant/logs"
cp "$REPO/helpers/download-cache-sweep.sh" "$I/helpers/"
cp -R "$REPO/hooks/lib" "$I/hooks/lib"
mkdir "$T/bin"; cp "$REPO/tests/hooks/fake-turso.sh" "$T/bin/turso"; cp "$REPO/tests/hooks/fake-libsql-curl.sh" "$T/bin/curl"
chmod +x "$T/bin/turso" "$T/bin/curl"
sqlite3 "$T/test.db" < "$REPO/scripts/schema.sql" 2>/dev/null
C="$I/.juvant/config.json"
echo '{}' > "$C"
SHA=0123456789abcdef
OLD=$(date -v-10d +%Y%m%d0000 2>/dev/null || date -d '10 days ago' +%Y%m%d0000)
AGED_3=$(date -v-3d +%Y%m%d0000 2>/dev/null || date -d '3 days ago' +%Y%m%d0000)

mk(){ mkdir -p "$(dirname "$1")"; echo x > "$1"; touch -t "${2:-$OLD}" "$1"; }
run(){ HOME="$H" PATH="$T/bin:$PATH" JUVANT_TEST_DB_FILE="$T/test.db" TURSO_URL=libsql://test.fake TURSO_TOKEN=x JUVANT_CONFIG="$C" \
        bash "$I/helpers/download-cache-sweep.sh" "$@" 2>&1; echo "EXIT:$?"; }

G="$H/.cache/m365-graph-mcp-server/tenant-a"
M="$H/.cache/m365-mail-mcp-server/tenant-a"

echo "=== no sandbox yet: a clean no-op ==="
out=$(run); has "exit 0" "$out" "EXIT:0"; has "no roots" "$out" "roots=0 deleted=0 errors=0 refused=0"

echo "=== old removed, recent kept, shape enforced ==="
mk "$G/$SHA-contract.docx"
mk "$G/$SHA-contract.pdf"
mk "$M/$SHA-invoice acme.pdf"
mk "$G/$SHA-recent.docx" "$(date +%Y%m%d0000)"
mk "$G/$SHA-three-days.docx" "$AGED_3"
mk "$G/not-a-server-file.docx"
mk "$G/ABCDEF0123456789-upper.docx"
mk "$H/.cache/m365-graph-mcp-server/$SHA-at-root-level.docx"
mk "$G/sub/$SHA-too-deep.docx"
mk "$G/$SHA"
echo victim > "$H/victim.txt"; touch -t "$OLD" "$H/victim.txt"
ln -s "$H/victim.txt" "$G/$SHA-link.docx"; touch -h -t "$OLD" "$G/$SHA-link.docx"
mkdir -p "$H/outside"; mk "$H/outside/$SHA-x.docx"
ln -s "$H/outside" "$H/.cache/m365-graph-mcp-server/tenant-link"
log_before=$(run --dry-run)
has "dry run counts" "$log_before" "would_delete=3"
exists "dry run deletes nothing" "$G/$SHA-contract.docx"
out=$(run)
has "exit 0" "$out" "EXIT:0"
has "deleted three" "$out" "roots=2 deleted=3 errors=0 refused=0"
gone "old file" "$G/$SHA-contract.docx"
gone "old converted pdf" "$G/$SHA-contract.pdf"
gone "old mail attachment, space in name" "$M/$SHA-invoice acme.pdf"
exists "recent file" "$G/$SHA-recent.docx"
exists "inside the window" "$G/$SHA-three-days.docx"
exists "no hash prefix" "$G/not-a-server-file.docx"
exists "uppercase is not the server's shape" "$G/ABCDEF0123456789-upper.docx"
exists "file at root level" "$H/.cache/m365-graph-mcp-server/$SHA-at-root-level.docx"
exists "file one level too deep" "$G/sub/$SHA-too-deep.docx"
exists "bare hash" "$G/$SHA"
exists "symlink itself kept" "$G/$SHA-link.docx"
exists "symlink target kept" "$H/victim.txt"
exists "symlinked tenant dir not followed" "$H/outside/$SHA-x.docx"
exists "tenant dir kept" "$G"
exists "root kept" "$H/.cache/m365-graph-mcp-server"

echo "=== N is configurable and clamped ==="
echo '{"retention":{"download_days":2}}' > "$C"
out=$(run); has "days from config" "$out" "days=2"
gone "older than 2 days" "$G/$SHA-three-days.docx"
for v in 0 '"0"'; do echo "{\"retention\":{\"download_days\":$v}}" > "$C"; has "0 clamps up" "$(run)" "days=1"; done
echo '{"retention":{"download_days":999}}' > "$C"; has "999 clamps down" "$(run)" "days=30"
echo '{"retention":{"download_days":-5}}' > "$C"; has "negative → default" "$(run)" "days=7"
echo '{"retention":{"download_days":"soon"}}' > "$C"; has "garbage → default" "$(run)" "days=7"
echo 'not json' > "$C"; has "unreadable config → default" "$(run)" "days=7"
exists "clamped run kept a recent file" "$G/$SHA-recent.docx"

echo "=== declared roots: an override is honoured ==="
R="$H/work/downloads"; mk "$R/tenant-a/$SHA-override.docx"; mk "$R/tenant-a/$SHA-recent.docx" "$(date +%Y%m%d0000)"
jq -n --arg r "$R" '{retention:{download_roots:[$r]}}' > "$C"
out=$(run); has "exit 0" "$out" "EXIT:0"; has "three roots" "$out" "roots=3"
gone "old file under an override" "$R/tenant-a/$SHA-override.docx"
exists "recent file under an override" "$R/tenant-a/$SHA-recent.docx"
jq -n --arg r "$R/" '{retention:{download_roots:[$r]}}' > "$C"; has "trailing slash" "$(run)" "EXIT:0"
jq -n --arg r "$H/not/yet" '{retention:{download_roots:[$r]}}' > "$C"
out=$(run); has "a root not created yet is fine" "$out" "EXIT:0"; has "not swept" "$out" "refused=0"

echo "=== a wrong root finds nothing to delete, or is refused ==="
D="$H/Documents"; mk "$D/Clients/contract.docx"
jq -n --arg r "$D" '{retention:{download_roots:[$r]}}' > "$C"
has "a real folder is not refused" "$(run)" "EXIT:0"
exists "but nothing of the wrong shape goes" "$D/Clients/contract.docx"

refused(){ # <label> <json root>
  jq -n --argjson r "$2" '{retention:{download_roots:[$r]}}' > "$C"
  local o; o=$(run); has "$1: exit 1" "$o" "EXIT:1"; has "$1: reason" "$o" "$3"
}
mk "$T/elsewhere/tenant/$SHA-x.docx"
ln -s "$R" "$H/link-root"
mk "$H/$SHA-at-home.docx"; mk "$H/tenant/$SHA-in-home-tenant.docx"
refused "the home directory" "\"$H\"" "the home directory"
refused "home, trailing slash" "\"$H/\"" "the home directory"
refused "home through .." "\"$H/work/..\"" "the home directory"
refused "outside home" "\"$T/elsewhere\"" "outside the home directory"
refused "root of the filesystem" '"/"' "outside the home directory"
refused "relative" '"work/downloads"' "not absolute"
refused "empty" '""' "empty"
refused "not a string" '{"a":1}' "empty"
refused "a symlink" "\"$H/link-root\"" "a symlink"
refused "a file" "\"$H/victim.txt\"" "not a directory"
echo '{"retention":{"download_roots":"/x"}}' > "$C"; has "not an array" "$(run)" "EXIT:1"
exists "refusal deletes nothing: home" "$H/tenant/$SHA-in-home-tenant.docx"
exists "refusal deletes nothing: outside" "$T/elsewhere/tenant/$SHA-x.docx"

echo "=== symlinked default root ==="
mv "$H/.cache/m365-mail-mcp-server" "$T/moved"; ln -s "$H/Documents" "$H/.cache/m365-mail-mcp-server"
echo '{}' > "$C"; has "refused" "$(run)" "EXIT:1"
rm "$H/.cache/m365-mail-mcp-server"; mv "$T/moved" "$H/.cache/m365-mail-mcp-server"

echo "=== the log holds no file name ==="
echo '{}' > "$C"
mk "$G/$SHA-Rossi-settlement.docx"
mkdir -p "$G/locked"
ALL=$(run; run --dry-run)
hasnt "stdout: no name" "$ALL" "Rossi"
hasnt "stdout: no hash" "$ALL" "$SHA"

echo "=== a failed delete is loud and leaks no name ==="
mk "$G/$SHA-Secret-name.docx"
chmod a-w "$G"
out=$(run); chmod u+w "$G"
if [[ $(id -u) == 0 ]]; then
  echo "    (root: permissions don't apply, skipped)"
else
  has "exit 1" "$out" "EXIT:1"
  has "counted" "$out" "errors=1"
  hasnt "find's stderr is not repeated" "$out" "Secret-name"
  eq "one row for CoS" "1" "$(sqlite3 "$T/test.db" "SELECT COUNT(*) FROM messages WHERE to_agent='cos' AND from_agent='download-cache-sweep' AND notify_ceo=1;")"
  hasnt "row holds no name" "$(sqlite3 "$T/test.db" "SELECT content FROM messages;")" "Secret-name"
  chmod a-w "$G"; run >/dev/null; chmod u+w "$G"
  eq "one row a day" "1" "$(sqlite3 "$T/test.db" "SELECT COUNT(*) FROM messages WHERE from_agent='download-cache-sweep';")"
fi

echo "=== usage ==="
has "unknown argument" "$(run --bogus)" "EXIT:2"
hasnt "log file: no name" "$(cat "$I/.juvant/logs/download-cache-sweep.log" 2>/dev/null)" "$SHA"
has "log stamped" "$(cat "$I/.juvant/logs/download-cache-sweep.log")" "=== RUN "

echo ""
echo "  download-cache-sweep: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
