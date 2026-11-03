#!/usr/bin/env bash
# tests/helpers/test-monthly-dispatch.sh
#
# FEAT-067 (juvantlabs/juvant-os-pm#203) — helpers/monthly-dispatch.sh:
# first-business-day gate (weekends, MM-DD and YYYY-MM-DD holidays from config
# or JUVANT_HOLIDAYS), idempotency (messages ref_id, decisions category), the
# shape of the enqueued messages row, --dry-run, both jobs, and fail-loud paths.
# Local sqlite DB; curl faked so no Teams call can leave the machine.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEMA="$REPO/scripts/schema.sql"

for dep in sqlite3 jq; do
  command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }
done

PASS=0; FAIL=0
ok(){ echo "    PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (expected [$2], got [$3])"; fi; }
has(){ if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing: $3)"; fi; }

TMP=$(mktemp -d)
FAKEBIN=$(mktemp -d)
trap 'rm -rf "$TMP" "$FAKEBIN"' EXIT

mkdir -p "$TMP/helpers" "$TMP/hooks/lib" "$TMP/.juvant/logs"
cp "$REPO/helpers/monthly-dispatch.sh" "$TMP/helpers/"
cp "$REPO/hooks/lib/db.sh" "$TMP/hooks/lib/"
[[ -f "$REPO/hooks/lib/secrets.sh" ]] && cp "$REPO/hooks/lib/secrets.sh" "$TMP/hooks/lib/"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/curl.calls"\nexit 0\n' "$TMP" > "$FAKEBIN/curl"
chmod +x "$FAKEBIN/curl"

DBFILE="$TMP/.juvant/state.db"
CONFIG_PATH="$TMP/.juvant/config.json"
sq(){ sqlite3 "$DBFILE" "$@"; }

fresh(){   # [holidays-json-array]
  rm -f "$DBFILE" "$TMP/curl.calls"
  sqlite3 "$DBFILE" < "$SCHEMA"
  jq -n --arg db "file:$DBFILE" --argjson h "${1:-[]}" \
    '{db:{provider:"local",url:$db},notifications:{teams_webhooks:{ops:""}},scheduling:{holidays:$h}}' > "$CONFIG_PATH"
}

run(){   # <date> <job> [extra args…]   (JUVANT_HOLIDAYS passes through when set)
  local date="$1" job="$2"; shift 2
  ( PATH="$FAKEBIN:$PATH" JUVANT_CONFIG="$CONFIG_PATH" JUVANT_TODAY="$date" \
    bash "$TMP/helpers/monthly-dispatch.sh" --job "$job" "$@" ) 2>&1
  echo "EXIT:$?"
}
rows(){ sq "SELECT COUNT(*) FROM messages WHERE type='scheduled-dispatch';"; }

echo "=== A: first business day on a weekday enqueues one row (shape) ==="
fresh
out=$(run 2026-12-01 clo-disclosure-audit)
has "Tue 1st → enqueued" "$out" "ENQUEUED"
has "exit 0" "$out" "EXIT:0"
eq "one scheduled-dispatch row" "1" "$(rows)"
eq "row shape" "monthly-dispatch|cos|scheduled-dispatch|high|1|disclosure-audit-2026-12|unread" \
  "$(sq "SELECT from_agent,to_agent,type,priority,notify_ceo,ref_id,status FROM messages;")"
has "content names month, CLO and the prompt" "$(sq "SELECT content FROM messages;")" \
  "Monthly Disclosure Audit due for 2026-12: dispatch the CLO with the Monthly Disclosure Audit prompt"
has "content says read-only on policies" "$(sq "SELECT content FROM messages;")" "Read-only on existing policies."

echo "=== B: not the first business day ==="
out=$(run 2026-12-02 clo-disclosure-audit)
has "Wed 2nd after a Tue 1st → not first" "$out" "not the first business day"
eq "still one row" "1" "$(rows)"

echo "=== C: idempotency ==="
out=$(run 2026-12-01 clo-disclosure-audit)
has "second run same day → already queued" "$out" "already queued"
eq "still one row" "1" "$(rows)"
fresh
sq "INSERT INTO decisions (agent,title,category,status) VALUES ('clo','Disclosure audit 2026-12','disclosure-audit','executed');"
out=$(run "$(date +%Y-%m)-01" clo-disclosure-audit)
if [[ "$out" == *"not a business day"* ]]; then
  ok "decision-category gate (skipped: the 1st of this month is a weekend)"
