#!/usr/bin/env bash
# tests/sync/test-sync-hooks.sh
#
# scripts/sync-hooks.sh — decisions#303 R2: the canonical template's
# permissions_deny entries are MERGED into an instance's .claude/settings.json
# (append missing, keep instance entries, never remove); the stale framework
# comment claiming .juvant/config.json is denied is corrected; the hooks block
# is still reconciled; nothing is merged in the framework repo itself.
#
# Run:  bash tests/sync/test-sync-hooks.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPROOT=$(mktemp -d /tmp/juvant-sync-hooks-XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
t_assert() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); echo "  ok   $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL $1 (expected '$2', got '$3')"; fi
}

# mk_repo <dir> <origin-url> → a scratch repo with the real script + template
mk_repo() {
  mkdir -p "$1/scripts/templates" "$1/.claude"
  cp "$ROOT_DIR/scripts/sync-hooks.sh" "$1/scripts/"
  cp "$ROOT_DIR/scripts/templates/hooks-registration.json" "$1/scripts/templates/"
  git -C "$1" init -q
  git -C "$1" remote add origin "$2"
  cat > "$1/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "_comment": "Autonomous-by-default. Edit/Write inside the repo never prompt; .juvant/config.json and .env* are explicitly denied (token-bearing). Bash gating is delegated to hooks/pre-tool-use.sh.",
    "allow": ["Read(**)"],
    "deny": ["Edit(**/.env)", "Edit(.juvant/backups/**)", "Edit(instance/local-secret.txt)"]
  },
  "additionalDirectories": ["/tmp/instance-only"],
  "hooks": {}
}
JSON
}

TPL_DENY=$(jq -c '.permissions_deny' "$ROOT_DIR/scripts/templates/hooks-registration.json")
t_assert "template carries a non-empty permissions_deny" "yes" \
  "$([[ $(jq 'length' <<< "$TPL_DENY") -gt 0 ]] && echo yes || echo no)"
for want in 'Edit(.juvant/audit-spool.sql)' 'Write(.juvant/audit-spool.sql.*)' 'Edit(.juvant/backups/**)' \
            'Edit(helpers/drain-audit-spool.sh)' 'Write(security/policy.json)'; do
  t_assert "template denies $want" "yes" "$(jq -e --arg w "$want" 'index($w) != null' <<< "$TPL_DENY" >/dev/null && echo yes || echo no)"
done

# ── adopter instance ──
A="$TMPROOT/adopter"; mk_repo "$A" https://github.com/acme/instance.git
bash "$A/scripts/sync-hooks.sh" >/dev/null 2>&1
S="$A/.claude/settings.json"
t_assert "adopter: hooks block reconciled from template" "yes" \
  "$([[ "$(jq -S .hooks "$S")" == "$(jq -S .hooks "$ROOT_DIR/scripts/templates/hooks-registration.json")" ]] && echo yes || echo no)"
t_assert "adopter: every template deny now present" "yes" \
  "$(jq -e --argjson t "$TPL_DENY" '[ $t[] as $d | .permissions.deny | index($d) ] | all(. != null)' "$S" >/dev/null && echo yes || echo no)"
t_assert "adopter: instance deny entries kept" "yes yes" \
  "$(jq -r '[.permissions.deny | index("Edit(**/.env)"), index("Edit(instance/local-secret.txt)")] | map(if . != null then "yes" else "no" end) | join(" ")' "$S")"
t_assert "adopter: no duplicate deny entries" "0" \
  "$(jq '.permissions.deny | length - (unique | length)' "$S")"
t_assert "adopter: instance keys (allow, additionalDirectories) preserved" "Read(**)|/tmp/instance-only" \
  "$(jq -r '.permissions.allow[0] + "|" + .additionalDirectories[0]' "$S")"
t_assert "adopter: stale 'config.json explicitly denied' claim removed" "no" \
  "$(jq -r '.permissions._comment' "$S" | grep -q 'config.json and .env\* are explicitly denied' && echo yes || echo no)"
t_assert "adopter: corrected comment says config.json is NOT denied" "yes" \
  "$(jq -r '.permissions._comment' "$S" | grep -q 'config.json is NOT denied' && echo yes || echo no)"
before=$(jq -S . "$S")
out=$(bash "$A/scripts/sync-hooks.sh" 2>&1)
t_assert "adopter: second run is a no-op" "yes" \
  "$([[ "$before" == "$(jq -S . "$S")" && "$out" == *"no change"* ]] && echo yes || echo no)"

# ── framework repo: denies are NOT merged (they would block framework dev) ──
F="$TMPROOT/framework"; mk_repo "$F" git@github.com:juvantlabs/juvant-os.git
bash "$F/scripts/sync-hooks.sh" >/dev/null 2>&1
t_assert "framework repo: hooks reconciled" "yes" \
  "$([[ "$(jq -S .hooks "$F/.claude/settings.json")" == "$(jq -S .hooks "$ROOT_DIR/scripts/templates/hooks-registration.json")" ]] && echo yes || echo no)"
t_assert "framework repo: framework denies not merged" "no" \
  "$(jq -e '.permissions.deny | index("Edit(.juvant/audit-spool.sql)") != null' "$F/.claude/settings.json" >/dev/null && echo yes || echo no)"
F0="$TMPROOT/framework0"; mk_repo "$F0" git@github.com:juvantlabs/juvant-os.git
JUVANT_FRAMEWORK_DEV=0 bash "$F0/scripts/sync-hooks.sh" >/dev/null 2>&1
t_assert "framework repo + JUVANT_FRAMEWORK_DEV=0: denies merged" "yes" \
  "$(jq -e '.permissions.deny | index("Edit(.juvant/audit-spool.sql)") != null' "$F0/.claude/settings.json" >/dev/null && echo yes || echo no)"

echo ""
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
