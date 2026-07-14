#!/usr/bin/env bash
# tests/helpers/test-spec-marking-gate.sh
#
# ARCH-017 Layer 1 (ADR 0028) — the shared capture-at-execution gate
# (hooks/lib/spec-marking-gate.sh), exercised end-to-end through BOTH host hooks
# (subagent-stop.sh, main-thread stop.sh). Pins the decision logic plus the
# three hardening fixes found in live adoption (2026-07-14):
#
#   BUG-056 (#143) — independent; tested in tests/hooks/run-tests.sh.
#   BUG-057 (#144) — repo unresolved but a merge seen → WARN, fail-open (here).
#   BUG-058 (#145) — the merge is in the FEAT-051 async spool, not yet the DB;
#                    the gate must drain first and still block (here).
#
# Fixture-staged so the hooks' $SCRIPT_DIR/../{.juvant,hooks,helpers} resolve to
# the temp tree. A fake `gh` returns deterministic PR bodies keyed on PR number.
# Enforcement (CC honoring the block) was confirmed live; not re-checked here.

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
eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$2' got '$3')"; fi; }
has(){ if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing: $3)"; fi; }

TMP=$(mktemp -d); FAKEBIN=$(mktemp -d)
trap 'rm -rf "$TMP" "$FAKEBIN"' EXIT

mkdir -p "$TMP/helpers" "$TMP/hooks/lib" "$TMP/.juvant/logs"
cp "$REPO/hooks/stop.sh" "$REPO/hooks/subagent-stop.sh" "$TMP/hooks/"
cp "$REPO/hooks/lib/db.sh" "$REPO/hooks/lib/track-tokens.sh" \
   "$REPO/hooks/lib/spec-marking-gate.sh" "$TMP/hooks/lib/"
cp "$REPO/helpers/drain-audit-spool.sh" "$TMP/helpers/"
printf '#!/usr/bin/env bash\ncat >/dev/null 2>&1 || true\nexit 0\n' > "$TMP/hooks/notification.sh"
chmod +x "$TMP/hooks/notification.sh"
: > "$TMP/.juvant/transcript.jsonl"    # dummy transcript so stop.sh proceeds

cp "$FAKETURSO" "$FAKEBIN/turso"; chmod +x "$FAKEBIN/turso"
# Fake gh: auth ok; `pr view <N>` → body keyed on N (55 refs decisions#1; 66 none).
cat > "$FAKEBIN/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then exit 0; fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  case "$3" in
    55) echo "Implements the fix. Closes decisions#1. See ARCH-017." ;;
    66) echo "A PR with no governance reference at all." ;;
    *)  echo "" ;;
  esac
  exit 0
fi
echo ""; exit 0
GH
chmod +x "$FAKEBIN/gh"

DBFILE="$TMP/.juvant/state.db"
CONFIG_PATH="$TMP/.juvant/config.json"
SPOOL="$TMP/.juvant/audit-spool.sql"
REPOSLUG="acme/acme-os"
SESS="sess-L1"

