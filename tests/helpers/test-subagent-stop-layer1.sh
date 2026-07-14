#!/usr/bin/env bash
# tests/helpers/test-subagent-stop-layer1.sh
#
# Layer 1 of ADR 0028 (ARCH-017): subagent-stop.sh capture-at-execution gate.
# When a subagent merged a PR THIS session whose body references an approved,
# still-unmarked pr-spec (decisions#<id>), the hook blocks the stop with a
# satisfiable, self-remediating instruction. This test pins the DECISION LOGIC
# (block iff a concrete, recovered PR→spec link is unmarked; fail-open on every
# ambiguity). It does NOT — and cannot from the framework repo — verify that
# Claude Code *honors* the block; that is a live probe (ARCH-017).
#
# Fixture-staged so subagent-stop.sh's $SCRIPT_DIR/../{.juvant,hooks} resolve to
# the temp tree. A fake `gh` returns deterministic PR bodies keyed on PR number.

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
cp "$REPO/hooks/subagent-stop.sh" "$TMP/hooks/"
cp "$REPO/hooks/lib/db.sh" "$TMP/hooks/lib/"
cp "$REPO/hooks/lib/track-tokens.sh" "$TMP/hooks/lib/" 2>/dev/null || true

cp "$FAKETURSO" "$FAKEBIN/turso"; chmod +x "$FAKEBIN/turso"

# Fake gh: auth ok; `pr view <N> --json body -q .body` → body keyed on N.
#   55 → references decisions#1 ;  66 → no decisions ref.
cat > "$FAKEBIN/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then exit 0; fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  pr="$3"
  case "$pr" in
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
REPOSLUG="acme/acme-os"
SESS="sess-L1"

sq(){ sqlite3 "$DBFILE" "$@"; }
fresh_db(){ rm -f "$DBFILE"; sqlite3 "$DBFILE" < "$SCHEMA"; }
write_cfg(){
  jq -n --arg u "file:$DBFILE" --arg org "${REPOSLUG%/*}" --arg rn "${REPOSLUG#*/}" \
    '{db:{provider:"local",url:$u},github_repo:{org:$org,repo_name:$rn}}' > "$CONFIG_PATH"
}
seed_spec(){ # id status
  sq "INSERT INTO decisions (id,agent,title,category,status,approved_by,approved_at,created_at)
      VALUES ($1,'eng-lead','Spec $1','pr-spec','$2','ceo',datetime('now','-1 days'),datetime('now','-1 days'));"
}
seed_merge(){ # session, summary
  sq "INSERT INTO agent_actions_log (session_id,agent,tool_name,args_hash,status,input_summary,started_at)
      VALUES ('$1','eng-lead','Bash','h','success','$2',datetime('now','-5 minutes'));"
}
# run → prints "<rc>|<stdout>"; PATH toggled via $1 (with-gh | no-gh)
run(){
  local path="$FAKEBIN:$PATH"; [[ "${1:-with-gh}" == "no-gh" ]] && path="/usr/bin:/bin"
  local ev='{"agent_type":"eng-lead","session_id":"'"$SESS"'"}'
  local out rc
  out=$( echo "$ev" | PATH="$path" JUVANT_CONFIG="$CONFIG_PATH" JUVANT_TEST_DB_FILE="$DBFILE" \
         JUVANT_DB_TIMEOUT=15 bash "$TMP/hooks/subagent-stop.sh" 2>/dev/null )
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

# ── 1. BLOCK: merged PR#55 → decisions#1 still approved ──────────────────────
echo "=== 1: block on unmarked spec after merge ==="
fresh_db; write_cfg; seed_spec 1 approved; seed_merge "$SESS" "gh pr merge 55 --repo $REPOSLUG --squash"
res=$(run); rc="${res%%|*}"; out="${res#*|}"
eq  "unmarked spec + merged PR → exit 2 (block)" "2" "$rc"
has "block reason names the spec"   "$out" "decisions#1"
has "block emits decision=block"    "$out" '"decision":"block"'
has "remedy is a satisfiable UPDATE" "$out" "status='executed'"

# ── 2. NO block: spec already executed ──────────────────────────────────────
echo "=== 2: no block when already executed ==="
fresh_db; write_cfg
sq "INSERT INTO decisions (id,agent,title,category,status,executed_by,executed_at,source_ref,approved_by,approved_at,created_at)
    VALUES (1,'eng-lead','Spec 1','pr-spec','executed','eng-lead',datetime('now'),'$REPOSLUG#55','ceo',datetime('now','-1 days'),datetime('now','-1 days'));"
seed_merge "$SESS" "gh pr merge 55 --repo $REPOSLUG --squash"
res=$(run); eq "already-executed spec → exit 0 (no block)" "0" "${res%%|*}"

# ── 3. NO block: no merge action this session ───────────────────────────────
echo "=== 3: no block without a merge action ==="
fresh_db; write_cfg; seed_spec 1 approved
res=$(run); eq "approved spec but no merge this session → exit 0" "0" "${res%%|*}"

# ── 4. NO block: PR body carries no decisions# reference ─────────────────────
echo "=== 4: no block when link unrecoverable ==="
fresh_db; write_cfg; seed_spec 1 approved; seed_merge "$SESS" "gh pr merge 66 --repo $REPOSLUG --squash"
res=$(run); eq "merged PR w/o decisions# ref → exit 0 (fail-open)" "0" "${res%%|*}"

# ── 5. NO block: gh absent → safe degradation to Layer 2 ─────────────────────
echo "=== 5: gh absent → no block ==="
fresh_db; write_cfg; seed_spec 1 approved; seed_merge "$SESS" "gh pr merge 55 --repo $REPOSLUG --squash"
res=$(run no-gh); eq "gh absent → exit 0 (Layer 2 is the net)" "0" "${res%%|*}"

# ── 6. NO block: merge belonged to a DIFFERENT session ──────────────────────
echo "=== 6: no block across sessions ==="
fresh_db; write_cfg; seed_spec 1 approved; seed_merge "other-session" "gh pr merge 55 --repo $REPOSLUG --squash"
res=$(run); eq "merge in another session → exit 0" "0" "${res%%|*}"

echo "───────────────────────────────────"
echo "  subagent-stop L1: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
