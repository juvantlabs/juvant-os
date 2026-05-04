#!/usr/bin/env bash
# tests/hooks/test-pre-tool-use.sh
# Bash-based test for hooks/pre-tool-use.sh — verifies the universal
# deny-list and per-agent allow-list logic correctly produce
# permissionDecision=deny vs allow.
#
# This test runs WITHOUT Turso connectivity: the hook handles missing
# TURSO_URL gracefully (skips the audit-log write, still returns the
# permission decision). Set TURSO_URL=disabled here to force the
# audit-log path to be skipped and isolate the policy logic.
#
# Run: ./tests/hooks/test-pre-tool-use.sh
# CI: invoked by .github/workflows/lint.yml as a separate step.
#
# Exit code: 0 = all pass, 1 = any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../../hooks/pre-tool-use.sh"

# Force-skip the audit-log Turso write. The hook reads TURSO_URL/TOKEN
# from env or .juvant/config.json; both empty + a unreadable config
# triggers the "no creds, skip log" path while still returning the
# permission decision.
unset TURSO_URL TURSO_TOKEN
export TURSO_URL=""
export TURSO_TOKEN=""

PASS=0
FAIL=0
FAILED_CASES=()

# Helper: run the hook with stdin event, expect substring in output
expect_decision() {
  local desc="$1"
  local event_json="$2"
  local expected="$3"  # "allow" or "deny"
  local agent_role="${4:-cos}"

  out=$(echo "$event_json" | env AGENT_ROLE="$agent_role" bash "$HOOK" 2>/dev/null || true)
  decision=$(echo "$out" | jq -r '.permissionDecision // ""' 2>/dev/null || echo "")

  if [[ "$decision" == "$expected" ]]; then
    PASS=$((PASS+1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$desc — expected '$expected', got '$decision'")
    echo "  ✗ $desc — expected '$expected', got '$decision'"
  fi
}

echo "=== pre-tool-use.sh — universal deny-list ==="

# Universal denies — no agent should pass these
expect_decision "rm -rf / blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"rm -rf / "},"session_id":"test"}' \
  deny coo

expect_decision "sudo blocked even for COO" \
  '{"tool_name":"Bash","tool_input":{"command":"sudo apt update"},"session_id":"test"}' \
  deny coo

expect_decision "git push --force to main blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"},"session_id":"test"}' \
  deny coo

expect_decision "gh repo delete blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"gh repo delete juvantlabs/important"},"session_id":"test"}' \
  deny coo

expect_decision "DROP DATABASE blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"psql -c \"DROP DATABASE production\""},"session_id":"test"}' \
  deny coo

expect_decision "fork-bomb blocked" \
  '{"tool_name":"Bash","tool_input":{"command":":(){ :|:& };:"},"session_id":"test"}' \
  deny coo

expect_decision "shutdown blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"shutdown now"},"session_id":"test"}' \
  deny coo

echo ""
echo "=== pre-tool-use.sh — per-agent allow-list ==="

# CFO has no Bash — every command denies
expect_decision "CFO cannot run npm (not in allow-list)" \
  '{"tool_name":"Bash","tool_input":{"command":"npm install"},"session_id":"test"}' \
  deny cfo

expect_decision "CFO cannot run echo (not in allow-list)" \
  '{"tool_name":"Bash","tool_input":{"command":"echo hello"},"session_id":"test"}' \
  deny cfo

# CoS allow-list includes git, gh, turso, jq
expect_decision "CoS can run git status" \
  '{"tool_name":"Bash","tool_input":{"command":"git status"},"session_id":"test"}' \
  allow cos

expect_decision "CoS can run jq" \
  '{"tool_name":"Bash","tool_input":{"command":"jq .foo file.json"},"session_id":"test"}' \
  allow cos

expect_decision "CoS cannot run python (not in allow-list)" \
  '{"tool_name":"Bash","tool_input":{"command":"python script.py"},"session_id":"test"}' \
  deny cos

# eng-* allow-list includes npm, node, python
expect_decision "eng-api can run npm install" \
  '{"tool_name":"Bash","tool_input":{"command":"npm install"},"session_id":"test"}' \
  allow eng-api

expect_decision "eng-api can run pytest" \
  '{"tool_name":"Bash","tool_input":{"command":"pytest tests/"},"session_id":"test"}' \
  allow eng-api

expect_decision "eng-api cannot run gh repo create (not in allow-list — that's COO)" \
  '{"tool_name":"Bash","tool_input":{"command":"gh repo create"},"session_id":"test"}' \
  deny eng-api

# COO can run gh
expect_decision "COO can run gh repo view" \
  '{"tool_name":"Bash","tool_input":{"command":"gh repo view juvantlabs/juvant-os"},"session_id":"test"}' \
  allow coo

# Unknown role — denies all Bash
expect_decision "Unknown role denied" \
  '{"tool_name":"Bash","tool_input":{"command":"git status"},"session_id":"test"}' \
  deny unknown-role

echo ""
echo "=== pre-tool-use.sh — non-Bash tools ==="

# Read tool — always allowed (not subject to Bash policy)
expect_decision "Read tool allowed for any agent" \
  '{"tool_name":"Read","tool_input":{"file_path":"/tmp/foo"},"session_id":"test"}' \
  allow cfo

expect_decision "Edit tool allowed" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/foo","old_string":"a","new_string":"b"},"session_id":"test"}' \
  allow cfo

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do
    echo "  - $c"
  done
  exit 1
fi

echo "OK — all $PASS test cases passed."
