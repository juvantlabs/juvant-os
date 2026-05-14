#!/usr/bin/env bash
# helpers/install-schedules.sh
# Installs launchd plists (Mac) or cron entries (Linux) for the
# guardrail helpers per handbook ADR 0004 Track 3 + Track 4.
#
# Schedules:
#   helpers/turso-backup.sh     — daily 03:00
#   helpers/audit-reconcile.sh  — weekly Saturday 03:00
#   helpers/anomaly-check.sh    — every 15 min
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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ACTION="${1:-install}"

OS=$(uname -s)

case "$OS" in
  Darwin)
    LAUNCHD_DIR="$HOME/Library/LaunchAgents"
    PREFIX="io.juvant.guardrails"

    case "$ACTION" in
      install|--install)
        mkdir -p "$LAUNCHD_DIR"

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

        # audit-reconcile — weekly Saturday 03:00 (weekday 7 = Saturday in launchd)
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
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key><integer>7</integer>
    <key>Hour</key><integer>3</integer>
    <key>Minute</key><integer>0</integer>
  </dict>
  <key>StandardOutPath</key><string>${REPO_ROOT}/.juvant/logs/audit-reconcile.log</string>
  <key>StandardErrorPath</key><string>${REPO_ROOT}/.juvant/logs/audit-reconcile.err</string>
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
  <key>StartInterval</key><integer>900</integer>
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

        mkdir -p "${REPO_ROOT}/.juvant/logs"

        for label in turso-backup audit-reconcile anomaly-check morning-brief; do
          launchctl bootout "gui/$(id -u)/${PREFIX}.${label}" 2>/dev/null || true
          launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_DIR/${PREFIX}.${label}.plist"
          echo "[install-schedules] loaded ${PREFIX}.${label}"
        done
        echo "[install-schedules] OK — Mac launchd schedules installed (4 jobs)."
        ;;

      uninstall|--uninstall)
        for label in turso-backup audit-reconcile anomaly-check morning-brief; do
          launchctl bootout "gui/$(id -u)/${PREFIX}.${label}" 2>/dev/null || true
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
0 3 * * *    /bin/bash ${REPO_ROOT}/helpers/turso-backup.sh      >> ${REPO_ROOT}/.juvant/logs/turso-backup.log 2>&1       $CRON_TAG
0 3 * * 6    /bin/bash ${REPO_ROOT}/helpers/audit-reconcile.sh   >> ${REPO_ROOT}/.juvant/logs/audit-reconcile.log 2>&1    $CRON_TAG
*/15 * * * * /bin/bash ${REPO_ROOT}/helpers/anomaly-check.sh     >> ${REPO_ROOT}/.juvant/logs/anomaly-check.log 2>&1      $CRON_TAG
0 8 * * *    /bin/bash ${REPO_ROOT}/helpers/morning-brief.sh     >> ${REPO_ROOT}/.juvant/logs/morning-brief.log 2>&1      $CRON_TAG
CRON
        mkdir -p "${REPO_ROOT}/.juvant/logs"
        crontab "$TMP"
        rm -f "$TMP"
        echo "[install-schedules] OK — Linux cron entries installed (3 jobs tagged $CRON_TAG)."
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
For each of the 4 helpers (turso-backup daily 03:00,
audit-reconcile weekly Sat 03:00, anomaly-check every 15 min,
morning-brief daily 08:00). The hooks themselves run independently
of these schedules. fiscal-deadlines.sh is available as an on-demand
helper but is not scheduled.
WINMSG
    exit 1
    ;;

  *)
    echo "[install-schedules] FATAL: unsupported OS '$OS'. v1.0 supports Darwin (launchd) + Linux (cron) + Windows via WSL2 (cron)." >&2
    exit 1
    ;;
esac
