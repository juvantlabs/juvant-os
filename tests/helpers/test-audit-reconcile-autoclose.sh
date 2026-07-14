#!/usr/bin/env bash
# tests/helpers/test-audit-reconcile-autoclose.sh
#
# Layer 2 of ADR 0028 (ARCH-017): audit-reconcile.sh auto-closes the VERIFIABLE
# subset of stale specs so already-done work stops surfacing as Anomaly 4
# (stale) / Anomaly 1 (orphan). This test pins the strict bounds of that
# maintenance-writer carve-out (§4c):
#
#   • pr-spec only, status approved → executed only;
#   • close ONLY on EXACTLY ONE merged PR referencing decisions#<id>;
#   • write ONLY the close-set, tagged executed_by='audit-reconcile';
#   • 0/>1 match, non-pr-spec, or unresolved repo → left approved (still alerted);
#   • the schema trigger is the storage-layer backstop (executed needs source_ref);
#   • D3: a reconciler-tagged row does not raise an Anomaly-1 orphan alert.
#
# The helper is staged into a temp fixture (helpers + hooks/lib/db.sh + a stub
# notification.sh) so its hard-wired $SCRIPT_DIR/../{.juvant,hooks} paths resolve
# to the fixture, never a real instance. A fake `gh` on a front PATH returns
# deterministic PR-search results keyed on the decisions#<id> in --search.

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
eq(){ # desc, expected, actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$2' got '$3')"; fi
}
has(){ # desc, text, needle
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"
  else no "$1 (missing: $3)"; printf '%s\n' "$2" | sed 's/^/        > /'; fi
}

# ── Stage the fixture repo ──────────────────────────────────────────────────
TMP=$(mktemp -d)
FAKEBIN=$(mktemp -d)
trap 'rm -rf "$TMP" "$FAKEBIN"' EXIT

mkdir -p "$TMP/helpers" "$TMP/hooks/lib" "$TMP/.juvant/logs"
cp "$REPO/helpers/audit-reconcile.sh" "$TMP/helpers/"
cp "$REPO/hooks/lib/db.sh" "$TMP/hooks/lib/"
printf '#!/usr/bin/env bash\ncat >/dev/null 2>&1 || true\nexit 0\n' > "$TMP/hooks/notification.sh"
chmod +x "$TMP/hooks/notification.sh"

# turso shim (unused for provider=local, but on PATH for parity).
cp "$FAKETURSO" "$FAKEBIN/turso"; chmod +x "$FAKEBIN/turso"

# Fake gh: `auth status` → ok; `pr list --search "decisions#<id> …"` → JSON keyed
# on <id>. id 1 → exactly one merged PR (closeable); id 4 → two (ambiguous, must
# NOT close); everything else → [] (no match).
cat > "$FAKEBIN/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then exit 0; fi
search=""; prev=""
for a in "$@"; do [[ "$prev" == "--search" ]] && search="$a"; prev="$a"; done
id="${search#*decisions#}"; id="${id%% *}"
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  case "$id" in
    1) echo '[{"number":101,"mergedAt":"2026-07-10T12:00:00Z"}]' ;;
    4) echo '[{"number":201,"mergedAt":"2026-07-10T12:00:00Z"},{"number":202,"mergedAt":"2026-07-11T12:00:00Z"}]' ;;
    *) echo '[]' ;;
  esac
  exit 0
fi
if [[ "$1" == "issue" && "$2" == "list" ]]; then
  case "$id" in
    5) echo '[{"number":301,"createdAt":"2026-07-09T09:00:00Z"}]' ;;
    *) echo '[]' ;;
  esac
  exit 0
fi
echo '[]'; exit 0
GH
chmod +x "$FAKEBIN/gh"

DBFILE="$TMP/.juvant/state.db"
CONFIG_PATH="$TMP/.juvant/config.json"
REPOSLUG="acme/acme-os"

sq(){ sqlite3 "$DBFILE" "$@"; }
fresh_db(){ rm -f "$DBFILE"; sqlite3 "$DBFILE" < "$SCHEMA"; }
write_cfg(){
  jq -n --arg u "file:$DBFILE" --arg org "${REPOSLUG%/*}" --arg rn "${REPOSLUG#*/}" \
    '{db:{provider:"local",url:$u},github_repo:{org:$org,repo_name:$rn}}' > "$CONFIG_PATH"
}
run(){ ( PATH="$FAKEBIN:$PATH" JUVANT_TEST_DB_FILE="$DBFILE" JUVANT_DB_TIMEOUT=15 \
         bash "$TMP/helpers/audit-reconcile.sh" ) 2>&1; }