sq(){ sqlite3 "$DBFILE" "$@"; }
fresh_db(){ rm -f "$DBFILE" "$SPOOL"; sqlite3 "$DBFILE" < "$SCHEMA"; }
write_cfg(){ # $1: with-repo | no-repo
  if [[ "${1:-with-repo}" == "no-repo" ]]; then
    jq -n --arg u "file:$DBFILE" '{db:{provider:"local",url:$u}}' > "$CONFIG_PATH"
  else
    jq -n --arg u "file:$DBFILE" --arg org "${REPOSLUG%/*}" --arg rn "${REPOSLUG#*/}" \
      '{db:{provider:"local",url:$u},github_repos:[($org+"/"+$rn)]}' > "$CONFIG_PATH"
  fi
}
seed_spec(){ sq "INSERT INTO decisions (id,agent,title,category,status,approved_by,approved_at,created_at)
      VALUES ($1,'eng-lead','Spec $1','pr-spec','$2','ceo',datetime('now','-1 days'),datetime('now','-1 days'));"; }
merge_sql(){ printf "INSERT INTO agent_actions_log (session_id,agent,tool_name,args_hash,status,input_summary,started_at) VALUES ('%s','eng-lead','Bash','h','success','gh pr merge %s --repo %s --squash',datetime('now','-5 minutes'));" "$1" "$2" "$REPOSLUG"; }
seed_merge(){ sq "$(merge_sql "$1" "$2")"; }                 # → straight to DB
spool_merge(){ printf '%s\n' "$(merge_sql "$1" "$2")" > "$SPOOL"; }  # → async spool only

# run <hook> [no-gh] → sets RC/OUT/ERR
run(){
  local hook="$1" mode="${2:-with-gh}" path ev
  path="$FAKEBIN:$PATH"; [[ "$mode" == "no-gh" ]] && path="/usr/bin:/bin"
  if [[ "$hook" == "subagent-stop.sh" ]]; then ev='{"agent_type":"eng-lead","session_id":"'"$SESS"'"}'
  else ev='{"session_id":"'"$SESS"'","transcript_path":"'"$TMP/.juvant/transcript.jsonl"'"}'; fi
  OUT=$( echo "$ev" | PATH="$path" JUVANT_CONFIG="$CONFIG_PATH" JUVANT_TEST_DB_FILE="$DBFILE" \
         JUVANT_DB_TIMEOUT=15 bash "$TMP/hooks/$hook" 2>"$TMP/err" ); RC=$?
  ERR=$(cat "$TMP/err")
}

# ── SubagentStop path ───────────────────────────────────────────────────────
echo "=== subagent-stop.sh ==="
fresh_db; write_cfg; seed_spec 1 approved; seed_merge "$SESS" 55
run subagent-stop.sh
eq "block: unmarked spec after merge → exit 2" "2" "$RC"
has "block reason names the spec" "$OUT" "decisions#1"
has "block emits decision=block"  "$OUT" '"decision":"block"'

fresh_db; write_cfg
sq "INSERT INTO decisions (id,agent,title,category,status,executed_by,executed_at,source_ref,approved_by,approved_at,created_at)
    VALUES (1,'eng-lead','S','pr-spec','executed','eng-lead',datetime('now'),'$REPOSLUG#55','ceo',datetime('now','-1 days'),datetime('now','-1 days'));"
seed_merge "$SESS" 55; run subagent-stop.sh
eq "no block when already executed" "0" "$RC"

fresh_db; write_cfg; seed_spec 1 approved; run subagent-stop.sh
eq "no block without a merge action" "0" "$RC"

fresh_db; write_cfg; seed_spec 1 approved; seed_merge "$SESS" 66; run subagent-stop.sh
eq "no block when PR body has no decisions# ref" "0" "$RC"

fresh_db; write_cfg; seed_spec 1 approved; seed_merge "$SESS" 55; run subagent-stop.sh no-gh
eq "no block when gh absent (fail-open)" "0" "$RC"

fresh_db; write_cfg; seed_spec 1 approved; seed_merge "other" 55; run subagent-stop.sh
eq "no block across sessions" "0" "$RC"

# ── BUG-058: the merge is spooled (not in DB) → gate must drain, then block ──
echo "=== BUG-058: async-spool race ==="
fresh_db; write_cfg; seed_spec 1 approved; spool_merge "$SESS" 55
run subagent-stop.sh
eq "spooled merge (no manual drain) → still blocks (exit 2)" "2" "$RC"
has "spooled merge → block names the spec" "$OUT" "decisions#1"
eq "spool was drained by the gate" "1" \
   "$(sq "SELECT COUNT(*) FROM agent_actions_log WHERE session_id='$SESS';")"

# ── BUG-057: repo unresolved but a merge seen → WARN, fail-open ──────────────
echo "=== BUG-057: unresolved repo → WARN, not silence ==="
fresh_db; write_cfg no-repo; seed_spec 1 approved; seed_merge "$SESS" 55
run subagent-stop.sh
eq "unresolved repo → no block (fail-open)" "0" "$RC"
has "unresolved repo → emits a WARN (not silent)" "$ERR" "github_repos is unresolved"

# ── Main-thread Stop path (the variant the live probe exercised) ─────────────
echo "=== stop.sh (main thread) ==="
fresh_db; write_cfg; seed_spec 1 approved; seed_merge "$SESS" 55
run stop.sh
eq "main-thread merge + unmarked spec → stop.sh blocks (exit 2)" "2" "$RC"
has "stop.sh block emits decision=block" "$OUT" '"decision":"block"'

fresh_db; write_cfg; seed_spec 1 approved; run stop.sh
eq "stop.sh: no merge → no block" "0" "$RC"

# ── Path 1 (ADR 0029) — artifact-less executions via a stamped spec_id ──────
echo "=== ADR-0029: stamped spec_id gate (artifact-less) ==="
aspec_sql(){ # session id  → a success Bash action carrying spec_id
  printf "INSERT INTO agent_actions_log (session_id,agent,tool_name,args_hash,status,input_summary,spec_id,started_at) VALUES ('%s','eng-lead','Bash','h','success','JUVANT_EXECUTING_SPEC=%s az keyvault set',%s,datetime('now','-5 minutes'));" "$1" "$2" "$2"
}
seed_aspec(){ sq "$(aspec_sql "$1" "$2")"; }
spool_aspec(){ printf '%s\n' "$(aspec_sql "$1" "$2")" > "$SPOOL"; }

# 1. stamped spec_id + approved decision → block (names the spec).
fresh_db; write_cfg; seed_spec 7 approved; seed_aspec "$SESS" 7
run subagent-stop.sh
eq "stamped spec_id, approved → exit 2 (block)" "2" "$RC"
has "block names the stamped spec" "$OUT" "decisions#7"

# 2. KEY: Path 1 is pure-DB → blocks even with gh ABSENT (no PR to recover).
fresh_db; write_cfg; seed_spec 7 approved; seed_aspec "$SESS" 7
run subagent-stop.sh no-gh
eq "stamped spec_id blocks with gh absent (pure-DB path)" "2" "$RC"

# 3. decision already executed → no block.
fresh_db; write_cfg
sq "INSERT INTO decisions (id,agent,title,category,status,executed_by,executed_at,source_ref,approved_by,approved_at,created_at)
    VALUES (8,'eng-lead','S','pr-spec','executed','eng-lead',datetime('now'),'$REPOSLUG#9','ceo',datetime('now','-1 days'),datetime('now','-1 days'));"
seed_aspec "$SESS" 8; run subagent-stop.sh
eq "stamped spec_id but decision executed → no block" "0" "$RC"

# 4. BUG-058: the stamped action is SPOOLED (not yet in DB) → gate drains, blocks.
fresh_db; write_cfg; seed_spec 7 approved; spool_aspec "$SESS" 7
run subagent-stop.sh
eq "spooled stamped action (no manual drain) → still blocks" "2" "$RC"

# 5. main-thread Stop covers it too.
fresh_db; write_cfg; seed_spec 7 approved; seed_aspec "$SESS" 7
run stop.sh
eq "stop.sh: stamped spec_id → block" "2" "$RC"

echo "───────────────────────────────────"
echo "  spec-marking-gate: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
