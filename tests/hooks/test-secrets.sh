#!/usr/bin/env bash
# tests/hooks/test-secrets.sh
#
# decisions#305 B1b — secrets live in a gated .juvant/secrets.json, read only
# by hook/helper processes (hooks/lib/secrets.sh); the DB token never appears
# in a curl argv; a read-only token serves reads; the PreToolUse secrets gate
# (Track 2h) denies every tool read/write of the file.
#
# Run:  bash tests/hooks/test-secrets.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMPROOT=$(mktemp -d /tmp/juvant-secrets-XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
t_assert() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); echo "  ok   $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL $1 (expected '$2', got '$3')"; fi
}
SF="secrets"".json"   # assembled so this file's own text never trips the gate's literal match

# ── fixture instance dir ──
D="$TMPROOT/inst/.juvant"; mkdir -p "$D"
CFG="$D/config.json"; SEC="$D/$SF"
cat > "$CFG" <<'JSON'
{ "db": { "provider": "turso", "url": "libsql://unit.example", "auth_token": "WRITE-TOKEN-1" },
  "notifications": { "telegram_bot_token": "BOT-1", "telegram_chat_id": "42",
                     "teams_webhooks": { "approvals": "https://hook/approvals", "ops": "https://hook/ops" } },
  "projects": { "p1": { "turso_db_name": "project-p1", "db": { "auth_token": "PTOK-1" },
                        "notifications": { "teams_webhooks": { "approvals": "https://hook/p1" } } } },
  "github_token": "GH-1",
  "mail_enabled_agents": { "cfo": "finance@example.test" } }
JSON
# shellcheck disable=SC1091
. "$ROOT_DIR/hooks/lib/secrets.sh"

echo "== accessor: legacy fallback + precedence =="
t_assert "legacy: value read from config.json" "WRITE-TOKEN-1" "$(JUVANT_SECRETS_QUIET=1 juvant_secret_get '.db.auth_token' "$CFG")"
t_assert "legacy: deprecation warning on stderr" "yes" \
  "$(juvant_secret_get '.db.auth_token' "$CFG" 2>&1 >/dev/null | grep -q DEPRECATED && echo yes || echo no)"
t_assert "secret paths detected in config" "7" "$(juvant_secret_paths_in "$CFG" | grep -c .)"

echo "== migrate-secrets.sh =="
OUT=$(JUVANT_CONFIG="$CFG" bash "$ROOT_DIR/scripts/migrate-secrets.sh" --dry-run)
t_assert "dry-run changes nothing" "no|7" "$([[ -f "$SEC" ]] && echo yes || echo no)|$(juvant_secret_paths_in "$CFG" | grep -c .)"
t_assert "dry-run never prints a value" "no" "$([[ "$OUT" == *WRITE-TOKEN-1* || "$OUT" == *BOT-1* ]] && echo yes || echo no)"
OUT=$(JUVANT_CONFIG="$CFG" bash "$ROOT_DIR/scripts/migrate-secrets.sh")
t_assert "migration never prints a value" "no" "$([[ "$OUT" == *WRITE-TOKEN-1* || "$OUT" == *PTOK-1* || "$OUT" == *https://hook* ]] && echo yes || echo no)"
t_assert "config.json no longer holds secrets" "0" "$(juvant_secret_paths_in "$CFG" | grep -c . || true)"
t_assert "non-secret keys stay in config" "finance@example.test|42|project-p1" \
  "$(jq -r '.mail_enabled_agents.cfo + "|" + .notifications.telegram_chat_id + "|" + .projects.p1.turso_db_name' "$CFG")"
# GNU stat first: on Linux `stat -f` exists but means "filesystem status".
fmode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
t_assert "secrets file mode 600" "600" "$(fmode "$SEC")"
t_assert "accessor now reads from the secrets file (no warning)" "WRITE-TOKEN-1|" \
  "$(juvant_secret_get '.db.auth_token' "$CFG" 2>"$TMPROOT/err")|$(grep DEPRECATED "$TMPROOT/err" || true)"
