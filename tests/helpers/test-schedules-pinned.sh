#!/usr/bin/env bash
# tests/helpers/test-schedules-pinned.sh
#
# BUG-089 (juvant-os-pm#192, adopter finding #160): the scheduled guardrail jobs
# run a pinned, read-only checkout of origin/main (.juvant/pinned-main), so a
# branch checkout in the instance working tree does not change the code they
# execute. Runs against a throwaway instance repo with its own origin.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v git >/dev/null || { echo "SKIP: git not installed"; exit 0; }

PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$2' got '$3')"; fi; }
has(){ if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (missing: $3)"; fi; }

TMP=$(mktemp -d)
cleanup() { find "$TMP" -exec chmod u+w {} + 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }

# ── throwaway instance: helpers/hooks/scripts from this repo, with an origin ──
INST="$TMP/inst"; ORIGIN="$TMP/origin.git"
mkdir -p "$INST/.juvant/logs"
cp -R "$REPO/helpers" "$REPO/hooks" "$REPO/scripts" "$INST/"
printf '.juvant/config.json\n' > "$INST/.gitignore"
echo '{"db":{"provider":""}}' > "$INST/.juvant/config.json"
g init -q "$INST"; g -C "$INST" add -A; g -C "$INST" commit -q -m base
g init -q --bare "$ORIGIN"; g -C "$INST" remote add origin "$ORIGIN"
g -C "$INST" push -q origin main; g -C "$INST" fetch -q origin
MAIN0=$(git -C "$INST" rev-parse refs/remotes/origin/main)
PIN="$INST/.juvant/pinned-main"

STUB="$TMP/bin"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/launchctl-stub"
# shellcheck disable=SC2016  # the stub's own variables, expanded when it runs
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "-l" ]]; then cat "$CRON_FILE" 2>/dev/null; exit 0; fi\ncat "${1:-/dev/stdin}" > "$CRON_FILE"\n' > "$STUB/crontab"
chmod +x "$STUB"/*
export CRON_FILE="$TMP/crontab.txt"
install() { HOME="$TMP/home" PATH="$STUB:$PATH" JUVANT_LAUNCHCTL="$STUB/launchctl-stub" JUVANT_SCHED_SELFCHECK=0 \
  bash "$INST/helpers/install-schedules.sh" "$@" 2>&1; }
programs() { # every program path the installed jobs run
  if [[ "$(uname -s)" == "Darwin" ]]; then
    for p in "$TMP/home/Library/LaunchAgents/"io.juvant.guardrails.*.plist; do
      plutil -extract ProgramArguments.1 raw -o - "$p" 2>/dev/null; echo
    done
  else
    awk '{for (i = 1; i <= NF; i++) if ($i == "/bin/bash") { print $(i + 1); break }}' "$CRON_FILE"
  fi
}

echo "== install pins the jobs to origin/main =="
out=$(install install); rc=$?
eq  "install exits 0" "0" "$rc"
has "reports the pinned checkout" "$out" "pinned checkout:"
eq  "pinned checkout is at origin/main" "$MAIN0" "$(git -C "$PIN" rev-parse HEAD 2>/dev/null)"
eq  "every job runs code from the pinned checkout" "0" "$(programs | grep -v "^$PIN/" | grep -c . || true)"
eq  "8 jobs installed" "8" "$(programs | grep -c "^$PIN/" || true)"
if [[ -w "$PIN/helpers/drain-audit-spool.sh" ]]; then no "pinned code is read-only"; else ok "pinned code is read-only"; fi
eq  "pinned .juvant is the instance's state dir" "$INST/.juvant" "$(readlink "$PIN/.juvant")"
eq  "nested worktree hidden from the instance's git status" "0" "$(git -C "$INST" status --porcelain | grep -c pinned-main || true)"

echo "== ACCEPTANCE: a branch checkout does not change what the jobs run =="
g -C "$INST" checkout -q -b evil
echo 'echo pwned' >> "$INST/helpers/drain-audit-spool.sh"; g -C "$INST" commit -q -am evil
eq "pinned drain-audit-spool.sh unchanged (no 'pwned')" "0" "$(grep -c pwned "$PIN/helpers/drain-audit-spool.sh" || true)"
eq "the jobs' code is still origin/main" "$MAIN0" "$(git -C "$PIN" rev-parse HEAD)"

echo "== re-install after a merged sync moves the pin; integrity regen never touches git =="
g -C "$INST" checkout -q main
echo '# merged sync' >> "$INST/helpers/anomaly-check.sh"; g -C "$INST" commit -q -am sync
g -C "$INST" push -q origin main; g -C "$INST" fetch -q origin
MAIN1=$(git -C "$INST" rev-parse refs/remotes/origin/main)
HOME="$TMP/regen" PATH="$STUB:$PATH" JUVANT_LAUNCHCTL=false JUVANT_SCHED_SELFCHECK=0 JUVANT_SCHED_GENERATE_ONLY=1 \
  bash "$INST/helpers/install-schedules.sh" install >/dev/null 2>&1
eq "generate-only (integrity check) leaves the pin where it was" "$MAIN0" "$(git -C "$PIN" rev-parse HEAD)"
if [[ "$(uname -s)" == "Darwin" ]]; then
  eq "generate-only emits the pinned program paths" "$PIN/helpers/drain-audit-spool.sh" \
    "$(plutil -extract ProgramArguments.1 raw -o - "$TMP/regen/Library/LaunchAgents/io.juvant.guardrails.drain-audit-spool.plist")"
fi
SS=$(cd "$INST" && echo '{"session_id":"s"}' | JUVANT_CONFIG="$INST/.juvant/config.json" JUVANT_FRAMEWORK_DEV=1 bash "$INST/hooks/session-start.sh" 2>/dev/null)
has "SessionStart says the pin is behind origin/main" "$SS" "behind origin/main"
install install >/dev/null; eq "re-install moves the pin to the new origin/main" "$MAIN1" "$(git -C "$PIN" rev-parse HEAD)"

echo "== opt-out and uninstall =="
out=$(JUVANT_SCHED_PINNED=0 install install); eq "JUVANT_SCHED_PINNED=0 → jobs run the working tree" "0" "$(programs | grep -c "^$PIN/" || true)"
install install >/dev/null; install uninstall >/dev/null
if [[ -e "$PIN" ]]; then no "uninstall removes the pinned checkout"; else ok "uninstall removes the pinned checkout"; fi
eq "...and its worktree registration" "0" "$(git -C "$INST" worktree list | grep -c pinned-main || true)"

echo "== no origin/main → fails loudly, never pins the working tree =="
INST2="$TMP/inst2"; mkdir -p "$INST2/.juvant"; cp -R "$REPO/helpers" "$REPO/hooks" "$REPO/scripts" "$INST2/"
g init -q "$INST2"; g -C "$INST2" add -A; g -C "$INST2" commit -q -m base
out=$(HOME="$TMP/home2" PATH="$STUB:$PATH" JUVANT_LAUNCHCTL="$STUB/launchctl-stub" JUVANT_SCHED_SELFCHECK=0 bash "$INST2/helpers/install-schedules.sh" install 2>&1); rc=$?
if [[ "$rc" -ne 0 ]]; then ok "non-zero exit"; else no "exited 0"; fi
has "names the missing ref" "$out" "no refs/remotes/origin/main"

echo "───────────────────────────────────"
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
