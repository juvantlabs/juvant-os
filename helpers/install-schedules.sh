#!/usr/bin/env bash
# helpers/install-schedules.sh
# Installs launchd plists (Mac) or cron entries (Linux) for the
# guardrail helpers per handbook ADR 0004 Track 3 + Track 4.
#
# Schedules:
#   helpers/turso-backup.sh         — daily 03:00
#   helpers/audit-reconcile.sh      — weekly Saturday 03:00
#   helpers/anomaly-check.sh        — every 15 min
#   helpers/morning-brief.sh        — daily 08:00
#   helpers/cso-weekly-audit.sh     — weekly Sunday 22:00
#   helpers/drain-audit-spool.sh    — every 5 min (FEAT-051)
#   helpers/drain-outbox.sh         — every 15 min (ADR 0024)
#
# Idempotent: re-running replaces existing plists / cron entries
# under the well-known JUVANT prefix. Does NOT touch unrelated
# launchd jobs / cron entries.
#
# Usage:
#   ./helpers/install-schedules.sh             # install
#   ./helpers/install-schedules.sh --uninstall # remove
#
# Wizard step 4.5 of JUVANT_OS.md invokes this script (with `Y/n`
# confirmation prompt) at company init.
#
# macOS "every N minutes" jobs (decisions#300 item 14): these are
# emitted as StartCalendarInterval ARRAYS of {Minute} dicts (e.g. every
# 5 min = Minute 0,5,…,55), NOT as StartInterval. On the live install,
# StartInterval jobs (drain-audit-spool 300s, anomaly-check 900s) never
# fired on their own — runs stayed 0 after bootstrap, and after a manual
# kickstart no further run happened within 8 min — while the
# StartCalendarInterval jobs on the same machine ran on schedule.
# Root cause (verified live 2026-10-28): macOS Low Power Mode
# (`pmset -g` lowpowermode 1, set on AC and battery) puts the gui/<uid>
# launchd domain in "on-demand-only mode" — launchd logs "pending spawn,
# domain in on-demand-only mode" and `launchctl print` shows
# "pended nondemand spawn = interval". StartInterval is a NON-demand
# spawn and stays pended indefinitely; StartCalendarInterval fires via
# the com.apple.launchd.calendarinterval event stream (a demand spawn),
# as does `launchctl kickstart` — which is why both still worked.
# Calendar slots also coalesce a missed firing on wake (StartInterval
# firings during sleep are dropped, per launchd.plist(5)), and they
# match the Linux cron `*/N` semantics exactly.
#
# Post-install self-check (macOS): after loading, each "every N min" job
# is kickstarted once and its launchd `runs` counter must advance within
# a bounded timeout, else the installer exits non-zero with a clear
# stderr message. Knobs (all optional):
#   JUVANT_SCHED_SELFCHECK=0|1        default 1; default 0 when CI=true
#   JUVANT_SCHED_SELFCHECK_MODE=kickstart|scheduled
#                                     kickstart (default): kickstart once,
#                                     then poll `runs`. scheduled: do NOT
#                                     kickstart; wait for an unprompted
#                                     scheduled run (set TIMEOUT >= 300+).
#   JUVANT_SCHED_SELFCHECK_TIMEOUT=N  seconds to wait per job (default 30)
#   JUVANT_SCHED_SELFCHECK_POLL=N     poll interval seconds (default 1)
#   JUVANT_LAUNCHCTL=/path            launchctl binary (test injection)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ACTION="${1:-install}"

OS=$(uname -s)

