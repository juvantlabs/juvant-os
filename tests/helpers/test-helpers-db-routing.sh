#!/usr/bin/env bash
# tests/helpers/test-helpers-db-routing.sh
#
# Regression for the five scheduled guardrail helpers that used to talk to
# the DB with a raw `turso db shell "$(jq -r '.turso_url')"` — bypassing
# hooks/lib/db.sh. That had three failure modes, all silent:
#
#   1. CONFIG-KEY STALENESS. v0.8 moved the endpoint to `.db.{provider,url}`;
#      `jq -r '.turso_url'` returned "" → the helper FATAL-exited at startup
#      on any instance whose config no longer carries the legacy key.
#   2. NO local-sqlite branch. `turso db shell` cannot read a filesystem
#      path, so on provider=local adopters every query/write no-op'd.
#   3. NO timeout. A hung turso connection never returned (BUG-046).
#
# Routing through db.sh fixes all three. This test runs each converted
# helper against BOTH backends, end to end:
#
#   - provider=local : real sqlite3 over a seeded file DB.
#   - provider=turso : the tests/hooks/fake-turso.sh shim (turso CLI stand-in
#                      → sqlite3), with a config that carries ONLY `.db.url`
#                      and NO `.turso_url` — directly proving failure mode #1
#                      is fixed (the old code would have FATAL-exited here).
#
# Each helper is staged into a temp repo (helpers + hooks/lib/db.sh + a stub
# notification.sh) so its hard-wired `$SCRIPT_DIR/../{.juvant,hooks}` paths
# resolve to the fixture, never the real instance.

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
has(){ # desc, text, needle
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"
  else no "$1 (missing: $3)"; printf '%s\n' "$2" | sed 's/^/        > /'; fi
}
hasre(){ # desc, text, regex
  if printf '%s' "$2" | grep -qE -- "$3"; then ok "$1"
  else no "$1 (no match: $3)"; printf '%s\n' "$2" | sed 's/^/        > /'; fi
}

# ── Stage the fixture repo ──────────────────────────────────────────────────
TMP=$(mktemp -d)
FAKEBIN=$(mktemp -d)
trap 'rm -rf "$TMP" "$FAKEBIN"' EXIT

mkdir -p "$TMP/helpers" "$TMP/hooks/lib" "$TMP/.juvant/logs"
cp "$REPO"/helpers/anomaly-check.sh "$REPO"/helpers/audit-reconcile.sh \
   "$REPO"/helpers/morning-brief.sh "$REPO"/helpers/cso-weekly-audit.sh \
   "$REPO"/helpers/activity-digest.sh "$TMP/helpers/"
cp "$REPO/hooks/lib/db.sh" "$TMP/hooks/lib/"
# Stub notification.sh (audit-reconcile / anomaly-check invoke it).
printf '#!/usr/bin/env bash\ncat >/dev/null 2>&1 || true\nexit 0\n' > "$TMP/hooks/notification.sh"
chmod +x "$TMP/hooks/notification.sh"

# turso shim + curl-capture shim on a front PATH.
cp "$FAKETURSO" "$FAKEBIN/turso"; chmod +x "$FAKEBIN/turso"
cat > "$FAKEBIN/curl" <<'CURL'
#!/usr/bin/env bash
# Capture the AdaptiveCard payload (the value after -d) to $CURL_CAPTURE.
prev=""
for a in "$@"; do
  [[ "$prev" == "-d" ]] && printf '%s' "$a" > "${CURL_CAPTURE:-/dev/null}"
  prev="$a"
done
exit 0
CURL
chmod +x "$FAKEBIN/curl"

DBFILE="$TMP/.juvant/state.db"
CONFIG_PATH="$TMP/.juvant/config.json"

sq(){ sqlite3 "$DBFILE" "$@"; }
fresh_db(){ rm -f "$DBFILE"; sqlite3 "$DBFILE" < "$SCHEMA"; }

write_cfg(){ # provider, url, [teams_ops_webhook]
  local prov="$1" url="$2" teams="${3:-}"
  if [[ -n "$teams" ]]; then
    jq -n --arg p "$prov" --arg u "$url" --arg t "$teams" \
      '{db:{provider:$p,url:$u},notifications:{teams_webhooks:{ops:$t}}}' > "$CONFIG_PATH"
  else
    # NOTE: deliberately NO `.turso_url` key — proves the .db.url path.
    jq -n --arg p "$prov" --arg u "$url" '{db:{provider:$p,url:$u}}' > "$CONFIG_PATH"
  fi
}

run(){ # helper-name  → combined stdout+stderr; provider chosen by current config
  ( PATH="$FAKEBIN:$PATH" JUVANT_TEST_DB_FILE="$DBFILE" \
    CURL_CAPTURE="${CURL_CAPTURE:-/dev/null}" JUVANT_DB_TIMEOUT=15 \
    bash "$TMP/helpers/$1.sh" ) 2>&1
}

# provider → (prov, url) for write_cfg
declare_provider(){ # local|turso  → echoes "prov|url"
  if [[ "$1" == "local" ]]; then echo "local|file:$DBFILE"; else echo "turso|libsql://test-db"; fi
}

