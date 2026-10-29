#!/usr/bin/env bash
# tests/schema/test-audit-immutability.sh
#
# R5b + R5c (decisions#303 / #304 / #308; security_audit_log#155/#161/#163):
# DB-level audit immutability for security_audit_log / agent_actions_log /
# decisions, and the INSERT-only audit_events companion table.
#
# Every behaviour check runs against THREE databases, because the triggers must
# hold on every DB an adopter can have:
#   fresh    — built from scripts/schema.sql (new instance)
#   migrated — built from the PRE-R5 schema (schema.sql truncated before the
#              AUDIT IMMUTABILITY section), seeded with legacy rows, then
#              upgraded with `scripts/migrate.sh` (local provider), twice
#              (idempotency)
#   legacy   — a minimal old-shape DB whose audit tables lack later columns,
#              upgraded with `migrate.sh --project=<slug>` (proves the ADD COLUMN
#              guards: a trigger naming a missing column would brick every
#              UPDATE on the table)
# Plus: the migrated DB's R5 triggers/views are byte-identical (whitespace-
# normalized) to the fresh DB's.

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
SCHEMA="$REPO/scripts/schema.sql"

DB=""
sq(){ sqlite3 "$DB" "$@"; }
# aborts <name> <sql> <expected-message-substring>
aborts(){
  local out rc
  out=$(sqlite3 "$DB" "$2" 2>&1); rc=$?
  if [[ "$rc" -ne 0 && "$out" == *"$3"* ]]; then ok "$1"
  else no "$1 (rc=$rc out=${out:0:160})"; fi
}
# succeeds <name> <sql>
succeeds(){
  local out rc
  out=$(sqlite3 "$DB" "$2" 2>&1); rc=$?
  if [[ "$rc" -eq 0 ]]; then ok "$1"; else no "$1 (rc=$rc out=${out:0:160})"; fi
}
# ins <sql> — run an INSERT and print the new rowid
ins(){ sqlite3 "$DB" "$1; SELECT last_insert_rowid();"; }

R5_DEL='is forbidden'
R5_IMM='immutable'
R5_CLOCK='must be the DB clock'
R5_AUTH='requires authority_ref'