case "$OS" in
  Darwin)
    LAUNCHD_DIR="$HOME/Library/LaunchAgents"
    PREFIX="io.juvant.guardrails"
    LAUNCHCTL="${JUVANT_LAUNCHCTL:-launchctl}"
    DOMAIN="gui/$(id -u)"
    ALL_LABELS="turso-backup audit-reconcile governance-backfill anomaly-check morning-brief cso-weekly-audit drain-audit-spool drain-outbox"
    # "every N minutes" jobs — the ones the post-install self-check verifies.
    INTERVAL_LABELS="anomaly-check drain-audit-spool drain-outbox"

    # Emit a StartCalendarInterval array firing every $1 minutes
    # (Minute 0, $1, 2*$1, … < 60). $1 must divide 60.
    _every_minutes_xml() {
      local step="$1" m=0
      echo "  <key>StartCalendarInterval</key>"
      echo "  <array>"
      while [ "$m" -lt 60 ]; do
        echo "    <dict><key>Minute</key><integer>${m}</integer></dict>"
        m=$((m + step))
      done
      echo "  </array>"
    }

    # Top-level `runs = N` from `launchctl print`; empty when not loaded.
    _lc_runs() {
      "$LAUNCHCTL" print "$1" 2>/dev/null \
        | awk '/^[[:space:]]*runs = [0-9]+/ { sub(/.*runs = /, ""); print; exit }'
    }

    # Post-install self-check (see header). Returns non-zero on failure.
    _selfcheck_interval_jobs() {
      local mode="${JUVANT_SCHED_SELFCHECK_MODE:-kickstart}"
      local timeout="${JUVANT_SCHED_SELFCHECK_TIMEOUT:-30}"
      local poll="${JUVANT_SCHED_SELFCHECK_POLL:-1}"
      local label target before now start failed=0 disabled
      disabled=$("$LAUNCHCTL" print-disabled "$DOMAIN" 2>/dev/null || true)
      for label in $INTERVAL_LABELS; do
        target="$DOMAIN/${PREFIX}.${label}"
        if printf '%s\n' "$disabled" | grep -Eq "\"${PREFIX}\.${label}\" => (disabled|true)"; then
          echo "[install-schedules] SELF-CHECK FAIL: ${target} is DISABLED in launchd (launchctl print-disabled ${DOMAIN}). Run: launchctl enable ${target}" >&2
          failed=1
          continue
        fi
        before=$(_lc_runs "$target")
        if [ -z "$before" ]; then
          echo "[install-schedules] SELF-CHECK FAIL: ${target} is not loaded (launchctl print returned no 'runs' counter)." >&2
          failed=1
          continue
        fi
        if [ "$mode" = "kickstart" ]; then
          "$LAUNCHCTL" kickstart "$target" >/dev/null 2>&1 || true
        fi
        start=$SECONDS
        now="$before"
        while :; do
          now=$(_lc_runs "$target")
          if [ -n "$now" ] && [ "$now" -gt "$before" ]; then
            break
          fi
          if [ $((SECONDS - start)) -ge "$timeout" ]; then
            break
          fi
          sleep "$poll"
        done
        if [ -n "$now" ] && [ "$now" -gt "$before" ]; then
          echo "[install-schedules] self-check OK: ${PREFIX}.${label} runs ${before} -> ${now} (mode=${mode})"
        else
          echo "[install-schedules] SELF-CHECK FAIL: ${target} run counter did not advance within ${timeout}s (runs=${before} -> ${now:-?}, mode=${mode}). The job is loaded but launchd is not running it — inspect: launchctl print ${target}" >&2
          failed=1
        fi
        # A kickstart is a DEMAND spawn, so it succeeds even when launchd is
        # holding the job's scheduled (non-demand) spawns — the decisions#300
        # Low Power Mode failure. Catch that state directly.
        if "$LAUNCHCTL" print "$target" 2>/dev/null | grep -q 'pended nondemand spawn'; then
          echo "[install-schedules] SELF-CHECK FAIL: ${target} has a pended non-demand spawn — launchd is holding its scheduled runs (domain in on-demand-only mode, e.g. macOS Low Power Mode; check: pmset -g | grep lowpowermode)." >&2
          failed=1
        fi
      done
      return "$failed"
    }

    case "$ACTION" in
      install|--install)
        mkdir -p "$LAUNCHD_DIR"

        # Capture installer's PATH + HOME so launchd (which uses a minimal
        # /usr/bin:/bin:/usr/sbin:/sbin environment) can find Homebrew tools
        # like turso and jq. Baked in at install time; re-run this script
        # after changing your PATH if tools move.
        _PLIST_PATH="${PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
        _PLIST_HOME="${HOME}"

        # turso-backup — daily 03:00
        cat > "$LAUNCHD_DIR/${PREFIX}.turso-backup.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${PREFIX}.turso-backup</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${REPO_ROOT}/helpers/turso-backup.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${_PLIST_HOME}</string>
    <key>PATH</key><string>${_PLIST_PATH}</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>3</integer>
    <key>Minute</key><integer>0</integer>
  </dict>
  <key>StandardOutPath</key><string>${REPO_ROOT}/.juvant/logs/turso-backup.log</string>
  <key>StandardErrorPath</key><string>${REPO_ROOT}/.juvant/logs/turso-backup.err</string>
