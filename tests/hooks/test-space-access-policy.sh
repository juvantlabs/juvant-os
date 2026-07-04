#!/usr/bin/env bash
# tests/hooks/test-space-access-policy.sh
#
# Canary for the Track 2e sensitive-space deny-list (ADR 0025 / ADR 0027),
# harvested and generalized from the instance reference proven under
# decisions#210. Tenant-agnostic: uses a SYNTHETIC `.security.space_access`
# fixture (a fake driveId), so it always runs — no placeholder gating.
#
# This is the framework REGRESSION GATE for the space-access perimeter:
# re-run it on every change to hooks/pre-tool-use.sh AND on every bump of an
# MCP whose tools the policy classifies (a new tool must not slip in
# unclassified for non-allowlisted agents — gate d / deny-by-default).
#
# Run:  bash tests/hooks/test-space-access-policy.sh
# Exit: 0 on all-pass, non-zero on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOKS_DIR="$ROOT_DIR/hooks"

# ── Setup: temp SQLite + fake-turso on PATH + fixture config ──
TMPROOT=$(mktemp -d /tmp/juvant-space-access-canary-XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

TEST_DB="$TMPROOT/test.db"
sqlite3 "$TEST_DB" < "$ROOT_DIR/scripts/schema.sql"

FAKE_BIN="$TMPROOT/bin"; mkdir -p "$FAKE_BIN"
cp "$SCRIPT_DIR/fake-turso.sh" "$FAKE_BIN/turso"; chmod +x "$FAKE_BIN/turso"
export PATH="$FAKE_BIN:$PATH"
export JUVANT_TEST_DB_FILE="$TEST_DB"
export TURSO_URL="libsql://test.fake"
export TURSO_TOKEN="test-token"

FAKE_DRIVE_ID="b!TESTDRIVEID_legal_synthetic_0123456789"
FAKE_CONFIG="$TMPROOT/config.json"
cat > "$FAKE_CONFIG" <<JSON
{
  "db": { "provider": "turso", "url": "libsql://test.fake" },
  "security": {
    "space_access": [
      {
        "space": "legal-ip",
        "tool_prefix": "mcp__m365-graph__",
        "drive_ids": ["$FAKE_DRIVE_ID"],
        "path_patterns": ["legal-ip", "legal_ip", "/IP/", "/IP"],
        "allowlist": ["lex", "atlas", "cso"]
      }
    ]
  }
}
JSON
export JUVANT_CONFIG="$FAKE_CONFIG"
# The Track 2e audit row is spooled (FEAT-051), not written inline, so the
# row reaches security_audit_log only after a drain. Isolate the spool to the
# temp dir and provide reset/drain helpers for the audit-row assertions.
export JUVANT_SPOOL="$TMPROOT/audit-spool.sql"

# Clear both the table AND any pending spooled rows (prior ops in this run
# spool audit rows too) so each audit block starts from a clean slate.
_reset_audit() { sqlite3 "$TEST_DB" "DELETE FROM security_audit_log;"; rm -f "$JUVANT_SPOOL"; }
# Flush spooled audit rows into security_audit_log before asserting on them.
_drain_audit() { bash "$ROOT_DIR/helpers/drain-audit-spool.sh" >/dev/null 2>&1 || true; }

# ── Assertion helpers ──
PASS=0; FAIL=0
t_assert() { # name expected actual
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "  PASS: $1";
  else FAIL=$((FAIL+1)); echo "  FAIL: $1 (expected '$2', got '$3')"; fi
}
# decide ROLE TOOL ARGS_JSON  → echoes permissionDecision
# ARGS_JSON must be valid JSON (build via jq to avoid nested-quote mangling).
decide() {
  local role="$1" tool="$2" args="$3"
  local ev; ev=$(jq -n --arg t "$tool" --argjson a "$args" \
    '{tool_name:$t, tool_input:$a, session_id:"sess-sa", agent_type:""}')
  echo "$ev" | AGENT_ROLE="$role" bash "$HOOKS_DIR/pre-tool-use.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.permissionDecision'
}

# Pre-built arg payloads (jq-constructed → always valid JSON, no shell escaping).
ARGS_DRIVE=$(jq -nc --arg d "$FAKE_DRIVE_ID" '{drive_id:$d, path:"/x"}')
ARGS_DRIVE_ONLY=$(jq -nc --arg d "$FAKE_DRIVE_ID" '{drive_id:$d}')

echo "=== Core deny-list — driveId match || path-pattern match ==="
t_assert "non-allowlisted cfo + driveId hit (write) → deny" "deny" \
  "$(decide cfo mcp__m365-graph__upload_file "$ARGS_DRIVE")"
t_assert "non-allowlisted cmo + legal-ip path hit → deny" "deny" \
  "$(decide cmo mcp__m365-graph__get_file_content '{"path":"/Company/01 - Legal/IP/patent.docx"}')"
t_assert "allowlisted lex + driveId hit → allow" "allow" \
  "$(decide lex mcp__m365-graph__upload_file "$ARGS_DRIVE")"
t_assert "project-suffixed allowlist (dog-ai-lex) + driveId hit → allow" "allow" \
  "$(decide dog-ai-lex mcp__m365-graph__get_file_content "$ARGS_DRIVE_ONLY")"

echo "=== Coverage gate (a) — path-only op with no driveId still matches ==="
t_assert "non-allowlisted cfo + path-only 'legal-ip' → deny" "deny" \
  "$(decide cfo mcp__m365-graph__list_files '{"path":"/sites/legal-ip/Shared"}')"

echo "=== Coverage gate (b) — search must be scope-bound ==="
t_assert "non-allowlisted cfo + unscoped search → deny" "deny" \
  "$(decide cfo mcp__m365-graph__search_files '{"query":"merger"}')"
t_assert "allowlisted atlas + unscoped search → allow" "allow" \
  "$(decide atlas mcp__m365-graph__search_files '{"query":"merger"}')"

echo "=== Coverage gate (c) — resolution helper refuses the sensitive driveId ==="
t_assert "non-allowlisted cmo + get_drive with sensitive driveId in args → deny" "deny" \
  "$(decide cmo mcp__m365-graph__get_drive "$ARGS_DRIVE_ONLY")"

echo "=== Coverage gate (d) — no hook-visible target + unclassified → deny ==="
t_assert "non-allowlisted cfo + unclassified tool, no target → deny" "deny" \
  "$(decide cfo mcp__m365-graph__frobnicate '{}')"
t_assert "allowlisted atlas + unclassified tool, no target → allow" "allow" \
  "$(decide atlas mcp__m365-graph__frobnicate '{}')"

echo "=== Class C — escalation (sharing) op on the sensitive space → deny ==="
t_assert "non-allowlisted cfo + share op on legal-ip path → deny" "deny" \
  "$(decide cfo mcp__m365-graph__create_sharing_link '{"path":"/legal-ip/secret"}')"

echo "=== Non-sensitive ops are NOT blocked for ordinary agents ==="
t_assert "cfo + finance path (no markers) → allow" "allow" \
  "$(decide cfo mcp__m365-graph__get_file_content '{"path":"/Company/02 - Finance/ledger.xlsx"}')"
t_assert "cmo + gtm path → allow" "allow" \
  "$(decide cmo mcp__m365-graph__list_files '{"path":"/Company/06 - GTM/Social"}')"

echo "=== No-op when .security.space_access is absent (default framework state) ==="
NOSPACE_CFG="$TMPROOT/nospace.json"
echo '{ "db": { "provider": "turso", "url": "libsql://test.fake" } }' > "$NOSPACE_CFG"
t_assert "absent space_access → ordinary m365 op allowed" "allow" \
  "$(JUVANT_CONFIG="$NOSPACE_CFG" decide cfo mcp__m365-graph__upload_file "$ARGS_DRIVE_ONLY")"

echo "=== Condition #1 — security_audit_log fires (expected + unexpected), severity=high ==="
# Re-run two ops to seed audit rows in a clean DB.
_reset_audit
decide lex mcp__m365-graph__get_file_content "$ARGS_DRIVE_ONLY" >/dev/null   # allowlisted → expected=true
decide cfo mcp__m365-graph__get_file_content "$ARGS_DRIVE_ONLY" >/dev/null   # non-allowlisted → expected=false
_drain_audit
t_assert "allowlisted op → audit row expected=true" "1" \
  "$(sqlite3 "$TEST_DB" "SELECT count(*) FROM security_audit_log WHERE severity='high' AND finding LIKE '%legal-ip%expected=true%';")"
t_assert "non-allowlisted op → audit row expected=false" "1" \
  "$(sqlite3 "$TEST_DB" "SELECT count(*) FROM security_audit_log WHERE severity='high' AND finding LIKE '%legal-ip%expected=false%';")"
t_assert "two legal-ip ops → 2 high-severity audit rows" "2" \
  "$(sqlite3 "$TEST_DB" "SELECT count(*) FROM security_audit_log WHERE severity='high';")"

echo "=== gate-c: blind enumeration (empty args) denied — no driveId leak (bug_010) ==="
t_assert "non-allowlisted cfo + list_drives {} → deny" "deny" \
  "$(decide cfo mcp__m365-graph__list_drives '{}')"
t_assert "non-allowlisted cfo + list_shared_drives {} → deny" "deny" \
  "$(decide cfo mcp__m365-graph__list_shared_drives '{}')"
t_assert "non-allowlisted cfo + list_sites {} → deny" "deny" \
  "$(decide cfo mcp__m365-graph__list_sites '{}')"
t_assert "allowlisted atlas + list_drives {} → allow" "allow" \
  "$(decide atlas mcp__m365-graph__list_drives '{}')"

echo "=== gate-d: ANY target-less op denied regardless of class (bug_011) ==="
t_assert "non-allowlisted cfo + list_members {} (class A, no target) → deny" "deny" \
  "$(decide cfo mcp__m365-graph__list_members '{}')"

echo "=== bug_005: precautionary gate-b/d denies do NOT fire a space alert ==="
_reset_audit
decide cfo mcp__m365-graph__search_files '{"query":"merger"}' >/dev/null   # gate-b deny, no space evidence
decide cfo mcp__m365-graph__frobnicate '{}' >/dev/null                     # gate-d deny, no space evidence
_drain_audit
t_assert "gate-b + gate-d denies (no evidence) → 0 high-severity audit rows" "0" \
  "$(sqlite3 "$TEST_DB" "SELECT count(*) FROM security_audit_log WHERE severity='high';")"

echo "=== bug_004: audit category derived from (op-class, decision) ==="
_reset_audit
decide cfo mcp__m365-graph__get_file_content   "$ARGS_DRIVE_ONLY" >/dev/null  # A:deny → unauthorized-read
decide cfo mcp__m365-graph__create_sharing_link "$ARGS_DRIVE_ONLY" >/dev/null  # C:deny → unauthorized-escalation
decide lex mcp__m365-graph__get_file_content   "$ARGS_DRIVE_ONLY" >/dev/null  # A:allow → access-event
_drain_audit
t_assert "Class-A deny → category=unauthorized-read" "1" \
  "$(sqlite3 "$TEST_DB" "SELECT count(*) FROM security_audit_log WHERE category='unauthorized-read';")"
t_assert "Class-C deny → category=unauthorized-escalation" "1" \
  "$(sqlite3 "$TEST_DB" "SELECT count(*) FROM security_audit_log WHERE category='unauthorized-escalation';")"
t_assert "allowlisted allow → category=access-event" "1" \
  "$(sqlite3 "$TEST_DB" "SELECT count(*) FROM security_audit_log WHERE category='access-event';")"

echo "======================================================="
echo " RESULTS: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then echo " CANARY STATUS: PASS"; exit 0
else echo " CANARY STATUS: FAIL"; exit 1; fi