# seed_spec id category  → a stale (4d old) approved spec
seed_spec(){
  sq "INSERT INTO decisions (id,agent,title,category,status,approved_by,approved_at,created_at)
      VALUES ($1,'eng-lead','Spec $1','$2','approved','ceo',datetime('now','-4 days'),datetime('now','-4 days'));"
}

# ── Scenario A — the verifiable subset closes; everything else stays approved ─
echo "=== A: selective auto-close ==="
fresh_db; write_cfg
seed_spec 1 pr-spec        # exactly one merged PR → CLOSE
seed_spec 2 pr-spec        # no matching PR → stay approved
seed_spec 3 gh-issue-spec  # no matching issue → stay approved
seed_spec 4 pr-spec        # two merged PRs (ambiguous) → stay approved
seed_spec 5 gh-issue-spec  # exactly one existing issue → CLOSE (#147 item 2)
out=$(run)

eq "id1 pr-spec + 1 merged PR → executed" \
   "executed|audit-reconcile|$REPOSLUG#101" \
   "$(sq "SELECT status||'|'||executed_by||'|'||source_ref FROM decisions WHERE id=1;")"
eq "id1 executed_at = PR mergedAt" "2026-07-10T12:00:00Z" \
   "$(sq "SELECT executed_at FROM decisions WHERE id=1;")"
eq "id5 gh-issue-spec + 1 existing issue → executed (createdAt)" \
   "executed|audit-reconcile|$REPOSLUG#301|2026-07-09T09:00:00Z" \
   "$(sq "SELECT status||'|'||executed_by||'|'||source_ref||'|'||executed_at FROM decisions WHERE id=5;")"
eq "id2 pr-spec, no PR → stays approved" "approved" \
   "$(sq "SELECT status FROM decisions WHERE id=2;")"
eq "id3 gh-issue-spec, no matching issue → stays approved" "approved" \
   "$(sq "SELECT status FROM decisions WHERE id=3;")"
eq "id4 pr-spec, ambiguous (2 PRs) → stays approved" "approved" \
   "$(sq "SELECT status FROM decisions WHERE id=4;")"
has "reports exactly 2 auto-closes (pr + issue)" "$out" "auto-closed stale pr/issue-specs (Layer 2, ADR 0028): 2"
has "remaining stale count reflects post-close reality (id2,3,4)" "$out" \
   "stale gh-issue/pr specs (>3d unexecuted): 3"

# ── Scenario B — D3: a reconciler-tagged row is NOT an orphan ────────────────
echo "=== B: D3 orphan exclusion ==="
fresh_db; write_cfg
# executed_by='audit-reconcile', within the 7d window, NO antecedent action.
sq "INSERT INTO decisions (id,agent,title,category,status,executed_by,executed_at,source_ref,approved_by,approved_at,created_at)
    VALUES (10,'eng-lead','Reconciled','pr-spec','executed','audit-reconcile',datetime('now','-1 days'),'$REPOSLUG#77','ceo',datetime('now','-4 days'),datetime('now','-2 days'));"
out=$(run)
has "reconciler-tagged close raises NO orphan alert" "$out" \
   "orphan decisions (possible fabrication):  0"

# control: a normal agent decision with no antecedent IS an orphan.
fresh_db; write_cfg
sq "INSERT INTO decisions (agent,title,created_at) VALUES ('cfo','Orphan',datetime('now','-1 days'));"
out=$(run)
has "control: untagged decision with no antecedent → orphan=1" "$out" \
   "orphan decisions (possible fabrication):  1"

# ── Scenario C — no gh / unresolved repo → no close, alert-only degradation ──
echo "=== C: safe degradation (gh absent) ==="
fresh_db; write_cfg
seed_spec 1 pr-spec
# Run WITHOUT the fake gh on PATH (drop FAKEBIN): recovery must skip, row stays.
out=$( PATH="/usr/bin:/bin" JUVANT_TEST_DB_FILE="$DBFILE" JUVANT_DB_TIMEOUT=15 \
       bash "$TMP/helpers/audit-reconcile.sh" 2>&1 || true )
eq "gh absent → pr-spec stays approved (no close)" "approved" \
   "$(sq "SELECT status FROM decisions WHERE id=1;")"

# ── Summary ─────────────────────────────────────────────────────────────────
echo "───────────────────────────────────"
echo "  autoclose: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