</dict>
</plist>
PLIST

        # audit-reconcile — weekly Saturday 03:00 (launchd Weekday: 0/7=Sunday, 1=Mon … 6=Saturday)
        cat > "$LAUNCHD_DIR/${PREFIX}.audit-reconcile.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${PREFIX}.audit-reconcile</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${REPO_ROOT}/helpers/audit-reconcile.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${_PLIST_HOME}</string>
    <key>PATH</key><string>${_PLIST_PATH}</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key><integer>6</integer>
    <key>Hour</key><integer>3</integer>
    <key>Minute</key><integer>0</integer>
  </dict>
  <key>StandardOutPath</key><string>${REPO_ROOT}/.juvant/logs/audit-reconcile.log</string>
  <key>StandardErrorPath</key><string>${REPO_ROOT}/.juvant/logs/audit-reconcile.err</string>
</dict>
</plist>
PLIST

        # governance-backfill — monthly, 1st of month 04:00 (dry-run, all DBs)
        # Note: launchd does not support "first Saturday of month" natively;
        # Day=1 (1st of month) is the closest idiomatic equivalent.
        cat > "$LAUNCHD_DIR/${PREFIX}.governance-backfill.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${PREFIX}.governance-backfill</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${REPO_ROOT}/scripts/governance-backfill.sh</string>
    <string>--dry-run</string>
    <string>--all</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${_PLIST_HOME}</string>
    <key>PATH</key><string>${_PLIST_PATH}</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Day</key><integer>1</integer>
    <key>Hour</key><integer>4</integer>
    <key>Minute</key><integer>0</integer>
  </dict>
  <key>StandardOutPath</key><string>${REPO_ROOT}/.juvant/logs/governance-backfill.log</string>
  <key>StandardErrorPath</key><string>${REPO_ROOT}/.juvant/logs/governance-backfill.err</string>
</dict>
</plist>
PLIST

        # anomaly-check — every 15 minutes
        cat > "$LAUNCHD_DIR/${PREFIX}.anomaly-check.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${PREFIX}.anomaly-check</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${REPO_ROOT}/helpers/anomaly-check.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${_PLIST_HOME}</string>
    <key>PATH</key><string>${_PLIST_PATH}</string>
  </dict>
$(_every_minutes_xml 15)
  <key>StandardOutPath</key><string>${REPO_ROOT}/.juvant/logs/anomaly-check.log</string>
  <key>StandardErrorPath</key><string>${REPO_ROOT}/.juvant/logs/anomaly-check.err</string>
</dict>
</plist>
PLIST

        # FEAT-007 Helper 1 — morning-brief — daily 08:00 local
        cat > "$LAUNCHD_DIR/${PREFIX}.morning-brief.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${PREFIX}.morning-brief</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${REPO_ROOT}/helpers/morning-brief.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${_PLIST_HOME}</string>
    <key>PATH</key><string>${_PLIST_PATH}</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>8</integer>
    <key>Minute</key><integer>0</integer>
  </dict>
  <key>StandardOutPath</key><string>${REPO_ROOT}/.juvant/logs/morning-brief.log</string>
  <key>StandardErrorPath</key><string>${REPO_ROOT}/.juvant/logs/morning-brief.err</string>
</dict>
</plist>
PLIST

        # CSO weekly audit cadence — Sunday 22:00 local
        cat > "$LAUNCHD_DIR/${PREFIX}.cso-weekly-audit.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${PREFIX}.cso-weekly-audit</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${REPO_ROOT}/helpers/cso-weekly-audit.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${_PLIST_HOME}</string>
    <key>PATH</key><string>${_PLIST_PATH}</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key><integer>0</integer>
    <key>Hour</key><integer>22</integer>
    <key>Minute</key><integer>0</integer>
  </dict>
  <key>StandardOutPath</key><string>${REPO_ROOT}/.juvant/logs/cso-weekly-audit.log</string>
  <key>StandardErrorPath</key><string>${REPO_ROOT}/.juvant/logs/cso-weekly-audit.err</string>
