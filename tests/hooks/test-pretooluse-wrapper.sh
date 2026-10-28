#!/usr/bin/env bash
# tests/hooks/test-pretooluse-wrapper.sh
#
# Behavioural test for the PreToolUse REGISTRATION WRAPPER (decisions#298 /
# decisions#300 item 6). `onFailure: "block"` (FEAT-061) only covers a
# pre-tool-use.sh that starts and fails; a MISSING script is handled by the
# wrapper command itself, which must exit 2 (Claude Code's uniform "block the
# tool call" exit code) instead of falling through to exit 0 (allow).
#
# The wrapper is executed exactly as Claude Code runs it: the `command` string
# taken verbatim from both the canonical template
# (scripts/templates/hooks-registration.json) and the synced
# .claude/settings.json, with CLAUDE_PROJECT_DIR pointing at a scratch project.
#
# What this does NOT prove: that Claude Code honours exit 2 for a given client
# version. That is verified live per instance (hooks/README.md live smoke).
#
# Run:  bash tests/hooks/test-pretooluse-wrapper.sh
# Exit: 0 on all-pass, non-zero on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMPROOT=$(mktemp -d /tmp/juvant-pretooluse-wrapper-XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
t_assert() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1)); echo "  ok   $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name (expected '$expected', got '$actual')"
  fi
}

EVENT='{"tool_name":"Bash","session_id":"sess-wrapper","tool_input":{"command":"git status"}}'

# run_wrapper <command-string> <project-dir> → sets RC and ERR
run_wrapper() {
  local cmd="$1" proj="$2"
  ERR=$(printf '%s' "$EVENT" | CLAUDE_PROJECT_DIR="$proj" bash -c "$cmd" 2>&1 >/dev/null)
  RC=$?
}

for src in scripts/templates/hooks-registration.json .claude/settings.json; do
  echo "── $src"
  PRE_CMD=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$ROOT_DIR/$src")
  t_assert "$src: PreToolUse wrapper command present" "yes" \
    "$([[ -n "$PRE_CMD" && "$PRE_CMD" != "null" ]] && echo yes || echo no)"

  # 1. Script missing → exit 2 (tool blocked) with a stderr reason.
  proj_missing="$TMPROOT/missing-${src//\//_}"
  mkdir -p "$proj_missing/hooks"
  run_wrapper "$PRE_CMD" "$proj_missing"
  t_assert "$src: missing pre-tool-use.sh → exit 2 (blocked)" "2" "$RC"
  t_assert "$src: missing script → stderr names the failure" "yes" \
    "$([[ "$ERR" == *"pre-tool-use.sh"*"failing closed"* ]] && echo yes || echo no)"

  # 2. Script present → wrapper passes the script's verdict through unchanged.
  proj_ok="$TMPROOT/ok-${src//\//_}"
  mkdir -p "$proj_ok/hooks"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$proj_ok/hooks/pre-tool-use.sh"
  run_wrapper "$PRE_CMD" "$proj_ok"
  t_assert "$src: present script allowing → exit 0" "0" "$RC"

  proj_deny="$TMPROOT/deny-${src//\//_}"
  mkdir -p "$proj_deny/hooks"
  printf '#!/usr/bin/env bash\ncat >/dev/null\necho denied >&2\nexit 2\n' > "$proj_deny/hooks/pre-tool-use.sh"
  run_wrapper "$PRE_CMD" "$proj_deny"
  t_assert "$src: present script denying → exit 2" "2" "$RC"

  # 3. Observational hooks keep fail-open on a missing script (a missing
  #    session hook must not wedge the session).
  for ev in SessionStart PostToolUse Stop; do
    OBS_CMD=$(jq -r --arg e "$ev" '.hooks[$e][0].hooks[0].command' "$ROOT_DIR/$src")
    run_wrapper "$OBS_CMD" "$proj_missing"
    t_assert "$src: $ev wrapper with missing script → exit 0" "0" "$RC"
  done
done

# 4. Template and settings carry the identical PreToolUse wrapper.
t_assert "template ↔ settings PreToolUse wrapper parity" \
  "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$ROOT_DIR/scripts/templates/hooks-registration.json")" \
  "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$ROOT_DIR/.claude/settings.json")"

echo ""
echo "  pretooluse-wrapper: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