# ─────────────────────────────────────────────
# The behaviour suite (one DB)
# ─────────────────────────────────────────────
run_suite(){
  DB="$1"; echo; echo "=== [$2] ==="

  # Seed.
  local CSO COS CSO_NORAT SAL SAL2 AAL_P AAL_F AAL_NULLSUM DEC APPR EV
  CSO=$(ins "INSERT INTO decisions (agent,title,category,rationale,status) VALUES ('cso','CSO ruling','security-remediation','finding re-triaged after evidence review','proposed')")
  COS=$(ins "INSERT INTO decisions (agent,title,category,rationale,status) VALUES ('cos','CoS relay','arch-decision','relaying a message','proposed')")
  CSO_NORAT=$(ins "INSERT INTO decisions (agent,title,category,status) VALUES ('cso','CSO no rationale','security-remediation','proposed')")
  SAL=$(ins "INSERT INTO security_audit_log (auditor,session_id,scope,audit_type,layer,finding,severity,category,status) VALUES ('cso','sess-A','company','5-layer','agents','finding one','P1','drift','open')")
  SAL2=$(ins "INSERT INTO security_audit_log (auditor,scope,audit_type,layer,finding,severity,category,status) VALUES ('cso','company','incident','agents','incident two','P2','drift','open')")
  AAL_P=$(ins "INSERT INTO agent_actions_log (session_id,agent,tool_name,args_hash,status,input_summary) VALUES ('s1','cos','Bash','h1','pending','git status')")
  AAL_F=$(ins "INSERT INTO agent_actions_log (session_id,agent,tool_name,args_hash,status,deny_reason,input_summary) VALUES ('s1','cos','Bash','h2','denied','deny-list','rm -rf /')")
  AAL_NULLSUM=$(ins "INSERT INTO agent_actions_log (session_id,agent,tool_name,args_hash,status) VALUES ('s1','cos','Bash','h3','failure')")
  DEC=$(ins "INSERT INTO decisions (agent,title,category,rationale,status,created_at) VALUES ('eng-lead','Spec','pr-spec','diff','proposed',CURRENT_TIMESTAMP)")

  echo "  -- DELETE / REPLACE"
  aborts "DELETE security_audit_log aborted" "DELETE FROM security_audit_log WHERE id=$SAL;" "$R5_DEL"
  aborts "DELETE agent_actions_log aborted" "DELETE FROM agent_actions_log WHERE id=$AAL_F;" "$R5_DEL"
  aborts "DELETE decisions aborted" "DELETE FROM decisions WHERE id=$DEC;" "$R5_DEL"
  aborts "bulk DELETE decisions aborted" "DELETE FROM decisions;" "$R5_DEL"
  aborts "INSERT OR REPLACE onto existing security_audit_log id aborted" \
    "INSERT OR REPLACE INTO security_audit_log (id,auditor,scope,audit_type,severity) VALUES ($SAL,'cso','company','incident','info');" "never replaced"
  aborts "INSERT OR REPLACE onto existing decisions id aborted" \
    "INSERT OR REPLACE INTO decisions (id,agent,title) VALUES ($DEC,'x','y');" "never replaced"
  aborts "INSERT OR REPLACE onto existing agent_actions_log id aborted" \
    "INSERT OR REPLACE INTO agent_actions_log (id,agent,tool_name,args_hash,status) VALUES ($AAL_F,'x','y','z','success');" "never replaced"
  eq "rows survived the attempts" "P1|1|1" \
    "$(sq "SELECT (SELECT severity FROM security_audit_log WHERE id=$SAL)||'|'||(SELECT count(*) FROM decisions WHERE id=$DEC)||'|'||(SELECT count(*) FROM agent_actions_log WHERE id=$AAL_F);")"

  echo "  -- evidentiary UPDATEs"
  local c
  for c in "finding='x'" "severity='info'" "created_at=datetime('now','-3 days')" "auditor='cos'" \
           "layer='code'" "category='test'" "scope='p1'" "audit_type='monthly'" "session_id='forged'" \
           "bootstrap_baseline=1" "id=id+1000"; do
    aborts "security_audit_log SET $c aborted" "UPDATE security_audit_log SET $c WHERE id=$SAL;" "$R5_IMM"
  done
  aborts "silent severity downgrade (no WHERE) aborted" "UPDATE security_audit_log SET severity='info';" "$R5_IMM"
  for c in "agent='cfo'" "tool_name='Read'" "args_hash='zz'" "started_at=datetime('now','-1 days')" \
           "input_summary='rewritten'" "session_id='s9'" "spec_id=7"; do
    aborts "agent_actions_log SET $c aborted" "UPDATE agent_actions_log SET $c WHERE id=$AAL_P;" "$R5_IMM"
  done
  for c in "title='x'" "rationale='rewritten'" "created_at=datetime('now','-2 days')" "agent='ceo'" "category='legal'"; do
    aborts "decisions SET $c aborted" "UPDATE decisions SET $c WHERE id=$DEC;" "$R5_IMM"
  done
  aborts "decisions rationale append (backfill pattern) aborted" \
    "UPDATE decisions SET rationale=coalesce(rationale,'')||' [note]' WHERE id=$DEC;" "$R5_IMM"

  echo "  -- legitimate lifecycle UPDATEs (current writers)"
  succeeds "JUVANT_OS CEO approval (status+approved_by+approved_at NULL→value)" \
    "UPDATE decisions SET status='approved', approved_by='ceo', approved_at=CURRENT_TIMESTAMP WHERE id=$DEC;"
  succeeds "JUVANT_OS/eng-lead execution (status/executed_by/executed_at/source_ref)" \
    "UPDATE decisions SET status='executed', executed_by='eng-lead', executed_at=CURRENT_TIMESTAMP, source_ref='o/r#1' WHERE id=$DEC;"
  succeeds "JUVANT_OS source_ref recorded separately" "UPDATE decisions SET source_ref='o/r#2' WHERE id=$DEC;"
  succeeds "JUVANT_OS upstream_candidate=1" "UPDATE decisions SET upstream_candidate=1 WHERE id=$DEC;"
  succeeds "held_for_fallback flag" "UPDATE decisions SET held_for_fallback=1 WHERE id=$DEC;"
  succeeds "no-op re-SET of an immutable column (same value)" "UPDATE decisions SET title=title, rationale=rationale WHERE id=$DEC;"
  APPR=$(ins "INSERT INTO decisions (agent,title,category,rationale,status) VALUES ('eng-lead','Spec2','pr-spec','d','proposed')")
  succeeds "upstream-sync approval (approved_by='ceo')" \
    "UPDATE decisions SET status='approved', approved_by='ceo', approved_at=CURRENT_TIMESTAMP WHERE id=$APPR;"
  succeeds "audit-reconcile auto-close (WHERE status='approved')" \
    "UPDATE decisions SET status='executed', executed_by='audit-reconcile', executed_at=CURRENT_TIMESTAMP, source_ref='o/r#3' WHERE id=$APPR AND status='approved' AND category='pr-spec';"
  succeeds "governance-backfill 0b mark executed" \
    "UPDATE decisions SET status='executed', executed_by='governance-backfill', executed_at=CURRENT_TIMESTAMP WHERE id=$APPR;"
  succeeds "CEO decline (status='rejected')" "UPDATE decisions SET status='rejected' WHERE id=$COS;"
  aborts "approved_by value→other aborted" "UPDATE decisions SET approved_by='cos' WHERE id=$DEC;" "$R5_IMM"
  aborts "approved_at value→other aborted" "UPDATE decisions SET approved_at=datetime('now','+1 days') WHERE id=$DEC;" "$R5_IMM"
  aborts "approved_by value→NULL aborted" "UPDATE decisions SET approved_by=NULL WHERE id=$DEC;" "$R5_IMM"
  succeeds "post-tool-use success finalize (pending→success)" \
    "UPDATE agent_actions_log SET status='success', result_hash='r', ended_at=CURRENT_TIMESTAMP WHERE id=(SELECT id FROM agent_actions_log WHERE session_id='s1' AND agent='cos' AND tool_name='Bash' AND status='pending' AND args_hash='h1' ORDER BY started_at DESC LIMIT 1);"
  eq "pending row finalized" "success" "$(sq "SELECT status FROM agent_actions_log WHERE id=$AAL_P;")"
  local P2 P3
  P2=$(ins "INSERT INTO agent_actions_log (session_id,agent,tool_name,args_hash,status,input_summary) VALUES ('s2','cfo','Bash','h9','pending','terraform apply')")
  succeeds "post-tool-use-failure finalize (pending→failure)" \
    "UPDATE agent_actions_log SET status='failure', ended_at=CURRENT_TIMESTAMP WHERE id=(SELECT id FROM agent_actions_log WHERE session_id='s2' AND agent='cfo' AND tool_name='Bash' AND args_hash='h9' AND status='pending' ORDER BY started_at DESC LIMIT 1);"
  P3=$(ins "INSERT INTO agent_actions_log (session_id,agent,tool_name,args_hash,status,started_at) VALUES ('s3','cos','SendMessage','h8','pending',datetime('now','-2 hours'))")
  succeeds "drainer reconcile (pending >1h → terminated)" \
    "UPDATE agent_actions_log SET status='terminated', ended_at=CURRENT_TIMESTAMP WHERE status='pending' AND started_at < datetime('now','-1 hour');"
  eq "orphan terminated" "terminated" "$(sq "SELECT status FROM agent_actions_log WHERE id=$P3;")"
  succeeds "late PostToolUse against a terminated row is a no-op" \
    "UPDATE agent_actions_log SET status='success', result_hash='r', ended_at=CURRENT_TIMESTAMP WHERE id=(SELECT id FROM agent_actions_log WHERE session_id='s3' AND status='pending' ORDER BY started_at DESC LIMIT 1);"
  succeeds "governance-backfill 0d input_summary NULL→stamp on a final row" \
    "UPDATE agent_actions_log SET input_summary='[REDACTED — pre-FEAT-040 audit gap]' WHERE status IN ('denied','failure') AND (input_summary IS NULL OR trim(input_summary)='');"
  eq "stamp landed" "[REDACTED — pre-FEAT-040 audit gap]" "$(sq "SELECT input_summary FROM agent_actions_log WHERE id=$AAL_NULLSUM;")"
  aborts "final row: status rewrite aborted (denied→success)" "UPDATE agent_actions_log SET status='success' WHERE id=$AAL_F;" "row is final"
  aborts "final row: ended_at rewrite aborted" "UPDATE agent_actions_log SET ended_at=datetime('now','-5 days') WHERE id=$P2;" "row is final"
  aborts "final row: deny_reason rewrite aborted" "UPDATE agent_actions_log SET deny_reason='do not chase' WHERE id=$AAL_F;" "row is final"
  succeeds "security_audit_log status→in-progress (compat lifecycle)" "UPDATE security_audit_log SET status='in-progress' WHERE id=$SAL2;"
  succeeds "security_audit_log status/resolved_at (compat lifecycle, deprecated)" \
    "UPDATE security_audit_log SET status='resolved', resolved_at=CURRENT_TIMESTAMP WHERE id=$SAL2;"

  echo "  -- created_at is the DB clock"
  aborts "decisions backdated created_at (-1 day) aborted" \
    "INSERT INTO decisions (agent,title,created_at) VALUES ('cos','t',datetime('now','-1 days'));" "$R5_CLOCK"
  aborts "decisions future created_at (+10 min) aborted" \
    "INSERT INTO decisions (agent,title,created_at) VALUES ('cos','t',datetime('now','+10 minutes'));" "$R5_CLOCK"
  aborts "decisions literal historical created_at aborted" \
    "INSERT INTO decisions (agent,title,created_at) VALUES ('cos','t','2026-07-04 09:00:00');" "$R5_CLOCK"
  aborts "decisions explicit NULL created_at aborted" \
    "INSERT INTO decisions (agent,title,created_at) VALUES ('cos','t',NULL);" "$R5_CLOCK"
  aborts "decisions unparseable created_at aborted" \
    "INSERT INTO decisions (agent,title,created_at) VALUES ('cos','t','yesterday');" "$R5_CLOCK"
  succeeds "decisions created_at omitted (default) ok" "INSERT INTO decisions (agent,title) VALUES ('cos','t');"
  succeeds "decisions created_at=CURRENT_TIMESTAMP ok" "INSERT INTO decisions (agent,title,created_at) VALUES ('cos','t',CURRENT_TIMESTAMP);"
  succeeds "decisions created_at within tolerance (-60s, client clock) ok" \
    "INSERT INTO decisions (agent,title,created_at) VALUES ('cos','t',datetime('now','-60 seconds'));"
  succeeds "decisions created_at ISO-8601 Z form (client date -u) ok" \
    "INSERT INTO decisions (agent,title,created_at) VALUES ('cos','t',strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
  aborts "security_audit_log backdated created_at aborted" \
    "INSERT INTO security_audit_log (auditor,scope,audit_type,severity,created_at) VALUES ('cso','company','incident','P2',datetime('now','-3 hours'));" "$R5_CLOCK"
  succeeds "security_audit_log JUVANT_OS Tier-1 insert (created_at=CURRENT_TIMESTAMP) ok" \
    "INSERT INTO security_audit_log (auditor, scope, audit_type, finding, severity, category, status, created_at) VALUES ('cso', 'company', 'incident', 'x', 'P1', 'disclosure-unavailable', 'open', CURRENT_TIMESTAMP);"
  succeeds "security_audit_log hook-shaped insert (pre-tool-use Track 2e/2g, no created_at) ok" \
    "INSERT INTO security_audit_log (auditor, scope, audit_type, layer, finding, severity, category, status) VALUES ('hook:pre-tool-use', 'company', 'incident', 'agents', 'mailbox op', 'info', 'access-event', 'open');"
  succeeds "agent_actions_log started_at = hook action time is exempt (decisions#298)" \
    "INSERT INTO agent_actions_log (session_id,agent,tool_name,args_hash,status,input_summary,started_at) VALUES ('s4','cos','Bash','h7','pending','x',datetime('now','-3 hours'));"

  echo "  -- audit_events: INSERT-only"
  EV=$(ins "INSERT INTO audit_events (target_table,target_id,event_type,reason,author) VALUES ('security_audit_log',$SAL,'note','context from CEthO review','cetho')")
  if [[ "$EV" =~ ^[0-9]+$ ]]; then ok "note on another author's row needs no authority"
  else no "note insert failed ($EV)"; fi
  aborts "audit_events UPDATE aborted" "UPDATE audit_events SET reason='edited' WHERE id=$EV;" "INSERT-only"
  aborts "audit_events DELETE aborted" "DELETE FROM audit_events WHERE id=$EV;" "INSERT-only"
  aborts "audit_events INSERT OR REPLACE onto existing id aborted" \
    "INSERT OR REPLACE INTO audit_events (id,target_table,target_id,event_type,reason,author) VALUES ($EV,'decisions',$DEC,'note','x','cos');" "never replaced"
  aborts "audit_events backdated created_at aborted" \
    "INSERT INTO audit_events (target_table,target_id,event_type,reason,author,created_at) VALUES ('decisions',$DEC,'note','x','cos',datetime('now','-1 days'));" "$R5_CLOCK"
  aborts "audit_events unknown event_type rejected (CHECK)" \
    "INSERT INTO audit_events (target_table,target_id,event_type,reason,author) VALUES ('decisions',$DEC,'rewrite','x','cos');" "CHECK constraint failed"
  aborts "audit_events unknown target_table rejected (CHECK)" \
    "INSERT INTO audit_events (target_table,target_id,event_type,reason,author) VALUES ('messages',1,'note','x','cos');" "CHECK constraint failed"
  aborts "audit_events empty reason rejected" \
    "INSERT INTO audit_events (target_table,target_id,event_type,reason,author) VALUES ('decisions',$DEC,'note','  ','cos');" "CHECK constraint failed"
  aborts "audit_events target row must exist" \
    "INSERT INTO audit_events (target_table,target_id,event_type,reason,author) VALUES ('decisions',999999,'note','x','cos');" "existing row of target_table"
  aborts "audit_events authority_ref must exist" \
    "INSERT INTO audit_events (target_table,target_id,event_type,reason,authority_ref,author) VALUES ('decisions',$DEC,'note','x',999999,'cos');" "existing decisions row"

  echo "  -- corrections need a CSO-authored decisions row (decisions#308)"
  local sev="INSERT INTO audit_events (target_table,target_id,event_type,from_value,to_value,reason,authority_ref,author) VALUES ('security_audit_log',$SAL,'severity_change','P1','P2','re-triage'"
  aborts "severity_change without authority_ref aborted" "$sev,NULL,'cso');" "$R5_AUTH"
  aborts "severity_change with a CoS decisions row aborted" "$sev,$COS,'cos');" "$R5_AUTH"
  aborts "severity_change with a CSO row lacking rationale aborted" "$sev,$CSO_NORAT,'cso');" "$R5_AUTH"
  aborts "severity_change with wrong from_value aborted" \
    "INSERT INTO audit_events (target_table,target_id,event_type,from_value,to_value,reason,authority_ref,author) VALUES ('security_audit_log',$SAL,'severity_change','P0','P2','x',$CSO,'cso');" "from_value must equal"
  aborts "severity_change on a decisions row aborted" \
    "INSERT INTO audit_events (target_table,target_id,event_type,from_value,to_value,reason,authority_ref,author) VALUES ('decisions',$DEC,'severity_change',NULL,'P2','x',$CSO,'cso');" "security_audit_log only"
  succeeds "severity_change (downgrade P1→P2) with a CSO decisions row ok" "$sev,$CSO,'cso');"
  eq "view: current_severity = latest severity_change; base column unchanged" "P2|P1" \
    "$(sq "SELECT current_severity||'|'||severity FROM security_audit_log_current WHERE id=$SAL;")"
  aborts "chained severity_change must start from the CURRENT severity" \
    "INSERT INTO audit_events (target_table,target_id,event_type,from_value,to_value,reason,authority_ref,author) VALUES ('security_audit_log',$SAL,'severity_change','P1','P0','x',$CSO,'cso');" "from_value must equal"
  succeeds "chained severity_change P2→P1 ok" \
    "INSERT INTO audit_events (target_table,target_id,event_type,from_value,to_value,reason,authority_ref,author) VALUES ('security_audit_log',$SAL,'severity_change','P2','P1','x',$CSO,'cso');"
  eq "view reflects the latest event" "P1" "$(sq "SELECT current_severity FROM security_audit_log_current WHERE id=$SAL;")"
  aborts "severity_change without to_value aborted" \
    "INSERT INTO audit_events (target_table,target_id,event_type,from_value,reason,authority_ref,author) VALUES ('security_audit_log',$SAL,'severity_change','P1','x',$CSO,'cso');" "require to_value"

  local clo="INSERT INTO audit_events (target_table,target_id,event_type,from_value,to_value,reason,authority_ref,author) VALUES ('security_audit_log',$SAL,'closure','open','resolved','follow-up audit verified'"
  aborts "closure without authority_ref aborted" "$clo,NULL,'cos');" "$R5_AUTH"
  aborts "closure with a CoS decisions row aborted" "$clo,$COS,'cos');" "$R5_AUTH"
  aborts "status_change to a terminal status without CSO authority aborted (no closure bypass)" \
    "INSERT INTO audit_events (target_table,target_id,event_type,from_value,to_value,reason,author) VALUES ('security_audit_log',$SAL,'status_change','open','resolved','x','cos');" "$R5_AUTH"
  succeeds "status_change to in-progress needs no authority" \
    "INSERT INTO audit_events (target_table,target_id,event_type,from_value,to_value,reason,author) VALUES ('security_audit_log',$SAL,'status_change','open','in-progress','triaged','cso');"
  eq "view: current_status follows status_change" "in-progress" "$(sq "SELECT current_status FROM security_audit_log_current WHERE id=$SAL;")"
  succeeds "closure with a CSO decisions row ok" "$clo,$CSO,'cso');"
  eq "view: closure → current_status + current_resolved_at; base status untouched" "resolved|1|open" \
    "$(sq "SELECT current_status||'|'||(current_resolved_at IS NOT NULL)||'|'||status FROM security_audit_log_current WHERE id=$SAL;")"

  aborts "timestamp_correction without authority aborted" \
    "INSERT INTO audit_events (target_table,target_id,event_type,from_value,to_value,reason,author) VALUES ('decisions',$DEC,'timestamp_correction',NULL,'2026-07-01 10:00:00','x','cos');" "$R5_AUTH"
  aborts "timestamp_correction with unparseable to_value aborted" \
    "INSERT INTO audit_events (target_table,target_id,event_type,to_value,reason,authority_ref,author) VALUES ('decisions',$DEC,'timestamp_correction','last tuesday','x',$CSO,'cso');" "parseable datetime"
  succeeds "timestamp_correction with CSO authority ok" \
    "INSERT INTO audit_events (target_table,target_id,event_type,to_value,reason,authority_ref,author) VALUES ('decisions',$DEC,'timestamp_correction','2026-07-01 10:00:00','spool drain delay',$CSO,'cso');"
  eq "decisions_current: current_created_at corrected, base created_at untouched" "2026-07-01 10:00:00|1" \
    "$(sq "SELECT current_created_at||'|'||(created_at <> current_created_at) FROM decisions_current WHERE id=$DEC;")"

  aborts "test_artifact without authority aborted" \
    "INSERT INTO audit_events (target_table,target_id,event_type,reason,author) VALUES ('security_audit_log',$SAL2,'test_artifact','canary row','cos');" "$R5_AUTH"
  succeeds "test_artifact with CSO authority ok (test rows are marked, never deleted)" \
    "INSERT INTO audit_events (target_table,target_id,event_type,reason,authority_ref,author) VALUES ('security_audit_log',$SAL2,'test_artifact','canary row',$CSO,'cso');"
  eq "view: is_test_artifact" "1" "$(sq "SELECT is_test_artifact FROM security_audit_log_current WHERE id=$SAL2;")"
  succeeds "decisions status_change (supersession record) needs no CSO authority" \
    "INSERT INTO audit_events (target_table,target_id,event_type,from_value,to_value,reason,author) VALUES ('decisions',$COS,'status_change','rejected','superseded','superseded by decisions#$DEC','cos');"
  eq "decisions_current: current_status follows status_change" "superseded|rejected" \
    "$(sq "SELECT current_status||'|'||status FROM decisions_current WHERE id=$COS;")"
  succeeds "agent_actions_log note ok" \
    "INSERT INTO audit_events (target_table,target_id,event_type,reason,author) VALUES ('agent_actions_log',$AAL_F,'note','expected deny during canary','cso');"

  echo "  -- verdict-severity rule (decisions#308)"
  sq "INSERT INTO security_audit_log (auditor,session_id,scope,audit_type,layer,finding,severity,category) VALUES ('cso','sess-V','company','5-layer','access','f-a','P2','drift'),('cso','sess-V','company','5-layer','agents','f-b','high','drift');"
  aborts "verdict below the highest finding aborted" \
    "INSERT INTO security_audit_log (auditor,session_id,scope,audit_type,finding,severity,category) VALUES ('cso','sess-V','company','5-layer','WARN','P2','audit-verdict');" "highest finding"
  succeeds "verdict at the highest finding severity ok (high ≡ P1)" \
    "INSERT INTO security_audit_log (auditor,session_id,scope,audit_type,finding,severity,category) VALUES ('cso','sess-V','company','5-layer','WARN-WITH-CONDITIONS','P1','audit-verdict');"
  eq "violations view empty" "0" "$(sq "SELECT count(*) FROM security_audit_verdict_severity_violations WHERE session_id='sess-V';")"
  local FB
  FB=$(sq "SELECT id FROM security_audit_log WHERE session_id='sess-V' AND finding='f-b';")
  succeeds "CSO upgrades a finding after the verdict (severity_change)" \
    "INSERT INTO audit_events (target_table,target_id,event_type,from_value,to_value,reason,authority_ref,author) VALUES ('security_audit_log',$FB,'severity_change','high','critical','escalated',$CSO,'cso');"
  eq "violations view flags the now-understated verdict" "1" \
    "$(sq "SELECT count(*) FROM security_audit_verdict_severity_violations WHERE session_id='sess-V' AND finding_id=$FB;")"
  sq "INSERT INTO security_audit_log (auditor,scope,audit_type,finding,severity,category) VALUES ('cso','company','5-layer','PASS','info','audit-verdict');"
  eq "violations view flags a verdict without session_id (unlinkable)" "1" \
    "$(sq "SELECT count(*) FROM security_audit_verdict_severity_violations WHERE violation LIKE 'verdict without session_id%';")"

  echo "  -- pre-existing triggers still enforced"
  aborts "decisions category allowlist still rejects a bad category" \
    "INSERT INTO decisions (agent,title,category) VALUES ('cos','t','bogus-category');" "not in canonical list"
  aborts "approved requires approver (FEAT-040 1b) still enforced" \
    "INSERT INTO decisions (agent,title,category,status) VALUES ('cos','t','arch-decision','approved');" "requires approved_by"
  aborts "denied row requires input_summary (FEAT-040 1d) still enforced" \
    "INSERT INTO agent_actions_log (agent,tool_name,args_hash,status) VALUES ('cos','Bash','h','denied');" "require input_summary"
  sq "INSERT OR IGNORE INTO master_context (key,value) VALUES ('company_type','sub');"
  aborts "scope=global master-only still enforced (sub company)" \
    "UPDATE decisions SET scope='global' WHERE id=$DEC;" "company_type=master"
}

