#!/usr/bin/env bash
# tests/helpers/test-install-schedules-interval.sh
#
# Regression (decisions#300 item 14): on macOS the "every N minutes"
# launchd jobs (drain-audit-spool 5 min, anomaly-check 15 min,
# drain-outbox 15 min) were emitted with StartInterval and NEVER fired
# on their own (runs=0 after bootstrap; no scheduled run after a manual
# kickstart), while the StartCalendarInterval jobs on the same machine
# ran. The generator now emits them as StartCalendarInterval arrays of
# {Minute} dicts, and the installer runs a post-install self-check that
# fails loudly when a job's launchd `runs` counter does not advance.
#
# Asserts (macOS):
#   1. each interval job's plist has NO StartInterval key, and a
#      StartCalendarInterval ARRAY whose Minute entries are <integer>s
#      covering exactly every N minutes of the hour;
#   2. self-check PASSES (exit 0) when the stubbed run counter advances;
#   3. self-check FAILS (non-zero + stderr) when the counter is stuck;
#   4. self-check FAILS when a job is reported disabled;
#   5. JUVANT_SCHED_SELFCHECK=0 skips the check (exit 0 even if stuck).
# On Linux: asserts the cron entries are unchanged (*/5, */15).
#
# Nothing touches the real scheduler: launchctl is a stateful stub
# injected via JUVANT_LAUNCHCTL, HOME points at a temp dir.

set -uo pipefail
# These tests run the installer straight from this repo: keep the jobs on the
# working tree (no pinned worktree of the repo itself — BUG-089 has its own test).
export JUVANT_SCHED_PINNED=0

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/helpers/install-schedules.sh"

PASS=0
FAIL=0
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then
    echo "  PASS: $1 (= $3)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 — expected '$2', got '$3'"
    FAIL=$((FAIL + 1))
  fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

OS=$(uname -s)
echo "install-schedules interval-job regression ($OS)"

case "$OS" in
  Darwin) ;;
  Linux)
    STUB="$WORK/stub"; mkdir -p "$STUB"
    export CRON_CAPTURE="$WORK/crontab.txt"
    cat > "$STUB/crontab" <<'STUBEOF'
#!/bin/bash
if [[ "${1:-}" == "-l" ]]; then exit 1; fi
cp "$1" "$CRON_CAPTURE"
STUBEOF
    chmod +x "$STUB/crontab"
    HOME="$WORK" PATH="$STUB:$PATH" bash "$SCRIPT" install >/dev/null 2>&1
    check "cron drain-audit-spool every 5 min" "*/5" \
      "$(grep 'drain-audit-spool\.sh' "$CRON_CAPTURE" | awk '{print $1}')"
    check "cron anomaly-check every 15 min" "*/15" \
      "$(grep 'anomaly-check\.sh' "$CRON_CAPTURE" | awk '{print $1}')"
    check "cron drain-outbox every 15 min" "*/15" \
      "$(grep 'drain-outbox\.sh' "$CRON_CAPTURE" | awk '{print $1}')"
    echo "==============================="
    echo " RESULTS: $PASS passed, $FAIL failed"
    [[ "$FAIL" -eq 0 ]]
    exit $?
    ;;
  *)
    echo "  SKIP: scheduling unsupported on $OS (test is a no-op)"
    exit 0
    ;;
esac

# --- stateful launchctl stub ------------------------------------------
# State dir: $LC_STATE/<label>.loaded (present = bootstrapped),
# $LC_STATE/<label>.runs (counter). LC_ADVANCE=1 → kickstart bumps runs;
# LC_ADVANCE=0 → runs stays put (the live bug). LC_DISABLED=<label> →
# print-disabled reports it disabled.
STUB_LC="$WORK/launchctl"
cat > "$STUB_LC" <<'STUBEOF'
#!/bin/bash
S="$LC_STATE"
lbl() { local t="${1##*/}"; echo "$t"; }
case "$1" in
  bootout)   rm -f "$S/$(lbl "$2").loaded" ;;
  bootstrap) l=$(basename "$3" .plist); touch "$S/$l.loaded"
             [ -f "$S/$l.runs" ] || echo 0 > "$S/$l.runs" ;;
  enable)    : ;;
  print)     l=$(lbl "$2"); [ -f "$S/$l.loaded" ] || exit 113
             printf '%s = {\n\tactive count = 0\n\truns = %s\n' "$2" "$(cat "$S/$l.runs")"
             [ "${LC_PENDED:-}" = "$l" ] && printf '\tpended nondemand spawn = interval\n'
             printf '}\n' ;;
  print-disabled)
             printf 'disabled services = {\n'
             [ -n "${LC_DISABLED:-}" ] && printf '\t"%s" => disabled\n' "$LC_DISABLED"
             printf '}\n' ;;
  kickstart) l=$(lbl "$2")
             if [ "${LC_ADVANCE:-1}" = 1 ]; then
               echo $(( $(cat "$S/$l.runs") + 1 )) > "$S/$l.runs"
             fi ;;