t_assert "project webhook moved" "https://hook/p1" "$(juvant_secret_get '.projects["p1"].notifications.teams_webhooks["approvals"]' "$CFG")"
OUT=$(JUVANT_CONFIG="$CFG" bash "$ROOT_DIR/scripts/migrate-secrets.sh")
t_assert "second run is a no-op" "yes" "$([[ "$OUT" == *"nothing to do"* ]] && echo yes || echo no)"
jq '.db.auth_token = "STALE-IN-CONFIG"' "$CFG" > "$CFG.t" && mv "$CFG.t" "$CFG"
JUVANT_CONFIG="$CFG" bash "$ROOT_DIR/scripts/migrate-secrets.sh" >/dev/null
t_assert "existing secrets-file value wins over a stale config copy" "WRITE-TOKEN-1" "$(juvant_secret_get '.db.auth_token' "$CFG")"

echo "== set-secret.sh (add-only) =="
OUT=$(printf '%s' "OPS-HOOK-2" | JUVANT_CONFIG="$CFG" bash "$ROOT_DIR/scripts/set-secret.sh" '.notifications.teams_webhooks.system' 2>&1); RC=$?
t_assert "adds a new secret" "0|https?" "$RC|$([[ "$(juvant_secret_get '.notifications.teams_webhooks.system' "$CFG")" == "OPS-HOOK-2" ]] && echo 'https?' || echo no)"
t_assert "never prints the value" "no" "$([[ "$OUT" == *OPS-HOOK-2* ]] && echo yes || echo no)"
OUT=$(printf '%s' "https://attacker.example/hook" | JUVANT_CONFIG="$CFG" bash "$ROOT_DIR/scripts/set-secret.sh" '.notifications.teams_webhooks.approvals' 2>&1); RC=$?
t_assert "refuses to REPLACE an existing secret (alert redirection)" "1|https://hook/approvals" \
  "$RC|$(juvant_secret_get '.notifications.teams_webhooks.approvals' "$CFG")"
OUT=$(printf 'x' | JUVANT_CONFIG="$CFG" bash "$ROOT_DIR/scripts/set-secret.sh" '.a; .b' 2>&1); RC=$?
t_assert "rejects a non-path jq expression" "1" "$RC"
t_assert "secrets file still mode 600" "600" "$(fmode "$SEC")"

echo "== db.sh: token off argv, read-only token for reads =="
jq '.db.read_token = "READ-TOKEN-1"' "$SEC" > "$SEC.t" && mv "$SEC.t" "$SEC"
CAP="$TMPROOT/curlcap"; mkdir -p "$TMPROOT/bin" "$CAP"
cat > "$TMPROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
# capture argv and stdin (curl --config -), answer like libsql
n=$(find "$CAPDIR" -name '*.argv' | wc -l | tr -d ' ')
printf '%s\n' "$@" > "$CAPDIR/$n.argv"
if [[ " $* " == *" --config - "* ]]; then cat > "$CAPDIR/$n.stdin"; fi
body='{"results":[{"type":"ok","response":{"type":"execute","result":{"cols":[{"name":"n"}],"rows":[[{"type":"integer","value":"1"}]]}}},{"type":"ok","response":{"type":"close"}}]}'
if [[ " $* " == *" -w "* ]]; then printf '%s\n200' "$body"; else printf '%s' "$body"; fi
STUB
chmod +x "$TMPROOT/bin/curl"
(
  export PATH="$TMPROOT/bin:$PATH" CAPDIR="$CAP" JUVANT_CONFIG="$CFG"
  unset TURSO_URL TURSO_TOKEN TURSO_READ_TOKEN
  # shellcheck disable=SC1091
  . "$ROOT_DIR/hooks/lib/db.sh"
  juvant_db_query "SELECT 1" >/dev/null
  juvant_db_exec "UPDATE agents SET status='x' WHERE role='y'" >/dev/null
)
t_assert "no bearer token in any curl argv" "0" "$(cat "$CAP"/*.argv 2>/dev/null | grep -c 'TOKEN-1' || true)"
t_assert "read sent the READ token on stdin" "yes" "$(grep -q 'Bearer READ-TOKEN-1' "$CAP/0.stdin" 2>/dev/null && echo yes || echo no)"
t_assert "write sent the WRITE token on stdin" "yes" "$(grep -q 'Bearer WRITE-TOKEN-1' "$CAP/1.stdin" 2>/dev/null && echo yes || echo no)"

