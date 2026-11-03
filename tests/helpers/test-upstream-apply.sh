#!/usr/bin/env bash
# tests/helpers/test-upstream-apply.sh
# ADR 0036 — helpers/upstream-apply.sh applies only canonical upstream content:
# canonical remote, sync/* branch, upstream main resolved and fetched by the
# helper (a moved refs/remotes/upstream/main is ignored), Framework whitelist of
# that commit (globs included), repo-relative paths; then reconciles settings.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for dep in git jq; do command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }; done

PASS=0; FAIL=0
ok(){ echo "    PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (expected [$2], got [$3])"; fi; }
has(){ if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing: $3)"; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
g(){ git -c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=main "$@"; }

# Canonical-looking upstream: …/juvantlabs/juvant-os.git
UP="$T/juvantlabs/juvant-os.git"; mkdir -p "$(dirname "$UP")"; g init -q --bare "$UP"
W="$T/upwork"; g clone -q "$UP" "$W" 2>/dev/null
mkdir -p "$W/hooks" "$W/agents/projects" "$W/helpers" "$W/scripts/templates"
cat > "$W/JUVANT_OS.md" <<'MD'
# x
**Framework whitelist** (files the Skill may apply — never touches anything else):

```
hooks/stop.sh                 helpers/upstream-apply.sh
agents/projects/*.md          scripts/sync-hooks.sh
```
MD
echo 'echo upstream-v2' > "$W/hooks/stop.sh"
echo '# eng lead v2' > "$W/agents/projects/eng-lead.md"
echo 'echo not-whitelisted' > "$W/hooks/secret-tool.sh"
cp "$REPO/helpers/upstream-apply.sh" "$W/helpers/"
cp "$REPO/scripts/sync-hooks.sh" "$REPO/scripts/sync-sandbox.sh" "$W/scripts/"
cp "$REPO/scripts/templates/hooks-registration.json" "$REPO/scripts/templates/sandbox.json" "$W/scripts/templates/"
g -C "$W" add -A; g -C "$W" commit -qm v2; g -C "$W" push -q origin main 2>/dev/null

# The instance: older content, `upstream` remote, a sync branch.
I="$T/inst"; g clone -q "$UP" "$I" 2>/dev/null
mkdir -p "$I/hooks" "$I/.claude" "$I/.juvant/logs"
echo 'echo instance-v1' > "$I/hooks/stop.sh"
echo '{}' > "$I/.claude/settings.json"; echo '{}' > "$I/.juvant/config.json"
cp "$REPO/hooks/bash-policy.json" "$I/hooks/"
g -C "$I" remote rename origin upstream
g -C "$I" checkout -q -b sync/upstream-test
run(){ ( cd "$I" && bash helpers/upstream-apply.sh "$@" ) 2>&1; echo "EXIT:$?"; }

echo "=== applies a whitelisted file from upstream main ==="
out=$(run hooks/stop.sh)
has "APPLIED" "$out" "APPLIED hooks/stop.sh"
eq "content is upstream's" "echo upstream-v2" "$(cat "$I/hooks/stop.sh")"
has "exit 0" "$out" "EXIT:0"
has "logged" "$(cat "$I/.juvant/logs/upstream-apply.log")" "APPLIED hooks/stop.sh"

echo "=== whitelist globs ==="
has "agents/projects/*.md matches" "$(run agents/projects/eng-lead.md)" "APPLIED agents/projects/eng-lead.md"

echo "=== refusals ==="
has "not whitelisted" "$(run hooks/secret-tool.sh)" "REFUSED hooks/secret-tool.sh — not on the upstream Framework whitelist"
has "parent path" "$(run ../x)" "not a repo-relative path"
has "absolute path" "$(run /etc/hosts)" "not a repo-relative path"
has "under .git" "$(run .git/config)" "not a repo-relative path"
has "refusal exits 1" "$(run hooks/secret-tool.sh)" "EXIT:1"

echo "=== a moved refs/remotes/upstream/main is ignored ==="
echo 'echo evil' > "$I/hooks/stop.sh"
EVIL=$(cd "$I" && g add hooks/stop.sh >/dev/null && g commit -qm evil && git rev-parse HEAD)
g -C "$I" update-ref refs/remotes/upstream/main "$EVIL"
run hooks/stop.sh >/dev/null
eq "content is still upstream's" "echo upstream-v2" "$(cat "$I/hooks/stop.sh")"

echo "=== branch and remote guards ==="
g -C "$I" checkout -q -b main-copy
has "not on a sync/ branch" "$(run hooks/stop.sh)" "REFUSED: current branch is 'main-copy'"
g -C "$I" checkout -q sync/upstream-test
g -C "$I" remote set-url upstream "$T/evil/juvant-os-fork.git"
has "non-canonical upstream" "$(run hooks/stop.sh)" "not the canonical juvantlabs/juvant-os"
g -C "$I" remote set-url upstream "$UP"

echo "=== settings reconciled (sync-hooks + sync-sandbox) ==="
echo '{"feature_toggles":{"bash_sandbox":true}}' > "$I/.juvant/config.json"
cp "$REPO/scripts/sync-sandbox.sh" "$REPO/scripts/sync-hooks.sh" "$I/scripts/" 2>/dev/null || { mkdir -p "$I/scripts/templates"; cp "$REPO/scripts/sync-sandbox.sh" "$REPO/scripts/sync-hooks.sh" "$I/scripts/"; }
mkdir -p "$I/scripts/templates"; cp "$REPO/scripts/templates/sandbox.json" "$REPO/scripts/templates/hooks-registration.json" "$I/scripts/templates/"
run --settings-only >/dev/null
eq "sandbox block written" "true" "$(jq -r '.sandbox.enabled' "$I/.claude/settings.json")"
eq "hooks block written" "true" "$(jq -r '.hooks | has("PreToolUse")' "$I/.claude/settings.json")"

echo ""
echo "  upstream-apply: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