</dict>
</plist>
PLIST

        # FEAT-051: drain-audit-spool — every 5 minutes. SessionStart
        # already drains in the background on each new session; this
        # periodic job flushes the spool during long-running sessions so
        # the audit log stays near-current.
        cat > "$LAUNCHD_DIR/${PREFIX}.drain-audit-spool.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${PREFIX}.drain-audit-spool</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${REPO_ROOT}/helpers/drain-audit-spool.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${_PLIST_HOME}</string>
    <key>PATH</key><string>${_PLIST_PATH}</string>
  </dict>
$(_every_minutes_xml 5)
  <key>StandardOutPath</key><string>${REPO_ROOT}/.juvant/logs/drain-audit-spool.log</string>
  <key>StandardErrorPath</key><string>${REPO_ROOT}/.juvant/logs/drain-audit-spool.err</string>
</dict>
</plist>
PLIST

        # ADR 0024: drain-outbox — every 15 minutes. Surfaces outbox rows
        # that are approved and due so a staged backlog never sits silent
        # (the morning brief / notifications consume this). Dispatch itself
        # is agent-mediated (CoS) in v1.0; this job only reads and reports.
        cat > "$LAUNCHD_DIR/${PREFIX}.drain-outbox.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${PREFIX}.drain-outbox</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${REPO_ROOT}/helpers/drain-outbox.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${_PLIST_HOME}</string>
    <key>PATH</key><string>${_PLIST_PATH}</string>
  </dict>
$(_every_minutes_xml 15)
  <key>StandardOutPath</key><string>${REPO_ROOT}/.juvant/logs/drain-outbox.log</string>
  <key>StandardErrorPath</key><string>${REPO_ROOT}/.juvant/logs/drain-outbox.err</string>
</dict>
</plist>
PLIST

        mkdir -p "${REPO_ROOT}/.juvant/logs"

        for label in $ALL_LABELS; do
          target="$DOMAIN/${PREFIX}.${label}"
          "$LAUNCHCTL" bootout "$target" 2>/dev/null || true
          # bootout is asynchronous: wait (bounded, ~5s) until the old
          # instance is gone, so bootstrap never races a half-removed job.
          _w=0
          while "$LAUNCHCTL" print "$target" >/dev/null 2>&1 && [ "$_w" -lt 50 ]; do
            sleep 0.1
            _w=$((_w + 1))
          done
          # Clear any persistent "disabled" override (launchctl disable /
          # Login Items toggle) — a disabled job bootstraps but never fires.
          "$LAUNCHCTL" enable "$target" 2>/dev/null || true
          "$LAUNCHCTL" bootstrap "$DOMAIN" "$LAUNCHD_DIR/${PREFIX}.${label}.plist"
          echo "[install-schedules] loaded ${PREFIX}.${label}"
        done
        echo "[install-schedules] OK — Mac launchd schedules installed (8 jobs)."

        _selfcheck="${JUVANT_SCHED_SELFCHECK:-}"
        if [ -z "$_selfcheck" ]; then
          if [ "${CI:-}" = "true" ]; then _selfcheck=0; else _selfcheck=1; fi
        fi
        if [ "$_selfcheck" = "1" ]; then
          if ! _selfcheck_interval_jobs; then
            echo "[install-schedules] FATAL: post-install self-check failed — one or more 'every N minutes' jobs is not running under launchd (decisions#300 item 14). Set JUVANT_SCHED_SELFCHECK=0 to skip." >&2
            exit 1
          fi
          echo "[install-schedules] OK — post-install self-check passed."
        else
          echo "[install-schedules] post-install self-check skipped (JUVANT_SCHED_SELFCHECK=0 or CI)."
        fi
        ;;

      uninstall|--uninstall)
        for label in $ALL_LABELS; do
          "$LAUNCHCTL" bootout "$DOMAIN/${PREFIX}.${label}" 2>/dev/null || true
          rm -f "$LAUNCHD_DIR/${PREFIX}.${label}.plist"
          echo "[install-schedules] removed ${PREFIX}.${label}"
        done
        echo "[install-schedules] OK — Mac launchd schedules uninstalled."
        ;;

      *)
        echo "Usage: $0 [install|uninstall]" >&2
        exit 2
        ;;
    esac
    ;;

  Linux)
    CRON_TAG="# JUVANT-GUARDRAILS"

    case "$ACTION" in
      install|--install)
        # Strip any existing JUVANT-GUARDRAILS lines, then append fresh
        TMP=$(mktemp)
        crontab -l 2>/dev/null | grep -v "$CRON_TAG" > "$TMP" || true
        cat >> "$TMP" <<CRON