# ─────────────────────────────────────────────
# 1. fresh DB
# ─────────────────────────────────────────────
FRESH="$TMP/fresh.db"
sqlite3 "$FRESH" < "$SCHEMA"
run_suite "$FRESH" "fresh schema.sql"

# ─────────────────────────────────────────────
# 2. migrated from the pre-R5 schema
# ─────────────────────────────────────────────
echo; echo "=== [migrate.sh upgrade path] ==="
STAGE="$TMP/stage"; mkdir -p "$STAGE/scripts" "$STAGE/.juvant"
cp "$REPO/scripts/migrate.sh" "$SCHEMA" "$STAGE/scripts/"
MIG="$STAGE/.juvant/state.db"
# Pre-R5 schema = schema.sql truncated before the AUDIT IMMUTABILITY section.
awk '/^-- AUDIT IMMUTABILITY \(R5b\)/{exit} {print}' "$SCHEMA" > "$TMP/schema-pre-r5.sql"
sqlite3 "$MIG" < "$TMP/schema-pre-r5.sql"
eq "pre-R5 DB has no audit_events table" "0" \
  "$(sqlite3 "$MIG" "SELECT count(*) FROM sqlite_master WHERE name='audit_events';")"
# Legacy rows written before the upgrade (backdating + deletes still possible then).
sqlite3 "$MIG" "INSERT INTO decisions (agent,title,created_at) VALUES ('cos','legacy',datetime('now','-90 days'));
                INSERT INTO security_audit_log (auditor,scope,audit_type,severity,created_at) VALUES ('cso','company','incident','P1',datetime('now','-30 days'));
                INSERT INTO security_audit_log (auditor,scope,audit_type,severity) VALUES ('cso','company','incident','P2');
                DELETE FROM security_audit_log WHERE severity='P2';"
