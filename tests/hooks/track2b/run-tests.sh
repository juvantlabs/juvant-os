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
  "turso_db_name": "company-test",
  "projects": {
    "test-proj": {
      "url": "$PROJECT_URL",
      "turso_db_name": "project-test",
      "db_token": "stub"
    }
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
CO_WRITE_SHORT='turso db shell company-test "INSERT INTO decisions (agent) VALUES ('"'"'eng-lead'"'"')"'
CO_SELECT="turso db shell $COMPANY_URL \"SELECT * FROM decisions\""
PROJ_WRITE="turso db shell $PROJECT_URL \"INSERT INTO decisions (agent) VALUES ('eng-lead')\""
PROJ_WRITE_SHORT='turso db shell project-test "INSERT INTO decisions (agent) VALUES ('"'"'eng-lead'"'"')"'
HEREDOC_WRITE="turso db shell $COMPANY_URL <<SQL
INSERT INTO decisions (agent) VALUES ('eng-lead');
SQL"
MULTI_STMT="turso db shell $COMPANY_URL \"SELECT 1; INSERT INTO decisions (agent) VALUES ('x')\""
# Token-boundary: suffix-collision names must NOT trigger guard against base name
CO_WRITE_COLLISION='turso db shell company-test-external "INSERT INTO decisions (agent) VALUES ('"'"'x'"'"')"'
PROJ_WRITE_COLLISION='turso db shell project-test-mirror "INSERT INTO decisions (agent) VALUES ('"'"'x'"'"')"'

# ── Case a: project-scope agent → company DB ─────────────────────────────────
echo "Case a — §4c: project-scope agent + company DB write"
run_test "direct INSERT via URL, eng-lead → company DB" \
  "$(make_event eng-lead "$CO_WRITE")" "deny"

run_test "short-form INSERT, eng-lead → company-test (BUG-033 Bug 2)" \
  "$(make_event eng-lead "$CO_WRITE_SHORT")" "deny"

run_test "heredoc INSERT, product-lead → company DB" \
  "$(make_event product-lead "$HEREDOC_WRITE")" "deny"

run_test "multi-statement with INSERT, pca → company DB" \
  "$(make_event pca "$MULTI_STMT")" "deny"

run_test "SELECT only (no write), eng-lead → company DB — must ALLOW" \
  "$(make_event eng-lead "$CO_SELECT")" "allow"

run_test "INSERT to project DB via URL, eng-lead → must ALLOW" \
  "$(make_event eng-lead "$PROJ_WRITE")" "allow"

run_test "short-form INSERT, eng-lead → project-test — must ALLOW" \
  "$(make_event eng-lead "$PROJ_WRITE_SHORT")" "allow"

# ── Case b: company-scope agent → project DB ─────────────────────────────────
echo "Case b — §4b: company-scope agent + project DB write (post-bootstrap)"
run_test "cto INSERT via URL → project DB — must DENY" \
  "$(make_event cto "$PROJ_WRITE")" "deny"

run_test "cto short-form INSERT → project-test — must DENY (BUG-033 Bug 1+2)" \
  "$(make_event cto "$PROJ_WRITE_SHORT")" "deny"

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

# ── Token-boundary: suffix-collision names must NOT trigger guard ─────────────
echo "Token-boundary — suffix-collision names"
run_test "company-test-external must NOT match company-test guard" \
  "$(make_event eng-lead "$CO_WRITE_COLLISION")" "allow"

run_test "project-test-mirror must NOT match project-test guard (cto)" \
  "$(make_event cto "$PROJ_WRITE_COLLISION")" "allow"

# ── Case c — §4d: company agent + project ref in decisions INSERT ─────────────
# Reset config to bootstrap_window=0 with a project slug entry
cat >"$CFG_DIR/.juvant/config.json" <<JSON
{
  "turso_url": "$COMPANY_URL",
  "turso_token": "stub",
  "turso_db_name": "company-test",
  "bootstrap_window": "0",
  "projects": {
    "test-proj": {
      "url": "$PROJECT_URL",
      "turso_db_name": "project-test",
      "db_token": "stub"
    }
  }
}
JSON
echo "Case c — §4d: company agent inserting project-scoped content into company DB"
_SEC_WRITE_PROJ='turso db shell '"$COMPANY_URL"' "INSERT INTO decisions (agent,title,rationale) VALUES ('"'"'cso'"'"','"'"'rotate test-proj secret'"'"','"'"'juvantio/test-proj needs rotation'"'"')"'
_SEC_WRITE_CWSCOPE='turso db shell '"$COMPANY_URL"' "INSERT INTO decisions (agent,title,rationale) VALUES ('"'"'cso'"'"','"'"'company-wide secret rotation'"'"','"'"'all projects including test-proj'"'"')"'
_SEC_WRITE_NOPROJ='turso db shell '"$COMPANY_URL"' "INSERT INTO decisions (agent,title,rationale) VALUES ('"'"'cso'"'"','"'"'rotate infra key'"'"','"'"'shared AWS key rotation'"'"')"'

run_test "cso INSERT decisions + project ref in SQL → must DENY (§4d)" \
  "$(make_event cso "$_SEC_WRITE_PROJ")" "deny"

run_test "cso INSERT decisions + 'company-wide' token → must ALLOW (§4d exception)" \
  "$(make_event cso "$_SEC_WRITE_CWSCOPE")" "allow"

run_test "cso INSERT decisions + no project ref → must ALLOW" \
  "$(make_event cso "$_SEC_WRITE_NOPROJ")" "allow"

# ── Track 2c — Orchestrator boundary ─────────────────────────────────────────
# Reset config with a working_tree entry
_WT="$CFG_DIR/projects/test-proj"
mkdir -p "$_WT"
cat >"$CFG_DIR/.juvant/config.json" <<JSON
{
  "turso_url": "$COMPANY_URL",
  "turso_token": "stub",
  "turso_db_name": "company-test",
  "bootstrap_window": "0",
  "projects": {
    "test-proj": {
      "url": "$PROJECT_URL",
      "turso_db_name": "project-test",
      "db_token": "stub",
      "working_tree": "$_WT"
    }
  }
}
JSON
echo "Track 2c — Orchestrator boundary (§9)"
_PROJ_SRC_WRITE="$(make_event cos "")"  # placeholder — use jq below

_ev_proj_write=$(jq -n \
  --arg wt "$_WT/src/App.tsx" \
  '{session_id:"test",tool_name:"Edit",agent_type:"cos",tool_input:{file_path:$wt}}')
_ev_company_write=$(jq -n \
  '{session_id:"test",tool_name:"Edit",agent_type:"cos",tool_input:{file_path:"/repo/JUVANT_OS.md"}}')
_ev_proj_write_engl=$(jq -n \
  --arg wt "$_WT/src/App.tsx" \
  '{session_id:"test",tool_name:"Edit",agent_type:"eng-lead",tool_input:{file_path:$wt}}')

run_test "cos Edit file inside project working_tree → must DENY (§9)" \
  "$_ev_proj_write" "deny"

run_test "cos Edit company-level file (JUVANT_OS.md) → must ALLOW" \
  "$_ev_company_write" "allow"

run_test "eng-lead Edit file inside project working_tree → must ALLOW" \
  "$_ev_proj_write_engl" "allow"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Track 2b/2c: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
