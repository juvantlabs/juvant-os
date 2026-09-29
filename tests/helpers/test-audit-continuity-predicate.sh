#!/usr/bin/env bash
# tests/helpers/test-audit-continuity-predicate.sh
#
# decisions#277 — regression tests for the BUG-070 continuity predicate
# introduced in scripts/audit-bootstrap-baseline.sh (Layer 1 access).
#
# Replaces the old aggregate non-emptiness check (COUNT(*)==0) with a
# windowed continuity check across three DB write surfaces:
#   agent_actions_log, messages, session_snapshots
# and a halt_windows coverage branch.
#
# 10 test cases (spec §D.1):
#  (i)   Empty log            → HIGH  audit-surface-continuity-gap
#  (ii)  Today latest         → PASS  (no continuity finding)
#  (iii) Stale 10d            → PASS  (below WARN threshold)
#  (iv)  Stale 20d            → MEDIUM audit-surface-continuity-gap
#  (v)   Stale 45d            → HIGH  audit-surface-continuity-gap
#  (vi)  Stale 45d + full halt_windows cover → INFO audit-surface-continuity-covered
#  (vii) Stale 45d + partial halt_windows cover → HIGH audit-surface-continuity-gap
#  (viii) Stale 25d (action only) + messages/snapshots current → HIGH divergent
#  (ix)  Stale 25d + spool non-empty → INFO track-3-async-pending
#  (x)   Two adjacent halt_windows covering gap → INFO audit-surface-continuity-covered

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEMA="$REPO/scripts/schema.sql"

for dep in sqlite3 jq python3; do
  command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }
done

