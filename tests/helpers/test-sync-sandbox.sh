#!/usr/bin/env bash
# tests/helpers/test-sync-sandbox.sh
# ADR 0036 — scripts/sync-sandbox.sh (apply / --check / --print / --remove)
# and the template's denyWrite staying in step with hooks/lib/guardrail-paths.sh.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

PASS=0; FAIL=0
ok(){ echo "    PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (expected [$2], got [$3])"; fi; }
has(){ if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing: $3)"; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
CFG="$T/config.json"; SET="$T/.claude/settings.json"; mkdir -p "$T/.claude"
sync(){ JUVANT_CONFIG="$CFG" JUVANT_SETTINGS="$SET" bash "$REPO/scripts/sync-sandbox.sh" "$@" 2>&1; }

echo "=== toggle off → no-op ==="
echo '{}' > "$CFG"; echo '{"permissions":{"allow":["Bash(ls)"]}}' > "$SET"
out=$(sync); has "reports nothing to do" "$out" "nothing to do"
eq "settings untouched" '{"permissions":{"allow":["Bash(ls)"]}}' "$(jq -c . "$SET")"
eq "--check passes when off" "0" "$(sync --check >/dev/null; echo $?)"

echo "=== toggle on → apply ==="
echo '{"feature_toggles":{"bash_sandbox":true},"sandbox":{"extra_domains":["example.org"]}}' > "$CFG"
eq "--check fails before apply" "1" "$(sync --check >/dev/null; echo $?)"
out=$(sync); has "writes the block" "$out" "sandbox block written"
eq "other keys preserved" '["Bash(ls)"]' "$(jq -c .permissions.allow "$SET")"
eq "enabled" "true" "$(jq -r .sandbox.enabled "$SET")"
eq "no unsandboxed retry" "false" "$(jq -r .sandbox.allowUnsandboxedCommands "$SET")"
eq "excludedCommands exactly the two helpers" '["bash helpers/upstream-apply.sh *","bash helpers/fetch-origin.sh"]' "$(jq -c .sandbox.excludedCommands "$SET")"
doms=$(jq -r '.sandbox.network.allowedDomains | join(" ")' "$SET")
has "gh domains (gh is allowed to some role)" "$doms" "api.github.com"
has "turso domains" "$doms" "*.turso.io"
has "extra_domains from config" "$doms" "example.org"
eq "--check passes after apply" "0" "$(sync --check >/dev/null; echo $?)"
has "idempotent" "$(sync)" "already canonical"

echo "=== --check findings ==="
cp "$SET" "$T/good.json"
jq '.sandbox.enabled = false' "$T/good.json" > "$SET"; has "enabled false" "$(sync --check)" "sandbox.enabled is not true"
jq 'del(.sandbox.allowUnsandboxedCommands)' "$T/good.json" > "$SET"; has "retry allowed" "$(sync --check)" "allowUnsandboxedCommands is not false"
jq '.sandbox.filesystem.denyWrite -= ["./hooks/"]' "$T/good.json" > "$SET"; has "denyWrite gap" "$(sync --check)" "denyWrite misses ./hooks/"
jq '.sandbox.excludedCommands += ["rm *"]' "$T/good.json" > "$SET"; has "extra excluded command" "$(sync --check)" "extra excludedCommands entry 'rm *'"
cp "$T/good.json" "$SET"; echo '{"sandbox":{"enabled":false}}' > "$T/.claude/settings.local.json"
has "settings.local.json override" "$(sync --check)" "settings.local.json overrides"
rm -f "$T/.claude/settings.local.json"
jq '.sandbox.network.allowedDomains += ["evil.example"]' "$T/good.json" > "$SET"
eq "an extra domain is not a --check finding (apply resets it)" "0" "$(sync --check >/dev/null; echo $?)"
sync >/dev/null; eq "apply resets the domain list" "false" "$(jq -r '.sandbox.network.allowedDomains | index("evil.example") != null' "$SET")"

echo "=== --remove ==="
sync --remove >/dev/null; eq "block removed, rest kept" '{"permissions":{"allow":["Bash(ls)"]}}' "$(jq -c . "$SET")"

echo "=== template denyWrite covers the guardrail set (in step with guardrail-paths.sh) ==="
# shellcheck disable=SC1091
. "$REPO/hooks/lib/guardrail-paths.sh"
DW=()   # bash 3.2: no mapfile
while IFS= read -r _l; do DW+=("$_l"); done < <(jq -r '.sandbox.filesystem.denyWrite[]' "$REPO/scripts/templates/sandbox.json")
covered(){ local p="$1" d g
  for d in "${DW[@]}"; do
    # shellcheck disable=SC2088  # a literal "~/" prefix in the template, not a path
    [[ "${d:0:2}" == "~/" ]] && continue   # home paths: checked below
    g="${d#./}"
    if [[ "$g" == */ ]]; then [[ "$p" == "$g"* ]] && return 0
    else # shellcheck disable=SC2053
      [[ "$p" == $g ]] && return 0; fi
  done; return 1; }
for p in hooks/pre-tool-use.sh hooks/lib/db.sh hooks/bash-policy.json helpers/drain-audit-spool.sh \
         scripts/migrate.sh scripts/templates/sandbox.json scripts/templates/hooks-registration.json \
         security/policy.json .juvant/audit-spool.sql .juvant/audit-spool.sql.draining.1 \
         .juvant/audit-spool.quarantine .juvant/backups/x.sql .juvant/alert-receipts.jsonl \
         .juvant/policy-blob-seen .juvant/pinned-main/hooks/stop.sh; do
  if juvant_guardrail_is_path "$p"; then
    if covered "$p"; then ok "denyWrite covers $p"; else no "denyWrite does NOT cover protected $p"; fi
  else
    no "$p is not in the guardrail set any more — update this list"
  fi
done
if jq -e '.sandbox.filesystem.denyWrite | index("~/Library/LaunchAgents/io.juvant*")' "$REPO/scripts/templates/sandbox.json" >/dev/null; then
  ok "denyWrite covers the guardrail launchd plists"; else no "LaunchAgents not covered"; fi

echo ""
echo "  sync-sandbox: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
