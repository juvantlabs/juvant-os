#!/usr/bin/env bash
# tests/helpers/test-pause-windows.sh
#
# decisions#300 item 15 (closes decisions#269 / decisions#270): declared pause
# windows (master_context.halt_windows) are consumed through ONE shared lib,
# hooks/lib/pause-windows.sh, by all three audit surfaces:
#   scripts/audit-bootstrap-baseline.sh  (Layer 1 continuity predicate)
#   helpers/cso-weekly-audit.sh          (weekly cadence gate)
#   helpers/audit-reconcile.sh           (continuity summary line)
#
# Semantics pinned for every consumer:
#   (a) gap fully covered by window(s)   → no alert
#   (b) gap partially covered            → alert only on the UNCOVERED portion
#   (c) activity INSIDE a window         → INFO, exit 0 (not an alarm)
#   (d) no windows key                   → behaviour unchanged
# plus negative cases: malformed declaration suppresses nothing; a window that
# does not overlap the gap suppresses nothing; the cadence gate's fail-safe
# "never audited" sentinel is never discounted.
#
# Local sqlite only (provider=local) — never touches a real Turso DB.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEMA="$REPO/scripts/schema.sql"
FAKETURSO="$REPO/tests/hooks/fake-turso.sh"

for dep in sqlite3 jq python3; do
  command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }
done

PASS=0; FAIL=0
ok(){ echo "    PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$2' got '$3')"; fi; }
has(){
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"
  else no "$1 (missing: $3)"; printf '%s\n' "$2" | sed 's/^/        | /' | head -25; fi
}
not_has(){
  if ! printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"
  else no "$1 (unexpected: $3)"; printf '%s\n' "$2" | sed 's/^/        | /' | head -25; fi
}

# d <N> → UTC date N days ago (YYYY-MM-DD); d 0 = today.
d(){ date -u -v-"$1"d +%Y-%m-%d 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%d; }

# ── Fixture ─────────────────────────────────────────────────────────────────
TMP=$(mktemp -d)
FAKEBIN=$(mktemp -d)
trap 'rm -rf "$TMP" "$FAKEBIN"' EXIT

mkdir -p "$TMP/scripts" "$TMP/helpers" "$TMP/hooks/lib" "$TMP/.juvant/logs"
cp "$REPO/scripts/audit-bootstrap-baseline.sh" "$TMP/scripts/"
cp "$REPO/helpers/cso-weekly-audit.sh" "$REPO/helpers/audit-reconcile.sh" "$TMP/helpers/"
cp "$REPO/hooks/lib/db.sh" "$REPO/hooks/lib/pause-windows.sh" "$TMP/hooks/lib/"
printf '#!/usr/bin/env bash\ncat >/dev/null 2>&1 || true\nexit 0\n' > "$TMP/hooks/notification.sh"
chmod +x "$TMP/hooks/notification.sh"
cp "$FAKETURSO" "$FAKEBIN/turso"; chmod +x "$FAKEBIN/turso"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/curl"; chmod +x "$FAKEBIN/curl"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/gh";   chmod +x "$FAKEBIN/gh"

DBFILE="$TMP/.juvant/state.db"
CONFIG_PATH="$TMP/.juvant/config.json"
printf '{"db":{"provider":"local","url":"file:%s"},"notifications":{"teams_webhooks":{"ops":""}}}\n' \
  "$DBFILE" > "$CONFIG_PATH"

sq(){ sqlite3 "$DBFILE" "$@"; }
fresh_db(){
  rm -f "$DBFILE"
  sqlite3 "$DBFILE" < "$SCHEMA"
  sq "INSERT INTO master_context (key,value) VALUES ('company_type','master');"
  rm -f "$TMP/.juvant/audit-spool.sql"
}
set_windows(){ sq "INSERT OR REPLACE INTO master_context (key,value) VALUES ('halt_windows','$1');"; }
win(){ printf '{"start":"%s","end":"%s"}' "$1" "$2"; }

