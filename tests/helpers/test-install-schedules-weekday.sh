#!/usr/bin/env bash
# tests/helpers/test-install-schedules-weekday.sh
#
# Regression: helpers/install-schedules.sh placed the weekly
# audit-reconcile job on the wrong day on macOS. launchd `Weekday`
# uses 0/7 = Sunday, 1 = Monday … 6 = Saturday — so Saturday is 6,
# NOT 7. The plist set `Weekday 7`, landing audit-reconcile on Sunday
# and colliding it onto the same day as cso-weekly-audit (Weekday 0,
# Sunday) — while the header comment and the Linux cron branch both
# said/used Saturday (cron field 6). The two platforms disagreed.
#
# This test runs the ACTUAL generator (stubbing launchctl/crontab so
# nothing is loaded into the real scheduler, and overriding HOME so no
# real launchd plist is written), then asserts the generated schedule:
#   - audit-reconcile  → Saturday (6)
#   - cso-weekly-audit → Sunday   (0)   [guard — must stay distinct]
#   - the two weekly jobs fall on DIFFERENT days (the original bug
#     collided them both onto Sunday).
#
# Saturday=6 and Sunday=0 hold in BOTH launchd Weekday and Unix cron
# weekday, so the expected values are identical across OSes.

set -uo pipefail

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
check_ne() { # desc a b
  if [[ "$2" != "$3" ]]; then
    echo "  PASS: $1 ($2 != $3)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 — both are '$2' (weekly jobs collided on one day)"
    FAIL=$((FAIL + 1))
  fi
}

TMPHOME=$(mktemp -d)
STUB=$(mktemp -d)
trap 'rm -rf "$TMPHOME" "$STUB"' EXIT

OS=$(uname -s)
echo "install-schedules weekday regression ($OS)"

AR_DAY=""
CSO_DAY=""

case "$OS" in
  Darwin)
    printf '#!/bin/bash\nexit 0\n' > "$STUB/launchctl"
    chmod +x "$STUB/launchctl"
    HOME="$TMPHOME" PATH="$STUB:$PATH" bash "$SCRIPT" install >/dev/null 2>&1
    PLIST_DIR="$TMPHOME/Library/LaunchAgents"
    PB=/usr/libexec/PlistBuddy
    AR_DAY=$("$PB" -c "Print :StartCalendarInterval:Weekday" \
      "$PLIST_DIR/io.juvant.guardrails.audit-reconcile.plist" 2>/dev/null)
    CSO_DAY=$("$PB" -c "Print :StartCalendarInterval:Weekday" \
      "$PLIST_DIR/io.juvant.guardrails.cso-weekly-audit.plist" 2>/dev/null)
    ;;
  Linux)
    export CRON_CAPTURE="$TMPHOME/crontab.txt"
    cat > "$STUB/crontab" <<'STUBEOF'
#!/bin/bash
# `crontab -l` → pretend no existing crontab; `crontab FILE` → capture
if [[ "${1:-}" == "-l" ]]; then exit 1; fi
cp "$1" "$CRON_CAPTURE"
STUBEOF
    chmod +x "$STUB/crontab"
    HOME="$TMPHOME" PATH="$STUB:$PATH" CRON_CAPTURE="$CRON_CAPTURE" \
      bash "$SCRIPT" install >/dev/null 2>&1
    # cron columns: min hour dom month weekday cmd … — weekday is field 5
    AR_DAY=$(grep 'audit-reconcile\.sh' "$CRON_CAPTURE" | awk '{print $5}')
    CSO_DAY=$(grep 'cso-weekly-audit\.sh' "$CRON_CAPTURE" | awk '{print $5}')
    ;;
  *)
    echo "  SKIP: scheduling unsupported on $OS (test is a no-op)"
    exit 0
    ;;
esac

check "audit-reconcile runs on Saturday" "6" "$AR_DAY"
check "cso-weekly-audit runs on Sunday"  "0" "$CSO_DAY"

# Normalize the launchd/cron "7 also means Sunday" alias before the
# distinctness check, so the original bug (Weekday 7 == Sunday,
# colliding with cso-weekly-audit's 0) is caught as a same-day clash
# and not masked by 7 != 0 being numerically true.
AR_NORM=${AR_DAY/#7/0}
CSO_NORM=${CSO_DAY/#7/0}
check_ne "the two weekly jobs are on different days" "$AR_NORM" "$CSO_NORM"

echo "==============================="
echo " RESULTS: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