for PROVIDER in local turso; do
  echo "=== provider: $PROVIDER ==="
  IFS='|' read -r PROV URL <<< "$(declare_provider "$PROVIDER")"

  # ── audit-reconcile: orphan decision (no antecedent action) → ALERT ───────
  fresh_db
  sq "INSERT INTO decisions (agent,title,created_at) VALUES ('cfo','Orphan X', datetime('now'));"
  write_cfg "$PROV" "$URL"
  out=$(run audit-reconcile); rc=$?
  hasre "audit-reconcile detects the orphan decision" "$out" 'orphan decisions \(possible fabrication\): +1'
  [[ "$rc" -eq 1 ]] && ok "audit-reconcile exits 1 on anomaly" || no "audit-reconcile exit code ($rc)"

  # ── cso-weekly-audit: empty audit log → stale → writes messages row ───────
  fresh_db
  write_cfg "$PROV" "$URL"
  out=$(run cso-weekly-audit); rc=$?
  rows=$(sq "SELECT COUNT(*) FROM messages WHERE from_agent='cso-weekly-audit' AND to_agent='cos';")
  [[ "$rows" -ge 1 ]] && ok "cso-weekly-audit WRITE landed (messages row, the local-death fix)" \
                       || no "cso-weekly-audit wrote no messages row (got $rows)"
  has "cso-weekly-audit reports staleness" "$out" "audit stale"

  # ── anomaly-check: 6/8 denied in last hour → high-denied-rate ALERT ───────
  fresh_db
  sq "INSERT INTO agent_actions_log (agent,tool_name,args_hash,status,input_summary,started_at)
        SELECT 'spy','Bash','h','success',NULL, datetime('now','-10 minutes');"
  sq "INSERT INTO agent_actions_log (agent,tool_name,args_hash,status,input_summary,started_at)
        SELECT 'spy','Bash','h','success',NULL, datetime('now','-9 minutes');"
  for i in 1 2 3 4 5 6; do
    sq "INSERT INTO agent_actions_log (agent,tool_name,args_hash,status,input_summary,started_at)
          VALUES ('spy','Bash','h','denied','probing deny-list', datetime('now','-${i} minutes'));"
  done
  write_cfg "$PROV" "$URL"
  out=$(run anomaly-check); rc=$?
  has "anomaly-check flags the high denied rate" "$out" "spy: high denied rate"
  [[ "$rc" -eq 1 ]] && ok "anomaly-check exits 1 on anomaly" || no "anomaly-check exit code ($rc)"

  # ── activity-digest: per-agent table + denied breakdown (CSV multi-col) ───
  fresh_db
  for i in 1 2 3; do
    sq "INSERT INTO agent_actions_log (agent,tool_name,args_hash,status,started_at)
          VALUES ('cfo','Read','h','success', datetime('now','-${i} hours'));"
  done
  sq "INSERT INTO agent_actions_log (agent,tool_name,args_hash,status,input_summary,started_at)
        VALUES ('cfo','Bash','h','denied','blocked', datetime('now','-2 hours'));"
  write_cfg "$PROV" "$URL"
  out=$(run activity-digest); rc=$?
  hasre "activity-digest renders the per-agent row" "$out" '\| cfo \|'
  has "activity-digest renders denied breakdown" "$out" "- cfo: 1"

  # ── morning-brief: full card pipeline incl. comma-bearing rationale ───────
  fresh_db
  # Comma in the rationale exercises the CSV comma-strip in the concatenated
  # decisions query — a naive `IFS=','` parse would corrupt it.
  sq "INSERT INTO decisions (agent,title,status,rationale,created_at)
        VALUES ('cfo','Refactor billing','proposed','old path, with commas, is slow', datetime('now','-1 hours'));"
  sq "INSERT INTO inbound_queue (counterparty_id,agent_owner,content,confidence,status)
        VALUES ('cp1','clo','need reply','unverified','pending');"
  sq "INSERT INTO agent_actions_log (agent,tool_name,args_hash,status,started_at)
        VALUES ('cfo','Read','h','success', datetime('now','-3 hours'));"
  write_cfg "$PROV" "$URL" "https://stub.invalid/teams-hook"
  CARD="$TMP/card-$PROVIDER.json"
  CURL_CAPTURE="$CARD" out=$(CURL_CAPTURE="$CARD" run morning-brief); rc=$?
  card=$(cat "$CARD" 2>/dev/null || true)
  has "morning-brief built a card with the decision (comma-rationale survived)" "$card" "Refactor billing"
  has "morning-brief card includes the queued agent_owner" "$card" "clo"
  has "morning-brief card includes the health agent" "$card" "cfo"
  has "morning-brief reports success" "$out" "OK — sent brief"
done

# ── Guard: no DB provider configured at all → FATAL exit 1 ───────────────────
echo "=== guard: empty config ==="
fresh_db
echo '{}' > "$CONFIG_PATH"
out=$(run audit-reconcile); rc=$?
[[ "$rc" -eq 1 ]] && ok "empty config → FATAL exit 1" || no "empty config exit ($rc)"
has "empty config names the missing keys" "$out" "no DB provider configured"

echo "==============================="
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
