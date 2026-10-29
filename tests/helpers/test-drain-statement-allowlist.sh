#!/usr/bin/env bash
# tests/helpers/test-drain-statement-allowlist.sh
#
# decisions#303 R3 (security_audit_log#154): helpers/drain-audit-spool.sh must
# execute ONLY the statement shapes the framework itself writes to the audit
# spool. The spool is agent-writable and every line used to run verbatim with the
# hook's DB credentials — an SQL injection channel.
#
#   1. Every legitimate shape, produced by RUNNING the real writers (hooks with a
#      failing write path for the sync juvant_db_exec callers, which spool on
#      transport failure), is applied — nothing quarantined.
#   2. A planted `INSERT INTO decisions (… approved_by='ceo')` in the live spool
#      is quarantined, a high 'spool-injection' security_audit_log row is written,
#      an alert is attempted, decisions is unchanged, the legit lines still apply.
#   3. The same planted line inside a stranded `.draining.<pid>` batch is
#      quarantined too (decisions#298 reclaim path).
#   4. A legit line with a stacked second statement is quarantined (whole line).
#   5. A value position holding a subquery / function call is quarantined.
#   6. audit-reconcile's `UPDATE decisions` is not an allowlisted spool shape.
#   7. The quarantine path follows JUVANT_SPOOL.
#   8. A quarantine write failure keeps the line in the spool, unexecuted.
#
# DB: provider=turso via a fake libsql-HTTP curl backed by a local SQLite file
# (plus fake turso / gh); notifications are recorded by the same curl stub.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

for dep in sqlite3 jq; do
  command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }
done

PASS=0; FAIL=0
ok()  { echo "    PASS: $1"; PASS=$(( PASS + 1 )); }
no()  { echo "    FAIL: $1"; FAIL=$(( FAIL + 1 )); }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing: $3)"; printf '%s\n' "$2" | head -20 | sed 's/^/        > /'; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then no "$1 (unexpected: $3)"; else ok "$1"; fi; }

TMP=$(mktemp -d)
FAKEBIN=$(mktemp -d)
trap 'wait 2>/dev/null; rm -rf "$TMP" "$FAKEBIN"' EXIT

unset TURSO_URL TURSO_TOKEN AGENT_ROLE JUVANT_DB_URL JUVANT_FRAMEWORK_DEV FAKE_CURL_MODE

DB="$TMP/state.db"
SCHEMA="$REPO/scripts/schema.sql"
mkdir -p "$TMP/.juvant" "$TMP/fixture/hooks/lib"
SPOOL="$TMP/.juvant/audit-spool.sql"
QUAR="$TMP/.juvant/audit-spool.quarantine"
CFG="$TMP/.juvant/config.json"
BACKUPS="$TMP/.juvant/backups"
ALERTS="$TMP/alerts.log"
TRANSCRIPT="$TMP/transcript.jsonl"

# session-start.sh launches helpers/drain-audit-spool.sh in the background from
# its own REPO_ROOT; run it from a fixture tree without helpers/ so no concurrent
# drain races this test.
cp "$REPO/hooks/session-start.sh" "$TMP/fixture/hooks/"
cp "$REPO/hooks/lib/db.sh" "$TMP/fixture/hooks/lib/"