jq -n --arg u "file:$MIG" '{db:{provider:"local",url:$u}}' > "$STAGE/.juvant/config.json"
out=$(bash "$STAGE/scripts/migrate.sh" 2>&1); rc=$?
eq "migrate.sh exits 0" "0" "$rc"
case "$out" in *"WARN [migrate]"*) no "migrate.sh emitted patch warnings: $(printf '%s' "$out" | grep WARN | head -3)";; *) ok "migrate.sh: no patch warnings";; esac
out=$(bash "$STAGE/scripts/migrate.sh" 2>&1); rc=$?
eq "migrate.sh re-run (idempotent) exits 0" "0" "$rc"
case "$out" in *"WARN [migrate]"*) no "re-run emitted patch warnings";; *) ok "migrate.sh re-run: no patch warnings";; esac
DB="$MIG"
aborts "legacy row is now protected (DELETE aborted)" "DELETE FROM decisions WHERE title='legacy';" "$R5_DEL"
eq "legacy backdated rows preserved as written" "2" \
  "$(sqlite3 "$MIG" "SELECT (SELECT count(*) FROM decisions WHERE title='legacy' AND created_at < datetime('now','-80 days')) + (SELECT count(*) FROM security_audit_log WHERE created_at < datetime('now','-20 days'));")"