seed_action(){ sq "INSERT INTO agent_actions_log (agent,tool_name,args_hash,status,started_at)
                   VALUES ('cos','Bash','h$RANDOM','success',datetime('now','-$1 days'));"; }
seed_audit(){ sq "INSERT INTO security_audit_log (audit_type,auditor,scope,created_at,bootstrap_baseline)
                  VALUES ('bootstrap_baseline','cso','company',datetime('now','-$1 days'),1);"; }
seed_all(){ # all three continuity surfaces at age N days
  seed_action "$1"
  sq "INSERT INTO messages (from_agent,to_agent,type,content,priority,notify_ceo,created_at)
      VALUES ('cos','atlas','escalation','x','low',0,datetime('now','-$1 days'));"
  sq "INSERT INTO session_snapshots (agent,snapshot,created_at) VALUES ('cos','{}',datetime('now','-$1 days'));"
}

run_baseline(){
  JUVANT_CONFIG="$CONFIG_PATH" CONTINUITY_WARN_DAYS=14 CONTINUITY_FAIL_DAYS=30 \
    bash "$TMP/scripts/audit-bootstrap-baseline.sh" 2>/dev/null || true
}
run_cso(){
  ( PATH="$FAKEBIN:$PATH" JUVANT_CONFIG="$CONFIG_PATH" CONTINUITY_WARN_DAYS=14 CONTINUITY_FAIL_DAYS=30 \
    bash "$TMP/helpers/cso-weekly-audit.sh" ) 2>&1; echo "EXIT:$?"
}
run_reconcile(){
  ( PATH="$FAKEBIN:$PATH" JUVANT_CONFIG="$CONFIG_PATH" CONTINUITY_WARN_DAYS=14 CONTINUITY_FAIL_DAYS=30 \
    bash "$TMP/helpers/audit-reconcile.sh" ) 2>&1; echo "EXIT:$?"
}
# sev_of <output> <category> → severity of first finding with that category ("" if none)
sev_of(){
  printf '%s' "$1" | python3 -c '
import sys, json
cat = sys.argv[1]
for line in sys.stdin:
    try: o = json.loads(line)
    except Exception: continue
    if o.get("category") == cat:
        print(o.get("severity","")); break
' "$2"
}
# lib <bash-snippet> → run a snippet with db.sh + pause-windows.sh sourced
lib(){
  ( export JUVANT_CONFIG="$CONFIG_PATH"
    # shellcheck disable=SC1091
    . "$TMP/hooks/lib/db.sh"; . "$TMP/hooks/lib/pause-windows.sh"
    eval "$1" )
}

# ════════════════════════════════════════════════════════════════════════════
echo "=== L: shared lib unit cases ==="
fresh_db
eq "L1 no key → load fails (caller keeps legacy behaviour)" "1" \
   "$(lib 'juvant_pause_windows_load; echo $?')"
set_windows '{"start":"2026-01-01"}'
eq "L2 non-array value → load fails (suppresses nothing)" "1" \
   "$(lib 'juvant_pause_windows_load; echo $?')"
set_windows '[]'
eq "L3 empty array → load fails" "1" "$(lib 'juvant_pause_windows_load; echo $?')"
set_windows "[$(win "$(d 17)" "$(d 1)")]"
eq "L4 gap 17d, window ends yesterday → uncovered 1d" "1" \
   "$(lib 'juvant_pause_windows_load && juvant_pause_uncovered_days 17')"
set_windows "[$(win "$(d 50)" "$(d 0)")]"
eq "L5 gap 45d, window through today → uncovered 0d" "0" \
   "$(lib 'juvant_pause_windows_load && juvant_pause_uncovered_days 45')"
set_windows "[$(win "$(d 10)" "$(d 0)")]"
eq "L6 gap 45d, window covers last 10d → uncovered 34d (older part)" "34" \
   "$(lib 'juvant_pause_windows_load && juvant_pause_uncovered_days 45')"
set_windows "[$(win "$(d 20)" "$(d 10)")]"
eq "L7 gap 30d, window in the middle → longest uncovered run 10d" "10" \
   "$(lib 'juvant_pause_windows_load && juvant_pause_uncovered_days 30')"
set_windows "[{\"start\":\"$(d 30)\",\"end\":null}]"
eq "L8 open-ended window (end:null) → uncovered 0d" "0" \
   "$(lib 'juvant_pause_windows_load && juvant_pause_uncovered_days 25')"
set_windows "[$(win "$(d 40)" "$(d 22)"),$(win "$(d 21)" "$(d 0)")]"
eq "L9 two adjacent windows merge → uncovered 0d" "0" \
   "$(lib 'juvant_pause_windows_load && juvant_pause_uncovered_days 35')"
set_windows "[$(win "$(d 90)" "$(d 60)")]"
eq "L10 window entirely before the gap → uncovered = full gap" "20" \
   "$(lib 'juvant_pause_windows_load && juvant_pause_uncovered_days 20')"
set_windows "[{\"start\":\"2026-01-01'' OR 1=1 --\",\"end\":null},{\"start\":\"bogus\"},$(win "$(d 5)" "$(d 3)")]"
eq "L11 invalid / injection-shaped entries dropped, valid kept" "$(d 5)..$(d 3)" \
   "$(lib 'juvant_pause_windows_load && juvant_pause_windows_summary')"
fresh_db; seed_action 35; seed_action 50; seed_action 1
set_windows "[$(win "$(d 40)" "$(d 30)")]"
eq "L12 activity inside window counted (only the in-window row)" "1" \
   "$(lib 'juvant_pause_windows_load && juvant_pause_activity_inside agent_actions_log started_at' | cut -d'|' -f1)"

# ════════════════════════════════════════════════════════════════════════════
echo "=== B: audit-bootstrap-baseline.sh (CSO Layer 1) ==="
# (a) the 2026-10-28 incident shape: 17d silence, window ended YESTERDAY.
fresh_db; seed_all 17; set_windows "[$(win "$(d 17)" "$(d 1)")]"
out=$(run_baseline)
eq "B-a full cover (window ended yesterday) → INFO covered" "info" \
   "$(sev_of "$out" audit-surface-continuity-covered)"
eq "B-a full cover → no continuity-gap finding" "" "$(sev_of "$out" audit-surface-continuity-gap)"
# (b) partial cover: 45d silence, window covers the OLDEST 20d → uncovered 25d → MEDIUM (raw would be HIGH).
fresh_db; seed_all 45; set_windows "[$(win "$(d 45)" "$(d 25)")]"
out=$(run_baseline)
eq "B-b partial cover → severity from uncovered 25d = MEDIUM (not HIGH)" "medium" \
   "$(sev_of "$out" audit-surface-continuity-gap)"
has "B-b finding reports the uncovered portion" "$out" "uncovered portion agent_actions_log=25d"
eq "B-b partial cover → not labelled covered" "" "$(sev_of "$out" audit-surface-continuity-covered)"
# (c) activity inside a window (replayed spool rows) + fresh activity → INFO only.
fresh_db; seed_all 0; seed_action 35; set_windows "[$(win "$(d 40)" "$(d 30)")]"
out=$(run_baseline)
eq "B-c activity inside window → INFO audit-activity-inside-pause-window" "info" \
   "$(sev_of "$out" audit-activity-inside-pause-window)"
eq "B-c no continuity-gap" "" "$(sev_of "$out" audit-surface-continuity-gap)"
eq "B-c no divergent-silence" "" "$(sev_of "$out" audit-surface-divergent-silence)"
# (d) no key → unchanged: 20d → MEDIUM, no window categories.
fresh_db; seed_all 20
out=$(run_baseline)
eq "B-d no key → MEDIUM continuity-gap (unchanged)" "medium" "$(sev_of "$out" audit-surface-continuity-gap)"
not_has "B-d no key → no covered category" "$out" "audit-surface-continuity-covered"
not_has "B-d no key → no inside-window category" "$out" "audit-activity-inside-pause-window"
not_has "B-d no key → no window note in finding" "$out" "uncovered portion"
# negatives
fresh_db; seed_all 45; set_windows 'not json'
out=$(run_baseline)
eq "B-neg malformed declaration → HIGH (suppresses nothing)" "high" "$(sev_of "$out" audit-surface-continuity-gap)"
fresh_db; seed_all 45; set_windows "[$(win "$(d 90)" "$(d 60)")]"
out=$(run_baseline)
eq "B-neg non-overlapping window → HIGH" "high" "$(sev_of "$out" audit-surface-continuity-gap)"
eq "B-neg non-overlapping window → no inside-window INFO (no rows in it)" "" \
   "$(sev_of "$out" audit-activity-inside-pause-window)"

# ════════════════════════════════════════════════════════════════════════════
echo "=== C: cso-weekly-audit.sh (cadence gate) ==="
# (a) incident: actions 17d, audit 17d, window d17..d1 → exit 0, no ALERT.
fresh_db; seed_audit 17; seed_action 17; set_windows "[$(win "$(d 17)" "$(d 1)")]"
out=$(run_cso)
has "C-a full cover → exit 0" "$out" "EXIT:0"
not_has "C-a full cover → no ALERT" "$out" "ALERT:"
has "C-a full cover → says covered" "$out" "covered by declared halt_windows"
eq "C-a full cover → no escalation row" "0" \
   "$(sq "SELECT COUNT(*) FROM messages WHERE from_agent='cso-weekly-audit';")"
# (b) partial: actions 45d, window covers last 10d → uncovered 34d → ALERT on 34d.
fresh_db; seed_audit 1; seed_action 45; set_windows "[$(win "$(d 10)" "$(d 0)")]"
out=$(run_cso)
has "C-b partial cover → exit 1" "$out" "EXIT:1"
has "C-b partial cover → ALERT on uncovered 34d" "$out" "actions=34d"
msg=$(sq "SELECT content FROM messages WHERE from_agent='cso-weekly-audit' ORDER BY id DESC LIMIT 1;")
has "C-b escalation body states raw vs uncovered" "$msg" "raw action_log 45d"
has "C-b escalation body uses uncovered figure" "$msg" "latest action_log 34d"
# (c) activity inside window + otherwise healthy → INFO line, exit 0.
fresh_db; seed_audit 1; seed_action 1; seed_action 35; set_windows "[$(win "$(d 40)" "$(d 30)")]"
out=$(run_cso)
has "C-c activity inside → exit 0" "$out" "EXIT:0"
has "C-c activity inside → INFO line" "$out" "INFO: 1 agent_actions_log row(s) dated inside declared halt_windows"
not_has "C-c activity inside → no ALERT" "$out" "ALERT:"
# (d) no key → unchanged: actions 20d → ALERT, no window lines.
fresh_db; seed_audit 1; seed_action 20
out=$(run_cso)
has "C-d no key → exit 1 (unchanged)" "$out" "EXIT:1"
has "C-d no key → ALERT on raw 20d" "$out" "actions=20d) —"
not_has "C-d no key → no halt_windows line" "$out" "declared halt_windows:"
# negatives
fresh_db; seed_audit 1; seed_action 20; set_windows "[$(win "$(d 90)" "$(d 60)")]"
out=$(run_cso)
has "C-neg non-overlapping window → still ALERT" "$out" "ALERT:"
fresh_db; seed_audit 1; seed_action 20; set_windows '{"oops":1}'
out=$(run_cso)
has "C-neg malformed declaration → still ALERT" "$out" "ALERT:"
fresh_db; seed_action 17; set_windows "[$(win "$(d 17)" "$(d 1)")]"   # no audit row ever
out=$(run_cso)
has "C-neg never-audited sentinel (99d) is not discounted → ALERT" "$out" "ALERT: audit stale (audit=99d"

# ════════════════════════════════════════════════════════════════════════════
echo "=== R: audit-reconcile.sh (continuity summary) ==="
fresh_db; seed_action 17; set_windows "[$(win "$(d 17)" "$(d 1)")]"
out=$(run_reconcile)
has "R-a full cover → labelled covered" "$out" "uncovered gap=1d (covered by declared window(s))"
has "R-a exit 0 (informational)" "$out" "EXIT:0"
fresh_db; seed_action 45; set_windows "[$(win "$(d 10)" "$(d 0)")]"
out=$(run_reconcile)
has "R-b partial → reports uncovered 34d" "$out" "uncovered gap=34d (UNCOVERED portion exceeds warn)"
has "R-b partial → still exit 0 (not an anomaly)" "$out" "EXIT:0"
fresh_db; seed_action 0; seed_action 35; set_windows "[$(win "$(d 40)" "$(d 30)")]"
out=$(run_reconcile)
has "R-c activity inside → INFO line" "$out" "INFO: 1 agent_actions_log row(s) dated inside declared halt_windows"
has "R-c activity inside → exit 0" "$out" "EXIT:0"
has "R-c activity inside → zero anomalies" "$out" "OK — no anomalies"
fresh_db; seed_action 20
out=$(run_reconcile)
not_has "R-d no key → no halt_windows output (unchanged)" "$out" "halt_windows"
has "R-d no key → legacy continuity line intact" "$out" "continuity: agent_actions_log latest="
fresh_db; seed_action 20; set_windows 'garbage'
out=$(run_reconcile)
not_has "R-neg malformed → nothing claimed covered" "$out" "covered by declared"

echo "───────────────────────────────────"
echo "  pause-windows: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
