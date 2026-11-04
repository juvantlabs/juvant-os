#!/usr/bin/env bash
# tests/hooks/test-shell-tools.sh
# BUG-100 — a command run through Monitor gets the same verdict as through Bash,
# track by track; the audit row keeps the real tool; any other non-MCP tool
# carrying a command is denied until it is classified.
# Runs the real hook on a throwaway copy, as a deployed instance: nothing is
# executed, the hook only decides.
#
# SC2016: the cases are literal shell text, meant not to expand.
# shellcheck disable=SC2016

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for dep in jq sqlite3; do command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }; done

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/bin" "$T/inst/.juvant"
cp -R "$REPO/hooks" "$T/inst/hooks"
cp "$REPO/tests/hooks/fake-turso.sh" "$T/bin/turso"
cp "$REPO/tests/hooks/fake-libsql-curl.sh" "$T/bin/curl"
chmod +x "$T/bin/turso" "$T/bin/curl"
sqlite3 "$T/test.db" < "$REPO/scripts/schema.sql" 2>/dev/null
echo '{}' > "$T/inst/.juvant/config.json"
SPOOL="$T/spool.sql"

RC=0; REASON=""
# hook <event json>
hook() {
  local out
  RC=0
  out=$(cd "$T/inst" && printf '%s' "$1" | HOME="$T/home" PATH="$T/bin:$PATH" JUVANT_FRAMEWORK_DEV=0 \
    JUVANT_CONFIG="$T/inst/.juvant/config.json" JUVANT_SPOOL="$SPOOL" JUVANT_TEST_DB_FILE="$T/test.db" \
    TURSO_URL=libsql://test.fake TURSO_TOKEN=x bash "$T/inst/hooks/pre-tool-use.sh" 2>/dev/null) || RC=$?
  REASON=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null | tail -1)
}
# ev <tool> <role or ""> <tool_input json>
ev() {
  jq -cn --arg t "$1" --arg r "$2" --argjson i "$3" \
    '{session_id:"s",tool_name:$t,tool_input:$i} + (if $r == "" then {} else {agent_type:$r} end)'
}
shell_input() { jq -cn --arg c "$1" '{command:$c,description:"x",timeout_ms:5000}'; }

# parity <expected rc through Bash> <role> <command>: Bash is the control.
parity() {
  local want="$1" role="$2" cmd="$3" brc breason
  hook "$(ev Bash "$role" "$(shell_input "$cmd")")"; brc=$RC; breason=$REASON
  if [[ "$brc" == "$want" ]]; then ok; else no "control: Bash rc=$brc, expected $want: $cmd"; fi
  hook "$(ev Monitor "$role" "$(shell_input "$cmd")")"
  if [[ "$RC" == "$brc" ]]; then ok; else no "Monitor rc=$RC, Bash rc=$brc: $cmd"; fi
  if [[ "$REASON" == "$breason" ]]; then ok; else no "reason differs for: $cmd"; fi
}

echo "=== denied through Bash, denied through Monitor ==="
for role in "" cfo; do
  parity 2 "$role" 'pandoc --version'                      # allow-list
  parity 2 "$role" 'sudo true'                             # universal deny-list
  parity 2 "$role" 'rm -rf ~'                              # universal deny-list
  parity 2 "$role" 'jq . x; pandoc --version'              # every command of a line
  parity 2 "$role" 'az group delete --name x'              # R3 cloud read-only
  parity 2 "$role" 'sed -i "" s/a/b/ hooks/pre-tool-use.sh' # Track 2f tamper floor
  parity 2 "$role" 'cat .juvant/secrets.json'              # secrets gate
done
parity 2 cfo 'gh pr merge 1'                               # single writer
parity 2 cfo 'turso db shell x "DROP TABLE decisions"'     # SQL deny-list

echo "=== waiting keeps working ==="
for role in "" cos; do
  parity 0 "$role" 'sleep 30'
  parity 0 "$role" 'until gh api repos/o/r >/dev/null; do sleep 30; done'
  parity 0 "$role" 'tail -f run.log | grep --line-buffered ERROR'
done

echo "=== Monitor with no shell ==="
hook "$(ev Monitor "" '{"ws":{"url":"wss://events.example.com/x"},"description":"x","timeout_ms":5000}')"
if [[ "$RC" == 0 ]]; then ok; else no "ws source denied (rc=$RC)"; fi

echo "=== the audit row keeps the real tool ==="
: > "$SPOOL"
hook "$(ev Monitor "" "$(shell_input 'sleep 7')")"
if grep -q "'Monitor'" "$SPOOL"; then ok; else no "allowed Monitor call not logged as Monitor"; fi
if grep -q "'Bash'" "$SPOOL"; then no "allowed Monitor call logged as Bash"; else ok; fi
: > "$SPOOL"
hook "$(ev Monitor "" "$(shell_input 'pandoc --version')")"
if grep -q "'Monitor'" "$SPOOL" && grep -q "'denied'" "$SPOOL"; then ok; else no "denied Monitor call not logged as a Monitor denial"; fi

echo "=== an unclassified tool carrying a command ==="
hook "$(ev SomeNewShell "" '{"command":"ls"}')"
if [[ "$RC" == 2 && "$REASON" == deny:unclassified-shell-tool:SomeNewShell* ]]; then ok; else no "unclassified tool not denied (rc=$RC)"; fi
hook "$(ev SomeNewShell "" '{"command":["ls","-l"]}')"
if [[ "$RC" == 2 ]]; then ok; else no "non-string command not denied (rc=$RC)"; fi

echo "=== everything else is untouched ==="
hook "$(ev mcp__some__tool "" '{"command":"not a shell"}')"
if [[ "$RC" == 0 ]]; then ok; else no "MCP tool with a command field denied (rc=$RC)"; fi
hook "$(ev Read "" '{"file_path":"README.md"}')"
if [[ "$RC" == 0 ]]; then ok; else no "Read denied (rc=$RC)"; fi
hook "$(ev WebFetch "" '{"url":"https://example.com","prompt":"x"}')"
if [[ "$RC" == 0 ]]; then ok; else no "WebFetch denied (rc=$RC)"; fi

echo ""
echo "  shell-tools: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