echo "== Track 2h secrets gate =="
H="$ROOT_DIR/hooks/pre-tool-use.sh"
tool() { # <tool> <json-input> [agent_type]
  jq -n --arg t "$1" --argjson i "$2" --arg a "${3:-}" '{tool_name:$t, tool_input:$i, session_id:"s-sec"} + (if $a == "" then {} else {agent_type:$a} end)' \
    | JUVANT_CONFIG="$TMPROOT/none.json" bash "$H" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision'
}
bash_cmd() { tool Bash "$(jq -cn --arg c "$1" '{command:$c}')" "${2:-}"; }
P=".juvant/$SF"
t_assert "Read on the secrets file → deny (main thread)" "deny" "$(tool Read "$(jq -cn --arg p "$P" '{file_path:$p}')")"
t_assert "Read on the secrets file (absolute) → deny (cso)" "deny" "$(tool Read "$(jq -cn --arg p "$ROOT_DIR/$P" '{file_path:$p}')" cso)"
t_assert "Grep with path = secrets file → deny" "deny" "$(tool Grep "$(jq -cn --arg p "$P" '{pattern:"token",path:$p}')")"
t_assert "Grep over .juvant/ → deny" "deny" "$(tool Grep '{"pattern":"token","path":".juvant"}')"
t_assert "Edit / Write on the secrets file → deny" "deny deny" \
  "$(tool Edit "$(jq -cn --arg p "$P" '{file_path:$p,old_string:"a",new_string:"b"}')") $(tool Write "$(jq -cn --arg p "$P" '{file_path:$p,content:"{}"}')")"
t_assert "Read .juvant/config.json → allow" "allow" "$(tool Read '{"file_path":".juvant/config.json"}')"
for c in "cat $P" "jq . $P" "grep token $P" "cp $P /tmp/x" "python3 -c \"print(open('$P').read())\"" \
         "cd .juvant && cat $SF" "cat .juvant/*" "cp -r .juvant /tmp/x" "tar czf /tmp/x.tgz .juvant" "find .juvant -type f -exec cat {} +"; do
  t_assert "Bash deny — $c" "deny" "$(bash_cmd "$c")"
done
for c in "ls .juvant" "cd .juvant" "jq . .juvant/config.json" "bash scripts/migrate-secrets.sh --dry-run" "mkdir -p .juvant/logs"; do
  t_assert "Bash allow — $c" "allow" "$(bash_cmd "$c")"
done

echo "== SessionStart notice =="
D2="$TMPROOT/inst2"; mkdir -p "$D2/.juvant"
echo '{"db":{"provider":"","auth_token":"X"}}' > "$D2/.juvant/config.json"
SS=$(echo '{"session_id":"s"}' | JUVANT_CONFIG="$D2/.juvant/config.json" JUVANT_FRAMEWORK_DEV=1 bash "$ROOT_DIR/hooks/session-start.sh" 2>/dev/null)
t_assert "secrets still in config → SessionStart notice" "yes" "$([[ "$SS" == *"still in .juvant/config.json"* ]] && echo yes || echo no)"
t_assert "notice never prints the value" "no" "$([[ "$SS" == *'"X"'* ]] && echo yes || echo no)"

echo ""
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
