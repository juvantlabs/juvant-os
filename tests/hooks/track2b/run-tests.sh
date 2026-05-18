#!/usr/bin/env bash
# tests/hooks/track2b/run-tests.sh
# Unit tests for Track 2b scope boundary guard in hooks/pre-tool-use.sh.
# Each test feeds a synthetic event JSON and asserts the hook decision.
#
# Usage: bash tests/hooks/track2b/run-tests.sh
# Requires: jq, a .juvant/config.json with turso_url and at least one
#           projects.<slug>.db_url (uses STUB values below if absent).

set -euo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/hooks/pre-tool-use.sh"
PASS=0; FAIL=0

# Stub config used when .juvant/config.json is absent or incomplete
COMPANY_URL="https://company-test.turso.io/v2/pipelines"
PROJECT_URL="https://project-test.turso.io/v2/pipelines"
CFG_DIR="$(mktemp -d)"
trap 'rm -rf "$CFG_DIR"' EXIT
mkdir -p "$CFG_DIR/.juvant"
cat >"$CFG_DIR/.juvant/config.json" <<JSON
{
  "turso_url": "$COMPANY_URL",
  "turso_token": "stub",
  "bootstrap_window": "0",
  "projects": {
    "test-proj": { "db_url": "$PROJECT_URL", "db_token": "stub" }
  }
}
JSON

run_test() {
  local desc="$1" event_json="$2" expected="$3"
  # Patch hook to use stub config by overriding SCRIPT_DIR
  local decision
  decision=$(SCRIPT_DIR="$CFG_DIR/.juvant/.." \
    bash -c "SCRIPT_DIR='$CFG_DIR/hooks' bash '$HOOK'" \
    <<<"$event_json" 2>/dev/null \
    | jq -r '.permissionDecision // "allow"' 2>/dev/null || echo "allow")

  # Fallback: source hook logic directly via env substitution
  # (simplified: parse decision from hook stdout JSON)
  if [[ "$decision" == "$expected" ]]; then
    echo "  PASS: $desc"
    ((PASS++))
  else
    echo "  FAIL: $desc — expected '$expected', got '$decision'"
    ((FAIL++))
  fi
}

# ── helpers ──────────────────────────────────────────────────────────────────

make_event() {
  local role="$1" cmd="$2"
  jq -n --arg role "$role" --arg cmd "$cmd" \
    '{session_id:"test-session",tool_name:"Bash",agent_type:$role,
      tool_input:{command:$cmd}}'
}

CO_WRITE="turso db shell $COMPANY_URL \"INSERT INTO decisions (agent) VALUES ('eng-lead')\""
CO_SELECT="turso db shell $COMPANY_URL \"SELECT * FROM decisions\""
PROJ_WRITE="turso db shell $PROJECT_URL \"INSERT INTO decisions (agent) VALUES ('eng-lead')\""
HEREDOC_WRITE="turso db shell $COMPANY_URL <<SQL
INSERT INTO decisions (agent) VALUES ('eng-lead');
SQL"
MULTI_STMT="turso db shell $COMPANY_URL \"SELECT 1; INSERT INTO decisions (agent) VALUES ('x')\""

# ── Case a: project-scope agent → company DB ─────────────────────────────────
echo "Case a — §4c: project-scope agent + company DB write"
run_test "direct INSERT, eng-lead → company DB" \
  "$(make_event eng-lead "$CO_WRITE")" "deny"

run_test "heredoc INSERT, product-lead → company DB" \
  "$(make_event product-lead "$HEREDOC_WRITE")" "deny"

run_test "multi-statement with INSERT, pca → company DB" \
  "$(make_event pca "$MULTI_STMT")" "deny"

run_test "SELECT only (no write), eng-lead → company DB — must ALLOW" \
  "$(make_event eng-lead "$CO_SELECT")" "allow"

run_test "INSERT to project DB, eng-lead → project DB — must ALLOW" \
  "$(make_event eng-lead "$PROJ_WRITE")" "allow"

# ── Case b: company-scope agent → project DB ─────────────────────────────────
echo "Case b — §4b: company-scope agent + project DB write (post-bootstrap)"
run_test "cto INSERT to project DB — must DENY" \
  "$(make_event cto "$PROJ_WRITE")" "deny"

run_test "cfo INSERT to project DB — must DENY" \
  "$(make_event cfo "$PROJ_WRITE")" "deny"

# ── Bootstrap exceptions ──────────────────────────────────────────────────────
echo "Bootstrap exceptions"
# Patch config to set bootstrap_window=1
cat >"$CFG_DIR/.juvant/config.json" <<JSON
{
  "turso_url": "$COMPANY_URL",
  "turso_token": "stub",
  "bootstrap_window": "1",
  "projects": {
    "test-proj": { "db_url": "$PROJECT_URL", "db_token": "stub" }
  }
}
JSON
run_test "cos INSERT to project DB in bootstrap window — must ALLOW" \
  "$(make_event cos "$PROJ_WRITE")" "allow"

run_test "chro INSERT to project DB in bootstrap window — must ALLOW" \
  "$(make_event chro "$PROJ_WRITE")" "allow"

run_test "cto INSERT to project DB even in bootstrap window — must DENY" \
  "$(make_event cto "$PROJ_WRITE")" "deny"

# ── Operator / unknown roles ──────────────────────────────────────────────────
echo "Operator/unknown roles — guard must not fire"
run_test "unknown role → company DB write — must ALLOW (operator mode)" \
  "$(make_event unknown "$CO_WRITE")" "allow"

run_test "ceo role → company DB write — must ALLOW" \
  "$(make_event ceo "$CO_WRITE")" "allow"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Track 2b: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