0 3 * * *    /bin/bash ${REPO_ROOT}/helpers/turso-backup.sh         >> ${REPO_ROOT}/.juvant/logs/turso-backup.log 2>&1          $CRON_TAG
0 3 * * 6    /bin/bash ${REPO_ROOT}/helpers/audit-reconcile.sh    >> ${REPO_ROOT}/.juvant/logs/audit-reconcile.log 2>&1       $CRON_TAG
0 4 1 * *    /bin/bash ${REPO_ROOT}/scripts/governance-backfill.sh --dry-run --all >> ${REPO_ROOT}/.juvant/logs/governance-backfill.log 2>&1 $CRON_TAG
*/15 * * * * /bin/bash ${REPO_ROOT}/helpers/anomaly-check.sh      >> ${REPO_ROOT}/.juvant/logs/anomaly-check.log 2>&1         $CRON_TAG
0 8 * * *    /bin/bash ${REPO_ROOT}/helpers/morning-brief.sh      >> ${REPO_ROOT}/.juvant/logs/morning-brief.log 2>&1         $CRON_TAG
0 22 * * 0   /bin/bash ${REPO_ROOT}/helpers/cso-weekly-audit.sh   >> ${REPO_ROOT}/.juvant/logs/cso-weekly-audit.log 2>&1      $CRON_TAG
*/5 * * * *  /bin/bash ${REPO_ROOT}/helpers/drain-audit-spool.sh  >> ${REPO_ROOT}/.juvant/logs/drain-audit-spool.log 2>&1     $CRON_TAG
*/15 * * * * /bin/bash ${REPO_ROOT}/helpers/drain-outbox.sh       >> ${REPO_ROOT}/.juvant/logs/drain-outbox.log 2>&1          $CRON_TAG
CRON
        mkdir -p "${REPO_ROOT}/.juvant/logs"
        crontab "$TMP"
        rm -f "$TMP"
        echo "[install-schedules] OK — Linux cron entries installed (8 jobs tagged $CRON_TAG)."
        ;;

      uninstall|--uninstall)
        TMP=$(mktemp)
        crontab -l 2>/dev/null | grep -v "$CRON_TAG" > "$TMP" || true
        crontab "$TMP"
        rm -f "$TMP"
        echo "[install-schedules] OK — Linux cron entries removed."
        ;;
    esac
    ;;

  MINGW*|MSYS*|CYGWIN*)
    cat >&2 <<'WINMSG'
[install-schedules] Windows-native (Git Bash / MSYS / Cygwin) is not
supported for scheduling in v1.0.

The hooks themselves (hooks/*.sh) work fine here — they only need
bash on PATH, which Git Bash provides. What doesn't work in this
shell is launchd (Mac-only) and Unix crontab (Unix-only). Native
Windows Task Scheduler integration is tracked as a v1.1+ open point
(see juvant-os-pm OP for "Native Windows Task Scheduler integration").

Recommended path for Windows users:

  1. Install WSL2 + Ubuntu:
       wsl --install -d Ubuntu
  2. Open the WSL shell, clone the per-company repo there.
  3. Run `./helpers/install-schedules.sh` from WSL — it'll install
     Linux cron entries that fire even when you're working in Windows
     (WSL2 background services run on the lightweight VM).

If you must stay on Git Bash (no WSL), you can manually create
Windows Task Scheduler entries pointing at:
  - C:\\path\\to\\Git\\bin\\bash.exe
  - $REPO_ROOT/helpers/<helper>.sh
For each of the 8 scheduled jobs (turso-backup daily 03:00,
audit-reconcile weekly Sat 03:00, governance-backfill monthly day-1 04:00,
anomaly-check every 15 min, morning-brief daily 08:00,
cso-weekly-audit weekly Sun 22:00, drain-audit-spool every 5 min,
drain-outbox every 15 min) — the same set the launchd/cron paths install.
The hooks themselves run independently of these schedules.
fiscal-deadlines.sh is available as an on-demand helper but is not scheduled.
WINMSG
    exit 1
    ;;

  *)
    echo "[install-schedules] FATAL: unsupported OS '$OS'. v1.0 supports Darwin (launchd) + Linux (cron) + Windows via WSL2 (cron)." >&2
    exit 1
    ;;
esac