# Migrated R5 objects must equal the fresh DB's (whitespace-normalized).
R5_WHERE="type IN ('trigger','view','table','index')
  AND (name IN ('audit_events','idx_audit_events_target','agent_actions_log_final_row_frozen',
                'security_audit_log_verdict_severity','security_audit_verdict_severity_violations')
       OR name LIKE '%\_no\_delete' ESCAPE '\' OR name LIKE '%\_no\_replace' ESCAPE '\'
       OR name LIKE '%immutable\_fields' ESCAPE '\' OR name LIKE '%db\_clock' ESCAPE '\'
       OR name LIKE 'audit\_events\_%' ESCAPE '\' OR name LIKE '%\_current' ESCAPE '\')"
r5_ddl(){
  sqlite3 "$1" "SELECT name||' '||sql FROM sqlite_master WHERE $R5_WHERE ORDER BY name;" \
    | sed -e 's/--.*$//' | tr -s '[:space:]' ' ' | sed -e 's/ *\([(),;=<>]\) */\1/g'
}
_f=$(r5_ddl "$FRESH"); _m=$(r5_ddl "$MIG")
if [[ -n "$_f" && "$_f" == "$_m" ]]; then ok "migrated R5 DDL identical to fresh schema.sql DDL"
else no "migrated R5 DDL differs from fresh"; fi
eq "R5 object count in migrated DB (23 triggers/views + table + index)" "25" \
  "$(sqlite3 "$MIG" "SELECT count(*) FROM sqlite_master WHERE $R5_WHERE;")"
run_suite "$MIG" "migrated pre-R5 → migrate.sh"

# ─────────────────────────────────────────────
# 3. legacy old-shape project DB (missing later columns) → migrate --project
# ─────────────────────────────────────────────
echo; echo "=== [old-shape project DB → migrate.sh --project] ==="
LEG="$STAGE/.juvant/project-p1.db"
sqlite3 "$LEG" "CREATE TABLE security_audit_log (id INTEGER PRIMARY KEY AUTOINCREMENT, auditor TEXT NOT NULL, scope TEXT NOT NULL, audit_type TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
                CREATE TABLE agent_actions_log (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, agent TEXT NOT NULL, tool_name TEXT NOT NULL, args_hash TEXT NOT NULL, status TEXT NOT NULL, started_at DATETIME DEFAULT CURRENT_TIMESTAMP);
                CREATE TABLE decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT NOT NULL, title TEXT NOT NULL, status TEXT DEFAULT 'proposed', created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
                INSERT INTO security_audit_log (auditor,scope,audit_type) VALUES ('cso','p1','incident');
                INSERT INTO agent_actions_log (agent,tool_name,args_hash,status) VALUES ('cos','Bash','h','pending');
                INSERT INTO decisions (agent,title) VALUES ('cos','old');"
jq --arg u "file:$LEG" '.projects = {p1:{db:{provider:"local",url:$u}}}' "$STAGE/.juvant/config.json" > "$STAGE/.juvant/c.tmp" \
  && mv "$STAGE/.juvant/c.tmp" "$STAGE/.juvant/config.json"
out=$(bash "$STAGE/scripts/migrate.sh" --project=p1 2>&1); rc=$?
eq "migrate.sh --project exits 0" "0" "$rc"
DB="$LEG"
succeeds "old-shape security_audit_log: lifecycle UPDATE works (columns patched in, no 'no such column')" \
  "UPDATE security_audit_log SET status='in-progress' WHERE id=1;"
succeeds "old-shape agent_actions_log: pending→success works" \
  "UPDATE agent_actions_log SET status='success', ended_at=CURRENT_TIMESTAMP, result_hash='r' WHERE id=1;"
succeeds "old-shape decisions: approval works" \
  "UPDATE decisions SET status='approved', approved_by='ceo', approved_at=CURRENT_TIMESTAMP WHERE id=1;"
aborts "old-shape decisions: DELETE aborted" "DELETE FROM decisions WHERE id=1;" "$R5_DEL"
aborts "old-shape security_audit_log: evidentiary UPDATE aborted" "UPDATE security_audit_log SET auditor='x' WHERE id=1;" "$R5_IMM"

echo
echo "───────────────────────────────────"
echo "  audit-immutability: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
