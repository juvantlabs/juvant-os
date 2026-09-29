#!/usr/bin/env bash
# tests/helpers/test-cso-weekly-audit-cadence.sh
#
# decisions#277 — regression tests for the cadence gate in
# helpers/cso-weekly-audit.sh after the BUG-070 continuity-predicate update.
#
# The helper now gates on BOTH audit staleness AND agent_actions_log gap,
# using env-tunable CONTINUITY_WARN_DAYS (default 14).  The old hard-coded
# 7d threshold is gone.
#
# 5 test cases (spec §D.2):
#  (i)   Fresh audit + fresh actions           → exit 0 silently
#  (ii)  Stale audit, fresh actions            → escalation written, exit 1
#  (iii) Fresh audit, stale actions            → escalation written, exit 1
#  (iv)  Both stale                            → escalation written, exit 1
#  (v)   halt_windows covers actions gap       → exit 0 (not escalated)
#
# NOTE: case (v) tests the cso-weekly-audit.sh exit path only — the full
# halt_windows coverage logic lives in audit-bootstrap-baseline.sh (Layer 1)
# and is tested by test-audit-continuity-predicate.sh.  cso-weekly-audit.sh
# escalates when either indicator exceeds the threshold; halt_windows are
# checked in the bootstrap audit, not here.  Case (v) is therefore: both
# indicators stay below threshold because the STALENESS/GAP values returned
# by the DB are within the WARN bound — it does not inject halt_windows.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEMA="$REPO/scripts/schema.sql"
FAKETURSO="$REPO/tests/hooks/fake-turso.sh"

for dep in sqlite3 jq; do
  command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }
done