cp "$REPO/tests/hooks/fake-turso.sh" "$FAKEBIN/turso"
cp "$REPO/tests/hooks/fake-libsql-curl.sh" "$FAKEBIN/libsql-curl"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/gh"            # gh "not authenticated"
# curl stub: /v2/pipeline → fake libsql server (writes fail with HTTP 500 when
# FAKE_WRITE_FAIL=1, reads keep working); anything else = a notification → log it.
cat > "$FAKEBIN/curl" <<'CURL'
#!/usr/bin/env bash
data=""; url=""; prev=""
for a in "$@"; do
  case "$prev" in --data|--data-raw|-d) data="$a" ;; esac
  [[ "$a" == http://* || "$a" == https://* ]] && url="$a"
  prev="$a"
done
if [[ "$url" != *"/v2/pipeline" ]]; then
  printf '%s\t%s\n' "$url" "$data" >> "${ALERT_LOG:-/dev/null}"
  exit 0
fi
if [[ "${FAKE_WRITE_FAIL:-0}" == "1" ]]; then
  sql=$(printf '%s' "$data" | jq -r '.requests[0].stmt.sql // ""' 2>/dev/null)
  if [[ ! "$sql" =~ ^[[:space:]]*SELECT ]]; then
    FAKE_CURL_MODE=500 exec bash "$(dirname "$0")/libsql-curl" "$@"
  fi
fi
exec bash "$(dirname "$0")/libsql-curl" "$@"
CURL
chmod +x "$FAKEBIN"/*

export PATH="$FAKEBIN:$PATH"
export JUVANT_TEST_DB_FILE="$DB" JUVANT_CONFIG="$CFG" JUVANT_SPOOL="$SPOOL" \
       JUVANT_BACKUP_DIR="$BACKUPS" ALERT_LOG="$ALERTS" JUVANT_DB_TIMEOUT=15

jq -n '{
  db: { provider: "turso", url: "libsql://test.fake" },
  notifications: { teams_webhooks: { approvals: "https://alerts.example.test/approvals" } },
  shared_mailboxes: { by_agent: { cfo: [ { upn: "finance@example.test", scope: "read" } ] } }
}' > "$CFG"

cat > "$TRANSCRIPT" <<'JSONL'
{"type":"assistant","message":{"model":"claude-test-1","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":2}}}
JSONL

sq() { sqlite3 "$DB" "$@"; }
fresh() {
  wait 2>/dev/null
  rm -rf "$DB" "$SPOOL" "$SPOOL".* "$QUAR" "$BACKUPS" "$ALERTS"
  sq < "$SCHEMA"
}
drain() { bash "$REPO/helpers/drain-audit-spool.sh" 2>&1; }
# The alert is fire-and-forget (backgrounded curl) — give it a moment to land.
alerts() {
  local _
  for _ in $(seq 1 50); do [[ -s "$ALERTS" ]] && break; sleep 0.1; done
  cat "$ALERTS" 2>/dev/null
}
injection_rows() { sq "SELECT COUNT(*) FROM security_audit_log WHERE category='spool-injection' AND severity='high' AND auditor='helper:drain-audit-spool';"; }

# A legit pre-tool-use.sh-shaped Track-3 row (exact column list + literal values).
legit() { # session n
  printf "INSERT INTO agent_actions_log (session_id, agent, tool_name, args_hash, status, deny_reason, input_summary, started_at) VALUES ('%s', 'cos', 'Bash', '%064x', 'pending', NULL, 'cmd %s', '2026-10-28 10:00:0%s');" "$1" "$2" "$2" "$2"
}
# No typed created_at: the R5b DB-clock trigger would reject that on its own,
# and the control below must prove the planted approval is otherwise effective.
PLANT="INSERT INTO decisions (agent, title, category, status, approved_by, approved_at) VALUES ('cos', 'planted approval', 'pr-spec', 'approved', 'ceo', '2026-10-28 10:00:00');"

DEADPID=$( (sleep 0 & echo $!) ); wait 2>/dev/null
while kill -0 "$DEADPID" 2>/dev/null; do DEADPID=$(( DEADPID + 7919 )); done

# ─────────────────────────────────────────────────────────────────────────────
echo "=== 1: every legitimate shape, written by the real writers, is applied ==="
fresh
sq "INSERT INTO messages (from_agent,to_agent,type,content,priority,notify_ceo,status) VALUES ('cfo','cos','task','x','normal',1,'unread');"

# Sync juvant_db_exec writers: the cloud write fails (HTTP 500) → db.sh spools it.
export FAKE_WRITE_FAIL=1
echo '{"session_id":"s-ptf","tool_name":"Bash","tool_input":{"command":"false"},"agent_type":"cfo"}' \
  | bash "$REPO/hooks/post-tool-use-failure.sh" >/dev/null 2>&1
printf 'snapshot line one\nline two' | AGENT_ROLE=cos bash "$REPO/hooks/pre-compact.sh" >/dev/null 2>&1
echo '{"session_id":"s-cfg","source":"project_settings","file_path":"/x/.claude/settings.json"}' \
  | bash "$REPO/hooks/config-change.sh" >/dev/null 2>&1
echo '{"agent_type":"cfo","session_id":"s-sub"}' | bash "$REPO/hooks/subagent-start.sh" >/dev/null 2>&1
jq -nc --arg t "$TRANSCRIPT" '{agent_type:"cfo",session_id:"s-sub",transcript_path:$t}' \
  | bash "$REPO/hooks/subagent-stop.sh" >/dev/null 2>&1
jq -nc --arg t "$TRANSCRIPT" '{session_id:"s-main",transcript_path:$t}' \
  | AGENT_ROLE=cos bash "$REPO/hooks/session-end.sh" >/dev/null 2>&1
echo '{"session_id":"s-start"}' | AGENT_ROLE=cos bash "$TMP/fixture/hooks/session-start.sh" >/dev/null 2>&1
# helpers/cso-weekly-audit.sh escalation (its exact statement text, sync exec → spooled).
NOW="2026-10-28 10:00:00"
# shellcheck disable=SC1091,SC2034  # SCRIPT_DIR is read by the sourced db.sh
( SCRIPT_DIR="$REPO/hooks"; . "$REPO/hooks/lib/db.sh"; juvant_db_exec "
INSERT INTO messages (from_agent, to_agent, type, content, priority, notify_ceo, created_at)
VALUES (
  'cso-weekly-audit',
  'cos',
  'escalation',
  'CSO cadence signal: last audit 20d, latest action_log 3d (warn=14d fail=30d). Dispatch CSO 5-layer audit from main thread.',
  'critical',
  1,
  '${NOW}'
);
" ) >/dev/null 2>&1
unset FAKE_WRITE_FAIL

# Async juvant_db_exec_async writers (pre/post-tool-use.sh).
echo '{"tool_name":"Bash","session_id":"s1","tool_input":{"command":"git status"}}' \
  | AGENT_ROLE=cos bash "$REPO/hooks/pre-tool-use.sh" >/dev/null 2>&1
echo '{"tool_name":"Bash","session_id":"s1","tool_input":{"command":"git status"},"tool_response":{"stdout":"clean"}}' \
  | AGENT_ROLE=cos bash "$REPO/hooks/post-tool-use.sh" >/dev/null 2>&1
echo '{"tool_name":"Bash","session_id":"s-spec","tool_input":{"command":"JUVANT_EXECUTING_SPEC=42 git status"}}' \
  | AGENT_ROLE=cos bash "$REPO/hooks/pre-tool-use.sh" >/dev/null 2>&1
echo '{"tool_name":"Bash","session_id":"s-deny","tool_input":{"command":"terraform plan"}}' \
  | AGENT_ROLE=eng-frontend bash "$REPO/hooks/pre-tool-use.sh" >/dev/null 2>&1
echo '{"tool_name":"AskUserQuestion","session_id":"s-ask","tool_input":{"question":"ok?"}}' \
  | AGENT_ROLE=cos bash "$REPO/hooks/pre-tool-use.sh" >/dev/null 2>&1
echo '{"tool_name":"AskUserQuestion","session_id":"s-ask","tool_input":{"question":"ok?","answer":"yes"},"tool_response":{}}' \
  | AGENT_ROLE=cos bash "$REPO/hooks/post-tool-use.sh" >/dev/null 2>&1
echo '{"tool_name":"mcp__m365-mail__m365-mail_search_messages","session_id":"s-k2","agent_type":"cfo","tool_input":{"query":"x","shared_user":"finance@example.test"}}' \
  | bash "$REPO/hooks/pre-tool-use.sh" >/dev/null 2>&1
# hooks/session-start.sh HooksIntegrity row (needs a tampered guardrail tree to
# fire for real) — its exact template, via the real async writer.
# shellcheck disable=SC1091,SC2034  # SCRIPT_DIR is read by the sourced db.sh
( SCRIPT_DIR="$REPO/hooks"; . "$REPO/hooks/lib/db.sh"; juvant_db_exec_async "INSERT INTO agent_actions_log
        (session_id, agent, tool_name, args_hash, status, deny_reason, input_summary, started_at)
        VALUES (NULL, 'system', 'HooksIntegrity', '$(printf x | shasum -a 256 | cut -d' ' -f1)', 'failed',
                'guardrail files not from canonical upstream (decisions#300 item 13)',
                'hooks integrity: hooks/pre-tool-use.sh: modified', '2026-10-28 10:00:00');" )
# Rows spooled by pre-#298 framework versions (no started_at; spec_id without it).
{ printf "INSERT INTO agent_actions_log\n  (session_id, agent, tool_name, args_hash, status, deny_reason, input_summary)\n  VALUES\n  ('s-old', 'cos', 'Bash', 'abc', 'pending', NULL, 'legacy');" | tr '\n' ' '; echo
  printf "INSERT INTO agent_actions_log (session_id, agent, tool_name, args_hash, status, deny_reason, input_summary, spec_id) VALUES ('s-old', 'cos', 'Bash', 'abd', 'pending', NULL, 'legacy spec', 7);\n"
} >> "$SPOOL"

SP=$(cat "$SPOOL" 2>/dev/null)
shape() { if printf '%s' "$SP" | grep -qE -- "$2"; then ok "spool holds shape: $1"; else no "spool lacks shape: $1 (writer did not run?)"; fi; }
shape "aal-insert (pre-tool-use, started_at)" "INSERT INTO agent_actions_log .*input_summary, started_at\) .*'s1'"
shape "aal-insert (spec_id)"                  "started_at, spec_id\).*, 42\);"
shape "aal-insert (denied)"                   "'eng-frontend', 'Bash', '[0-9a-f]{64}', 'denied'"
shape "aal-insert (HooksIntegrity)"           "'HooksIntegrity'"
shape "aal-insert (legacy, no started_at)"    "'legacy'"
shape "aal-config"                            "'ConfigChange'"
shape "aal-success (args_hash)"               "status = 'success'.*args_hash = "
shape "aal-success (AskUserQuestion)"         "status = 'success'.*'AskUserQuestion'"
shape "aal-failure"                           "status = 'failure'"
shape "sal-incident (Track 2g)"               "INSERT INTO security_audit_log.*'info'"
shape "agents-session"                        "UPDATE agents SET status='active', session_id='s-start'"
shape "agents-status (active)"                "UPDATE agents SET status='active', updated_at="
shape "agents-status (inactive)"              "UPDATE agents SET status='inactive'"
shape "snapshot"                              "INSERT INTO session_snapshots"
shape "msg-wrap"                              "'session-wrap-reminder'"
shape "msg-cso"                               "'cso-weekly-audit'"
shape "atu-main (UPSERT)"                     "INSERT INTO agent_token_usage.*'main'.*ON CONFLICT"
shape "atu-subagent"                          "INSERT INTO agent_token_usage.*'cfo'"

N=$(grep -c . "$SPOOL")
out=$(drain); rc=$?
eq "drain exit 0" "$rc" "0"
has "all $N statements applied" "$out" "drained $N statement(s)"
[[ ! -e "$QUAR" ]] && ok "nothing quarantined" || { no "legit statement(s) quarantined:"; sed 's/^/        > /' "$QUAR"; }
eq "no spool-injection row" "$(injection_rows)" "0"
eq "pre/post-tool-use row finalized to success" "$(sq "SELECT status FROM agent_actions_log WHERE session_id='s1';")" "success"
eq "AskUserQuestion row finalized (no args_hash match)" "$(sq "SELECT status FROM agent_actions_log WHERE session_id='s-ask';")" "success"
eq "spec_id stamp landed" "$(sq "SELECT spec_id FROM agent_actions_log WHERE session_id='s-spec';")" "42"
eq "denied row landed" "$(sq "SELECT COUNT(*) FROM agent_actions_log WHERE session_id='s-deny' AND status='denied';")" "1"
eq "Track 2g info row landed" "$(sq "SELECT COUNT(*) FROM security_audit_log WHERE severity='info' AND finding LIKE '%finance@example.test%';")" "1"
eq "ConfigChange row landed" "$(sq "SELECT COUNT(*) FROM agent_actions_log WHERE tool_name='ConfigChange';")" "1"
eq "HooksIntegrity row landed" "$(sq "SELECT COUNT(*) FROM agent_actions_log WHERE tool_name='HooksIntegrity';")" "1"
eq "legacy rows landed" "$(sq "SELECT COUNT(*) FROM agent_actions_log WHERE session_id='s-old';")" "2"
eq "snapshot landed" "$(sq "SELECT COUNT(*) FROM session_snapshots;")" "1"
eq "token rows landed (main + subagent)" "$(sq "SELECT COUNT(*) FROM agent_token_usage;")" "2"
eq "wrap-up + cso messages landed" "$(sq "SELECT COUNT(*) FROM messages WHERE type IN ('session-wrap-reminder','escalation');")" "2"
hasnt "no alert sent for a clean drain" "$(cat "$ALERTS" 2>/dev/null)" "spool injection"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== 2: planted decisions INSERT in the live spool → quarantined ==="
fresh
# Control: the planted statement is valid and WOULD land if executed.
cp "$DB" "$TMP/control.db"
sqlite3 "$TMP/control.db" "$PLANT" 2>/dev/null
eq "control: planted statement is effective SQL when executed" \
  "$(sqlite3 "$TMP/control.db" "SELECT COUNT(*) FROM decisions WHERE approved_by='ceo';")" "1"
{ legit s2 1; echo; echo "$PLANT"; legit s2 2; echo; } > "$SPOOL"
out=$(drain); rc=$?
eq "drain exit 0" "$rc" "0"
eq "decisions table unchanged" "$(sq "SELECT COUNT(*) FROM decisions;")" "0"
eq "legit lines around it still applied" "$(sq "SELECT COUNT(*) FROM agent_actions_log WHERE session_id='s2';")" "2"
has "planted line is in the quarantine file" "$(cat "$QUAR" 2>/dev/null)" "$PLANT"
has "quarantine header names the source" "$(cat "$QUAR" 2>/dev/null)" "source=audit-spool.sql"
[[ ! -e "$SPOOL" ]] && ok "spool consumed" || no "spool still present"
eq "one high spool-injection security_audit_log row" "$(injection_rows)" "1"
fnd=$(sq "SELECT finding FROM security_audit_log WHERE category='spool-injection';")
has "finding counts the quarantined statement" "$fnd" "1 spooled statement(s)"
hasnt "finding does not carry the raw SQL" "$fnd" "'ceo'"
has "drain reports the quarantine" "$out" "quarantined"
al=$(alerts)
has "alert attempted on the approvals webhook" "$al" "https://alerts.example.test/approvals"
has "alert names the incident" "$al" "audit spool injection"
hasnt "alert does not echo the raw planted SQL" "$al" "'ceo'"
hasnt "alert does not echo the full statement" "$al" "$PLANT"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== 3: same planted line inside a stranded .draining.<pid> batch ==="
fresh
{ legit s3 1; echo; echo "$PLANT"; legit s3 2; echo; } > "$SPOOL.draining.$DEADPID"
out=$(drain); rc=$?
eq "drain exit 0" "$rc" "0"
eq "decisions table unchanged" "$(sq "SELECT COUNT(*) FROM decisions;")" "0"
eq "legit stranded lines applied" "$(sq "SELECT COUNT(*) FROM agent_actions_log WHERE session_id='s3';")" "2"
[[ ! -e "$SPOOL.draining.$DEADPID" ]] && ok "stranded file removed" || no "stranded file still present"
has "planted line quarantined" "$(cat "$QUAR" 2>/dev/null)" "$PLANT"
has "quarantine header names the stranded batch" "$(cat "$QUAR" 2>/dev/null)" "source=audit-spool.sql.draining.$DEADPID"
eq "high spool-injection row" "$(injection_rows)" "1"
has "finding attributes it to a stranded batch" \
  "$(sq "SELECT finding FROM security_audit_log WHERE category='spool-injection';")" "(1 from stranded batches)"
has "alert attempted" "$(alerts)" "audit spool injection"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== 4: legit line + stacked second statement → whole line quarantined ==="
fresh
sq "INSERT INTO decisions (agent,title,category,status,approved_by,approved_at,created_at) VALUES ('cto','keep me','pr-spec','approved','ceo',datetime('now'),datetime('now'));"
STACK1="$(legit s4 1) DELETE FROM decisions;"
STACK2="INSERT INTO agent_actions_log (session_id, agent, tool_name, args_hash, status, deny_reason, input_summary, started_at) VALUES ('s4', 'cos', 'Bash', 'h', 'pending', NULL, 'x'); DELETE FROM decisions; --', '2026-10-28 10:00:00');"
STACK3="$(legit s4 3);DELETE FROM decisions"
{ echo "$STACK1"; echo "$STACK2"; echo "$STACK3"; legit s4 4; echo; } > "$SPOOL"
out=$(drain)
eq "decisions row survives" "$(sq "SELECT COUNT(*) FROM decisions;")" "1"
eq "only the clean line applied" "$(sq "SELECT COUNT(*) FROM agent_actions_log WHERE session_id='s4';")" "1"
eq "3 stacked lines quarantined" "$(grep -c '^-- quarantined' "$QUAR" 2>/dev/null || echo 0)" "3"
has "finding counts 3" "$(sq "SELECT finding FROM security_audit_log WHERE category='spool-injection';")" "3 spooled statement(s)"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== 5: subquery / function call in a value position → quarantined ==="
fresh
sq "INSERT INTO decisions (agent,title,category,status,approved_by,approved_at,created_at) VALUES ('cto','secret title','pr-spec','approved','ceo',datetime('now'),datetime('now'));"
SUBQ1="INSERT INTO agent_actions_log (session_id, agent, tool_name, args_hash, status, deny_reason, input_summary, started_at) VALUES ('s5', 'cos', 'Bash', 'h', 'pending', NULL, (SELECT group_concat(title) FROM decisions), '2026-10-28 10:00:00');"
SUBQ2="UPDATE agent_actions_log SET status = 'success', result_hash = (SELECT title FROM decisions LIMIT 1), ended_at = '2026-10-28 10:00:00' WHERE id = ( SELECT id FROM agent_actions_log WHERE session_id = 's5' AND agent = 'cos' AND tool_name = 'Bash' AND status = 'pending' ORDER BY started_at DESC LIMIT 1 );"
SUBQ3="INSERT INTO agent_actions_log (session_id, agent, tool_name, args_hash, status, deny_reason, input_summary, started_at) VALUES ('s5', 'cos', 'Bash', 'h', 'pending', NULL, 'x' || (SELECT title FROM decisions), datetime('now'));"
SUBQ4="UPDATE agents SET status='active', updated_at='x' WHERE role='cos' OR 1=1;"
{ echo "$SUBQ1"; echo "$SUBQ2"; echo "$SUBQ3"; echo "$SUBQ4"; } > "$SPOOL"
out=$(drain)
eq "no subquery row applied" "$(sq "SELECT COUNT(*) FROM agent_actions_log WHERE session_id='s5';")" "0"
eq "4 lines quarantined" "$(grep -c '^-- quarantined' "$QUAR" 2>/dev/null || echo 0)" "4"
eq "high spool-injection row" "$(injection_rows)" "1"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== 6: audit-reconcile's UPDATE decisions is not a spool shape ==="
fresh
sq "INSERT INTO decisions (id,agent,title,category,status,approved_by,approved_at,created_at) VALUES (9,'eng-lead','S','pr-spec','approved','ceo',datetime('now'),datetime('now'));"
echo "UPDATE decisions SET status='executed', executed_by='audit-reconcile', executed_at='2026-10-28T10:00:00Z', source_ref='acme/acme-os#5' WHERE id=9 AND status='approved' AND category='pr-spec';" > "$SPOOL"
out=$(drain)
eq "decision stays approved" "$(sq "SELECT status FROM decisions WHERE id=9;")" "approved"
eq "quarantined" "$(grep -c '^-- quarantined' "$QUAR" 2>/dev/null || echo 0)" "1"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== 7: quarantine path follows JUVANT_SPOOL ==="
fresh
mkdir -p "$TMP/alt"; rm -f "$TMP/alt/"*
echo "$PLANT" > "$TMP/alt/custom-spool.sql"
out=$(JUVANT_SPOOL="$TMP/alt/custom-spool.sql" drain)
[[ -s "$TMP/alt/custom-spool.quarantine" ]] && ok "quarantine next to the overridden spool" || no "no quarantine at $TMP/alt/custom-spool.quarantine"
[[ ! -e "$QUAR" ]] && ok "default quarantine untouched" || no "default quarantine written"
eq "decisions table unchanged" "$(sq "SELECT COUNT(*) FROM decisions;")" "0"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== 8: quarantine write fails → line kept in the spool, never executed ==="
fresh
mkdir -p "$QUAR"                                   # a directory: the append fails
{ legit s8 1; echo; echo "$PLANT"; legit s8 2; echo; } > "$SPOOL"
out=$(drain); rc=$?
eq "drain exit 1 (deferred)" "$rc" "1"
eq "decisions table unchanged" "$(sq "SELECT COUNT(*) FROM decisions;")" "0"
eq "head applied once" "$(sq "SELECT COUNT(*) FROM agent_actions_log WHERE session_id='s8';")" "1"
has "planted line re-queued, unexecuted" "$(cat "$SPOOL" 2>/dev/null)" "$PLANT"
eq "tail re-queued with it (2 lines)" "$(grep -c . "$SPOOL" 2>/dev/null || echo 0)" "2"
eq "still reported as a high spool-injection row" "$(injection_rows)" "1"
has "finding says it was kept unexecuted" \
  "$(sq "SELECT finding FROM security_audit_log WHERE category='spool-injection';")" "kept UNEXECUTED"
rmdir "$QUAR"

wait 2>/dev/null
echo
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