else
  has "decision of the category this month → protocol already ran" "$out" "already exists"
  eq "no row" "0" "$(rows)"
fi

echo "=== D: 1st on Saturday / Sunday ==="
fresh
has "Sat 1st → not a business day" "$(run 2026-08-01 clo-disclosure-audit)" "not a business day"
has "Mon 3rd → enqueued" "$(run 2026-08-03 clo-disclosure-audit)" "ENQUEUED"
has "Sun 1st → not a business day" "$(run 2026-03-01 clo-disclosure-audit)" "not a business day"
has "Mon 2nd → enqueued" "$(run 2026-03-02 clo-disclosure-audit)" "ENQUEUED"
eq "two rows (Aug, Mar)" "2" "$(rows)"

echo "=== E: holidays from config (MM-DD) ==="
fresh '["01-01","06-02","11-01"]'
has "01-01 on a Friday → holiday" "$(run 2027-01-01 clo-disclosure-audit)" "not a business day"
has "Mon 4 Jan → first business day" "$(run 2027-01-04 clo-disclosure-audit)" "ENQUEUED"
has "06-02 on a Monday (1st is Sunday) → holiday" "$(run 2025-06-02 clo-disclosure-audit)" "not a business day"
has "Tue 3 Jun → first business day" "$(run 2025-06-03 clo-disclosure-audit)" "ENQUEUED"
has "11-01 on a Saturday → not a business day" "$(run 2025-11-01 clo-disclosure-audit)" "not a business day"
has "Mon 3 Nov → first business day" "$(run 2025-11-03 clo-disclosure-audit)" "ENQUEUED"

echo "=== F: no holidays configured → weekends only (no country default) ==="
fresh
has "01-01 on a Friday with no holidays → enqueued" "$(run 2027-01-01 clo-disclosure-audit)" "ENQUEUED"

echo "=== G: one-off YYYY-MM-DD holiday via JUVANT_HOLIDAYS (overrides config) ==="
fresh '["04-01"]'
out=$(JUVANT_HOLIDAYS="2026-06-01" run 2026-06-01 clo-disclosure-audit)
has "2026-06-01 listed as a dated holiday → skipped" "$out" "not a business day"
has "Tue 2 Jun → enqueued" "$(JUVANT_HOLIDAYS="2026-06-01" run 2026-06-02 clo-disclosure-audit)" "ENQUEUED"
has "env overrides config: 04-01 no longer a holiday" "$(JUVANT_HOLIDAYS="" run 2026-04-01 clo-disclosure-audit)" "ENQUEUED"

echo "=== H: --dry-run writes nothing ==="
fresh
out=$(run 2026-12-01 clo-disclosure-audit --dry-run)
has "dry-run prints the decision" "$out" "DRY-RUN"
eq "no row" "0" "$(rows)"

echo "=== I: chro-ranking job ==="
fresh
out=$(run 2026-12-01 chro-ranking)
has "chro → enqueued" "$out" "ENQUEUED"
eq "chro ref_id" "monthly-ranking-2026-12" "$(sq "SELECT ref_id FROM messages;")"
has "chro content" "$(sq "SELECT content FROM messages;")" "dispatch the CHRO with the Monthly Agent Ranking prompt"
has "jobs are independent" "$(run 2026-12-01 clo-disclosure-audit)" "ENQUEUED"

echo "=== J: fail loud ==="
fresh
sq "DROP TABLE messages;"
out=$(run 2026-12-01 clo-disclosure-audit)
has "unreadable messages → WARN" "$out" "WARN: cannot read"
has "exit 1" "$out" "EXIT:1"
echo '{}' > "$CONFIG_PATH"
out=$(run 2026-12-01 clo-disclosure-audit)
has "no DB provider → FATAL" "$out" "FATAL: no DB provider"
has "exit 1" "$out" "EXIT:1"
has "unknown job → usage, exit 2" "$(run 2026-12-01 bogus)" "EXIT:2"

echo "=== K: no Teams webhook → no network call ==="
fresh
run 2026-12-01 clo-disclosure-audit >/dev/null
eq "curl not called" "no" "$([[ -s "$TMP/curl.calls" ]] && echo yes || echo no)"

echo ""
echo "  monthly-dispatch: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