PASS=0; FAIL=0
ok(){ echo "    PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }

# has <desc> <output> <needle>
has(){
  if printf '%s' "$2" | grep -qF -- "$3"
  then ok "$1"
  else no "$1 (missing needle: $3)"; printf '%s\n' "$2" | sed 's/^/        | /' | head -20
  fi
}
# not_has <desc> <output> <needle>
not_has(){
  if ! printf '%s' "$2" | grep -qF -- "$3"
  then ok "$1"
  else no "$1 (unexpected needle found: $3)"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Stage scripts + hooks so $ROOT resolves inside the script
mkdir -p "$TMP/scripts" "$TMP/hooks/lib" "$TMP/.juvant"
cp "$REPO/scripts/audit-bootstrap-baseline.sh" "$TMP/scripts/"
cp "$REPO/hooks/lib/db.sh"                     "$TMP/hooks/lib/"

DBFILE="$TMP/.juvant/state.db"
CONFIG_PATH="$TMP/.juvant/config.json"

sq(){ sqlite3 "$DBFILE" "$@"; }

fresh_db(){
  rm -f "$DBFILE"
  sqlite3 "$DBFILE" < "$SCHEMA"
  # Required by scope=global triggers; audit runs company scope.
  sq "INSERT INTO master_context (key, value) VALUES ('company_type', 'master');"
}

write_cfg(){
  printf '{"db":{"provider":"local","url":"file:%s"}}\n' "$DBFILE" > "$CONFIG_PATH"
}

# seed three write surfaces at a fixed age (days ago).
seed_all_stale(){
  local days="$1"
  sq "INSERT INTO agent_actions_log (agent, tool_name, args_hash, status, started_at)
      VALUES ('cos','Bash','aaah$days','success',datetime('now','-${days} days'));"
  sq "INSERT INTO messages (from_agent,to_agent,type,content,priority,notify_ceo,created_at)
      VALUES ('cos','atlas','escalation','x','low',0,datetime('now','-${days} days'));"
  sq "INSERT INTO session_snapshots (agent,snapshot,created_at)
      VALUES ('cos','{}',datetime('now','-${days} days'));"
}

seed_all_fresh(){
  sq "INSERT INTO agent_actions_log (agent,tool_name,args_hash,status,started_at)
      VALUES ('cos','Bash','fresh1','success',datetime('now'));"
  sq "INSERT INTO messages (from_agent,to_agent,type,content,priority,notify_ceo,created_at)
      VALUES ('cos','atlas','escalation','x','low',0,datetime('now'));"
  sq "INSERT INTO session_snapshots (agent,snapshot,created_at)
      VALUES ('cos','{}',datetime('now'));"
}

# seed only agent_actions_log stale; messages+snapshots fresh.
seed_action_stale_rest_fresh(){
  local days="$1"
  sq "INSERT INTO agent_actions_log (agent,tool_name,args_hash,status,started_at)
      VALUES ('cos','Bash','diverg1','success',datetime('now','-${days} days'));"
  sq "INSERT INTO messages (from_agent,to_agent,type,content,priority,notify_ceo,created_at)
      VALUES ('cos','atlas','escalation','x','low',0,datetime('now'));"
  sq "INSERT INTO session_snapshots (agent,snapshot,created_at)
      VALUES ('cos','{}',datetime('now'));"
}

set_halt_windows(){
  local json="$1"
  sq "INSERT OR REPLACE INTO master_context (key,value) VALUES ('halt_windows','${json}');"
}

# Place a non-empty spool file to trigger track-3-async-pending branch.
make_spool(){
  mkdir -p "$TMP/.juvant"
  printf 'INSERT INTO agent_actions_log (agent,tool_name,args_hash,status) VALUES (\"cos\",\"Bash\",\"sp1\",\"success\");\n' \
    > "$TMP/.juvant/audit-spool.sql"
}
clear_spool(){
  rm -f "$TMP/.juvant/audit-spool.sql"
}

run(){
  JUVANT_CONFIG="$CONFIG_PATH" \
  CONTINUITY_WARN_DAYS="${CONTINUITY_WARN_DAYS:-14}" \
  CONTINUITY_FAIL_DAYS="${CONTINUITY_FAIL_DAYS:-30}" \
  bash "$TMP/scripts/audit-bootstrap-baseline.sh" 2>/dev/null || true
}

# Extract severity for a given category from JSON output lines.
find_sev(){
  local output="$1" category="$2"
  printf '%s' "$output" \
    | python3 -c "
import sys, json
cat = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        if obj.get('category') == cat:
            print(obj.get('severity',''))
            sys.exit(0)
    except Exception:
        pass
" "$category" 2>/dev/null || true
}

has_category(){
  local output="$1" category="$2"
  printf '%s' "$output" | python3 -c "
import sys, json
cat = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        if obj.get('category') == cat:
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
" "$category" 2>/dev/null
}

# ── (i) Empty log → HIGH audit-surface-continuity-gap ───────────────────────
echo "=== (i) empty log → HIGH ==="
fresh_db; write_cfg; clear_spool
out=$(CONTINUITY_WARN_DAYS=14 CONTINUITY_FAIL_DAYS=30 run)
sev=$(find_sev "$out" "audit-surface-continuity-gap")
if [[ "$sev" == "high" ]]; then ok "(i) empty log → HIGH audit-surface-continuity-gap"
else no "(i) empty log → expected high, got '${sev}'"; fi

# ── (ii) Today latest → PASS (no continuity finding) ───────────────────────
echo "=== (ii) today latest → PASS ==="
fresh_db; write_cfg; clear_spool; seed_all_fresh
out=$(CONTINUITY_WARN_DAYS=14 CONTINUITY_FAIL_DAYS=30 run)
if has_category "$out" "audit-surface-continuity-gap" 2>/dev/null; then
  no "(ii) today latest → unexpected continuity finding"
else
  ok "(ii) today latest → no audit-surface-continuity-gap finding"
fi
if has_category "$out" "audit-surface-divergent-silence" 2>/dev/null; then
  no "(ii) today latest → unexpected divergent finding"
else
  ok "(ii) today latest → no audit-surface-divergent-silence finding"
fi

# ── (iii) Stale 10d → PASS (below 14d WARN) ────────────────────────────────
echo "=== (iii) stale 10d → PASS ==="
fresh_db; write_cfg; clear_spool; seed_all_stale 10
out=$(CONTINUITY_WARN_DAYS=14 CONTINUITY_FAIL_DAYS=30 run)
if has_category "$out" "audit-surface-continuity-gap" 2>/dev/null; then
  no "(iii) 10d stale → unexpected continuity finding"
else
  ok "(iii) 10d stale (< 14d WARN) → PASS"
fi

# ── (iv) Stale 20d → MEDIUM ────────────────────────────────────────────────
echo "=== (iv) stale 20d → MEDIUM ==="
fresh_db; write_cfg; clear_spool; seed_all_stale 20
out=$(CONTINUITY_WARN_DAYS=14 CONTINUITY_FAIL_DAYS=30 run)
sev=$(find_sev "$out" "audit-surface-continuity-gap")
if [[ "$sev" == "medium" ]]; then ok "(iv) 20d stale → MEDIUM audit-surface-continuity-gap"
else no "(iv) 20d stale → expected medium, got '${sev}'"; fi

# ── (v) Stale 45d → HIGH ────────────────────────────────────────────────────
echo "=== (v) stale 45d → HIGH ==="
fresh_db; write_cfg; clear_spool; seed_all_stale 45
out=$(CONTINUITY_WARN_DAYS=14 CONTINUITY_FAIL_DAYS=30 run)
sev=$(find_sev "$out" "audit-surface-continuity-gap")
if [[ "$sev" == "high" ]]; then ok "(v) 45d stale → HIGH audit-surface-continuity-gap"
else no "(v) 45d stale → expected high, got '${sev}'"; fi

# ── (vi) Stale 45d + full halt_windows cover → INFO ─────────────────────────
echo "=== (vi) stale 45d + full halt_windows → INFO ==="
# Skip if jq strptime is unavailable (jq <1.6 does not implement it).
jq_strptime_ok=0
echo 'null' | jq 'now | strftime("%Y-%m-%d")' >/dev/null 2>&1 && jq_strptime_ok=1
if [[ "$jq_strptime_ok" == "1" ]]; then
  fresh_db; write_cfg; clear_spool; seed_all_stale 45
  # Window covering from 50d ago through today.
  start_date=$(date -u -v-50d +%Y-%m-%d 2>/dev/null || date -u -d "50 days ago" +%Y-%m-%d)
  end_date=$(date -u +%Y-%m-%d)
  set_halt_windows "[{\"start\":\"${start_date}\",\"end\":\"${end_date}\"}]"
  out=$(CONTINUITY_WARN_DAYS=14 CONTINUITY_FAIL_DAYS=30 run)
  sev=$(find_sev "$out" "audit-surface-continuity-covered")
  if [[ "$sev" == "info" ]]; then ok "(vi) 45d stale + full halt_windows → INFO audit-surface-continuity-covered"
  else no "(vi) 45d stale + full halt_windows → expected info, got '${sev}'"; fi
  # Must NOT emit the continuity-gap finding.
  if has_category "$out" "audit-surface-continuity-gap" 2>/dev/null; then
    no "(vi) must not emit continuity-gap when halt covered"
  else
    ok "(vi) no audit-surface-continuity-gap when halt covered"
  fi
else
  echo "    SKIP: (vi) jq strptime not available"
fi

# ── (vii) Stale 45d + partial halt_windows → HIGH ───────────────────────────
echo "=== (vii) stale 45d + partial halt_windows → HIGH ==="
if [[ "$jq_strptime_ok" == "1" ]]; then
  fresh_db; write_cfg; clear_spool; seed_all_stale 45
  # Window covers only 10 days ago through today — does NOT cover the 45d gap.
  recent_start=$(date -u -v-10d +%Y-%m-%d 2>/dev/null || date -u -d "10 days ago" +%Y-%m-%d)
  end_date=$(date -u +%Y-%m-%d)
  set_halt_windows "[{\"start\":\"${recent_start}\",\"end\":\"${end_date}\"}]"
  out=$(CONTINUITY_WARN_DAYS=14 CONTINUITY_FAIL_DAYS=30 run)
  sev=$(find_sev "$out" "audit-surface-continuity-gap")
  if [[ "$sev" == "high" ]]; then ok "(vii) 45d + partial halt → HIGH audit-surface-continuity-gap"
  else no "(vii) 45d + partial halt → expected high, got '${sev}'"; fi
else
  echo "    SKIP: (vii) jq strptime not available"
fi

# ── (viii) Action stale 25d, messages+snapshots current → HIGH divergent ─────
echo "=== (viii) divergent: action 25d, rest current → HIGH ==="
fresh_db; write_cfg; clear_spool; seed_action_stale_rest_fresh 25
out=$(CONTINUITY_WARN_DAYS=14 CONTINUITY_FAIL_DAYS=30 run)
sev=$(find_sev "$out" "audit-surface-divergent-silence")
if [[ "$sev" == "high" ]]; then ok "(viii) divergent 25d action-only → HIGH audit-surface-divergent-silence"
else no "(viii) divergent → expected high, got '${sev}'"; fi
# Must NOT be classified as plain continuity-gap (which requires silent_count==3).
if has_category "$out" "audit-surface-continuity-gap" 2>/dev/null; then
  no "(viii) divergent must not emit audit-surface-continuity-gap"
else
  ok "(viii) divergent: no plain continuity-gap category"
fi

# ── (ix) Action stale 25d + spool non-empty → INFO track-3-async-pending ─────
echo "=== (ix) action stale + non-empty spool → INFO track-3-async ==="
fresh_db; write_cfg; seed_all_stale 25
make_spool
# Also seed messages+snapshots stale so all three surfaces are past WARN.
out=$(CONTINUITY_WARN_DAYS=14 CONTINUITY_FAIL_DAYS=30 run)
sev=$(find_sev "$out" "track-3-async-pending")
if [[ "$sev" == "info" ]]; then ok "(ix) stale + non-empty spool → INFO track-3-async-pending"
else no "(ix) stale + non-empty spool → expected info track-3-async-pending, got '${sev}'"; fi
# Must NOT emit a continuity-gap (spool takes priority).
if has_category "$out" "audit-surface-continuity-gap" 2>/dev/null; then
  no "(ix) non-empty spool must not emit continuity-gap"
else
  ok "(ix) no continuity-gap when spool non-empty"
fi

# ── (x) Two adjacent halt_windows fully covering → INFO ─────────────────────
echo "=== (x) two adjacent halt_windows covering → INFO ==="
if [[ "$jq_strptime_ok" == "1" ]]; then
  fresh_db; write_cfg; clear_spool; seed_all_stale 45
  # Two windows that together cover from 50d ago through today.
  w1_start=$(date -u -v-50d +%Y-%m-%d 2>/dev/null || date -u -d "50 days ago" +%Y-%m-%d)
  w1_end=$(date -u -v-22d +%Y-%m-%d 2>/dev/null   || date -u -d "22 days ago"  +%Y-%m-%d)
  w2_start=$(date -u -v-21d +%Y-%m-%d 2>/dev/null  || date -u -d "21 days ago"  +%Y-%m-%d)
  w2_end=$(date -u +%Y-%m-%d)
  set_halt_windows "[{\"start\":\"${w1_start}\",\"end\":\"${w1_end}\"},{\"start\":\"${w2_start}\",\"end\":\"${w2_end}\"}]"
  out=$(CONTINUITY_WARN_DAYS=14 CONTINUITY_FAIL_DAYS=30 run)
  sev=$(find_sev "$out" "audit-surface-continuity-covered")
  if [[ "$sev" == "info" ]]; then ok "(x) two adjacent halt_windows → INFO audit-surface-continuity-covered"
  else no "(x) two adjacent halt_windows → expected info, got '${sev}'"; fi
else
  echo "    SKIP: (x) jq strptime not available"
fi

# ── (xi) Actions fresh + sparse surfaces EMPTY → NO finding (fresh bootstrap) ──
# An empty sparse surface (messages / session_snapshots never written) is
# NEUTRAL, not a ~20k-day silence. A fresh/quiet instance must not raise a false
# HIGH divergent-silence. (Regression for the review finding.)
echo "=== (xi) fresh actions + empty sparse → no finding ==="
fresh_db; write_cfg; clear_spool
sq "INSERT INTO agent_actions_log (agent,tool_name,args_hash,status,started_at) VALUES ('cos','Bash','h','success', datetime('now'));"
out=$(CONTINUITY_WARN_DAYS=14 CONTINUITY_FAIL_DAYS=30 run)
if has_category "$out" "audit-surface-continuity-gap" || has_category "$out" "audit-surface-divergent-silence"; then
  no "(xi) fresh actions + empty sparse → unexpected continuity finding (false HIGH)"
else
  ok "(xi) fresh actions + empty sparse → no false continuity finding"
fi

# ── (xii) Broken reader → fail-safe HIGH (never a silent all-clear) ──────────
# A surface that cannot be read (missing table / unreachable DB) must RAISE — the
# grep+`${:-0}` used to coerce a failed read to 0 = "fresh". (Regression for the
# review finding.)
echo "=== (xii) broken reader → fail-safe HIGH ==="
fresh_db; write_cfg; clear_spool; seed_all_fresh
sq "DROP TABLE session_snapshots;"
out=$(CONTINUITY_WARN_DAYS=14 CONTINUITY_FAIL_DAYS=30 run)
sev=$(find_sev "$out" "audit-continuity-reader-error")
if [[ "$sev" == "high" ]]; then ok "(xii) broken reader → HIGH audit-continuity-reader-error"
else no "(xii) broken reader → expected high reader-error, got '${sev}'"; fi

echo "───────────────────────────────────"
echo "  continuity-predicate: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