esac
exit 0
STUBEOF
chmod +x "$STUB_LC"

run_install() { # extra env assignments as args; prints exit code
  local st="$WORK/state.$RANDOM$RANDOM"; mkdir -p "$st"
  local home="$WORK/home.$RANDOM$RANDOM"; mkdir -p "$home"
  env HOME="$home" LC_STATE="$st" JUVANT_LAUNCHCTL="$STUB_LC" \
    JUVANT_SCHED_SELFCHECK=1 JUVANT_SCHED_SELFCHECK_TIMEOUT=1 \
    JUVANT_SCHED_SELFCHECK_POLL=0.2 "$@" \
    bash "$SCRIPT" install >"$WORK/out" 2>"$WORK/err"
  LAST_RC=$?
  LAST_HOME="$home"
}

# 1. plist shape -------------------------------------------------------
run_install LC_ADVANCE=1
PB=/usr/libexec/PlistBuddy
PLIST_DIR="$LAST_HOME/Library/LaunchAgents"
for spec in drain-audit-spool:5 anomaly-check:15 drain-outbox:15; do
  label=${spec%%:*}; step=${spec##*:}
  p="$PLIST_DIR/io.juvant.guardrails.$label.plist"
  check "$label plist is valid (plutil -lint)" "0" \
    "$(plutil -lint "$p" >/dev/null 2>&1; echo $?)"
  check "$label has no StartInterval key" "absent" \
    "$("$PB" -c 'Print :StartInterval' "$p" >/dev/null 2>&1 && echo present || echo absent)"
  check "$label StartCalendarInterval is an array" "array" \
    "$(plutil -extract StartCalendarInterval xml1 -o - "$p" 2>/dev/null | grep -o '<array>' | head -1 | tr -d '<>')"
  want=""; m=0
  while [ "$m" -lt 60 ]; do want="$want$m,"; m=$((m + step)); done
  got=""; i=0
  while v=$("$PB" -c "Print :StartCalendarInterval:$i:Minute" "$p" 2>/dev/null); do
    got="$got$v,"; i=$((i + 1))
  done
  check "$label fires every $step min (Minute slots)" "$want" "$got"
  check "$label Minute is <integer>" "integer" \
    "$(plutil -extract StartCalendarInterval.0.Minute xml1 -o - "$p" 2>/dev/null | grep -o '<integer>' | head -1 | tr -d '<>')"
done
check "advancing counter → install exit 0" "0" "$LAST_RC"
check "advancing counter → self-check OK lines" "3" \
  "$(grep -c 'self-check OK' "$WORK/out")"

# 3. stuck counter -----------------------------------------------------
run_install LC_ADVANCE=0
check "stuck counter → install exits non-zero" "1" "$LAST_RC"
check "stuck counter → stderr names each interval job" "3" \
  "$(grep -c 'SELF-CHECK FAIL: .*did not advance' "$WORK/err")"
check "stuck counter → FATAL on stderr" "1" \
  "$(grep -c 'FATAL: post-install self-check failed' "$WORK/err")"

# 4. disabled job ------------------------------------------------------
run_install LC_ADVANCE=1 LC_DISABLED=io.juvant.guardrails.drain-audit-spool
check "disabled job → install exits non-zero" "1" "$LAST_RC"
check "disabled job → stderr says DISABLED" "1" \
  "$(grep -c 'drain-audit-spool is DISABLED' "$WORK/err")"

# 4b. pended non-demand spawn (Low Power Mode on-demand-only domain) ----
# kickstart still advances the counter (demand spawn), so only the pended
# marker reveals that launchd is holding the scheduled runs.
run_install LC_ADVANCE=1 LC_PENDED=io.juvant.guardrails.anomaly-check
check "pended nondemand spawn → install exits non-zero" "1" "$LAST_RC"
check "pended nondemand spawn → stderr names the job + Low Power Mode" "1" \
  "$(grep -c 'anomaly-check has a pended non-demand spawn.*Low Power Mode' "$WORK/err")"
check "pended job's kickstart still advanced (why the counter alone misses it)" "3" \
  "$(grep -c 'self-check OK' "$WORK/out")"
check "only the pended job is flagged" "1" \
  "$(grep -c 'pended non-demand spawn' "$WORK/err")"

# 5. opt-out -----------------------------------------------------------
run_install LC_ADVANCE=0 JUVANT_SCHED_SELFCHECK=0
check "JUVANT_SCHED_SELFCHECK=0 → skip, exit 0" "0" "$LAST_RC"

echo "==============================="
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