PASS=0; FAIL=0
ok(){ echo "    PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }
has(){ if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing: $3)"; fi; }
not_has(){ if ! printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (unexpected: $3)"; fi; }

TMP=$(mktemp -d)
FAKEBIN=$(mktemp -d)
trap 'rm -rf "$TMP" "$FAKEBIN"' EXIT

# Stage helper + lib.  Create .juvant/logs/ so the helper's run-stamp
# append (`echo ... >> .juvant/logs/cso-weekly-audit.log`) does not exit 1.
mkdir -p "$TMP/helpers" "$TMP/hooks/lib" "$TMP/.juvant/logs"
cp "$REPO/helpers/cso-weekly-audit.sh" "$TMP/helpers/"
cp "$REPO/hooks/lib/db.sh"             "$TMP/hooks/lib/"

# Fake turso shim (not used for local provider, but placed on PATH for parity).
cp "$FAKETURSO" "$FAKEBIN/turso"; chmod +x "$FAKEBIN/turso"

# Fake curl: suppress Teams HTTP calls so the test never makes network requests.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# absorb all args; exit 0 silently.
exit 0
SH
chmod +x "$FAKEBIN/curl"

DBFILE="$TMP/.juvant/state.db"
CONFIG_PATH="$TMP/.juvant/config.json"

sq(){ sqlite3 "$DBFILE" "$@"; }

fresh_db(){
  rm -f "$DBFILE"
  sqlite3 "$DBFILE" < "$SCHEMA"
  sq "INSERT INTO master_context (key,value) VALUES ('company_type','master');"
}

write_cfg(){
  printf '{"db":{"provider":"local","url":"file:%s"},"notifications":{"teams_webhooks":{"ops":""}}}\n' \
    "$DBFILE" > "$CONFIG_PATH"
}

# Insert a security_audit_log row aged `days` days ago.
seed_audit(){
  local days="$1"
  sq "INSERT INTO security_audit_log
      (audit_type, auditor, scope, created_at, bootstrap_baseline)
      VALUES ('bootstrap_baseline','cso','company',datetime('now','-${days} days'),1);"
}

# Insert an agent_actions_log row aged `days` days ago.
seed_action(){
  local days="$1"
  sq "INSERT INTO agent_actions_log (agent,tool_name,args_hash,status,started_at)
      VALUES ('cos','Bash','cso${days}','success',datetime('now','-${days} days'));"
}

run(){
  ( PATH="$FAKEBIN:$PATH" \
    JUVANT_CONFIG="$CONFIG_PATH" \
    JUVANT_TEST_DB_FILE="$DBFILE" \
    CONTINUITY_WARN_DAYS="${CONTINUITY_WARN_DAYS:-14}" \
    CONTINUITY_FAIL_DAYS="${CONTINUITY_FAIL_DAYS:-30}" \
    bash "$TMP/helpers/cso-weekly-audit.sh" ) 2>&1; echo "EXIT:$?"
}

# ── (i) Fresh audit + fresh actions → exit 0 silently ───────────────────────
echo "=== (i) fresh audit + fresh actions → exit 0 ==="
fresh_db; write_cfg
seed_audit 1      # audit 1d ago (< 14d WARN)
seed_action 1     # action 1d ago
out=$(CONTINUITY_WARN_DAYS=14 run)
has "(i) exit 0 reported"   "$out" "EXIT:0"
not_has "(i) no ALERT line" "$out" "ALERT:"

# ── (ii) Stale audit, fresh actions → escalation + exit 1 ───────────────────
echo "=== (ii) stale audit, fresh actions → exit 1 ==="
fresh_db; write_cfg
seed_audit 20     # audit 20d ago (> 14d WARN)
seed_action 1     # action fresh
out=$(CONTINUITY_WARN_DAYS=14 run)
has "(ii) exit 1 reported"      "$out" "EXIT:1"
has "(ii) ALERT line present"   "$out" "ALERT:"
has "(ii) escalation row msg shows actions gap" "$out" "actions="

# Check that the messages escalation row was written.
msg_count=$(sq "SELECT COUNT(*) FROM messages WHERE from_agent='cso-weekly-audit' AND to_agent='cos';")
if [[ "${msg_count:-0}" -ge 1 ]]; then ok "(ii) messages escalation row written"
else no "(ii) messages escalation row missing (count=${msg_count})"; fi

# Check updated message body includes both indicators.
msg_content=$(sq "SELECT content FROM messages WHERE from_agent='cso-weekly-audit' ORDER BY id DESC LIMIT 1;")
has "(ii) message body includes audit gap"   "$msg_content" "last audit"
has "(ii) message body includes action gap"  "$msg_content" "action_log"
has "(ii) message body mentions halt_windows" "$msg_content" "halt_windows"

# ── (iii) Fresh audit, stale actions → escalation + exit 1 ─────────────────
echo "=== (iii) fresh audit, stale actions → exit 1 ==="
fresh_db; write_cfg
seed_audit 1      # audit fresh
seed_action 20    # action 20d ago (> 14d WARN)
out=$(CONTINUITY_WARN_DAYS=14 run)
has "(iii) exit 1 (stale actions detected)" "$out" "EXIT:1"
has "(iii) ALERT line present"              "$out" "ALERT:"

# ── (iv) Both stale → escalation + exit 1 ────────────────────────────────────
echo "=== (iv) both stale → exit 1 ==="
fresh_db; write_cfg
seed_audit 20     # audit 20d ago
seed_action 20    # action 20d ago
out=$(CONTINUITY_WARN_DAYS=14 run)
has "(iv) exit 1 (both stale)"   "$out" "EXIT:1"
has "(iv) ALERT line present"    "$out" "ALERT:"

# ── (v) Both within threshold → exit 0 ──────────────────────────────────────
# This covers the case where CONTINUITY_WARN_DAYS is wide enough that both
# staleness values fall below it — the helper exits 0 without escalating.
# Simulates a scenario where the threshold is set to 30d and both are 20d.
echo "=== (v) both within 30d threshold → exit 0 ==="
fresh_db; write_cfg
seed_audit 20     # audit 20d ago
seed_action 20    # action 20d ago
out=$(CONTINUITY_WARN_DAYS=30 run)
has "(v) exit 0 with wide threshold" "$out" "EXIT:0"
not_has "(v) no ALERT with wide threshold" "$out" "ALERT:"

echo "───────────────────────────────────"
echo "  cso-weekly-audit-cadence: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
