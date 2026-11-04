#!/usr/bin/env bash
# helpers/download-cache-sweep.sh
# FEAT-068 (juvantlabs/juvant-os-pm#205) — retention for the plaintext files
# the m365-graph and m365-mail MCP servers leave in their download sandboxes.
# Runs daily (helpers/install-schedules.sh). Agents can't do this: `rm` is not
# on their allow-lists.
#
# What is deleted: regular files older than N days, only where the servers
# write them and only with the shape they give them:
#   <root>/<tenant-id>/<16 hex chars>-<name>
# A root pointed at the wrong directory therefore finds nothing to delete.
# Symlinks are never followed, roots and tenant directories are never removed,
# and age is mtime, so a file downloaded again stays.
#
# Roots:
#   ~/.cache/m365-graph-mcp-server, ~/.cache/m365-mail-mcp-server (defaults)
#   plus .juvant/config.json `retention.download_roots`, an array.
# A scheduled job gets only HOME and PATH, so it can't see M365_DOWNLOAD_DIR,
# M365_MAIL_DOWNLOAD_DIR or XDG_CACHE_HOME from the MCP launch config: an
# instance that sets one declares the resulting root here. For an env override
# the root is the override itself; for XDG_CACHE_HOME it is
# <XDG_CACHE_HOME>/m365-graph-mcp-server (and the m365-mail one).
# config.json is agent-writable, so a root must be an absolute path under
# $HOME, not $HOME itself, and not a symlink.
#
# N: .juvant/config.json `retention.download_days`, default 7. Clamped to 1–30,
# so a config edit can neither wipe the current session's files nor turn
# retention off.
#
# The log holds the run id and counts only, never a file name or a path: names
# are sensitive (counterparties, people, contract titles). find's own stderr
# carries paths, so it is counted and discarded.
#
# Usage: bash helpers/download-cache-sweep.sh [--dry-run]
# Exit: 0 = clean run (a default root that doesn't exist is not an error);
#       1 = a root was refused or a delete failed; a messages row tells CoS;
#       2 = usage error.

set -euo pipefail
export LC_ALL=C

# launchd / cron provide a minimal PATH — APPEND Homebrew dirs (mirrors
# helpers/cso-weekly-audit.sh) without shadowing a test-shimmed CLI.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${JUVANT_CONFIG:-$SCRIPT_DIR/../.juvant/config.json}"
TAG="[download-cache-sweep]"
DEFAULT_DAYS=7; MIN_DAYS=1; MAX_DAYS=30
# <16 hex chars>-<name>, the servers' own filename shape.
HEX='[0-9a-f]'
SHAPE="$HEX$HEX$HEX$HEX$HEX$HEX$HEX$HEX$HEX$HEX$HEX$HEX$HEX$HEX$HEX$HEX-*"

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
  *) echo "$TAG unknown argument: $1" >&2; exit 2 ;;
esac

if [[ -z "${HOME:-}" || "$HOME" != /* || ! -d "$HOME" ]]; then
  echo "$TAG FATAL: HOME is not a directory" >&2; exit 1
fi
HOME_REAL="$(cd -P "$HOME" && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"

# BUG-027: run-ID stamp + prune the log to the last 30 runs.
_LOG="$SCRIPT_DIR/../.juvant/logs/download-cache-sweep.log"
if [[ -f "$_LOG" ]]; then
  _total=$(grep -c '^=== RUN ' "$_LOG" 2>/dev/null || true)
  if [[ "${_total:-0}" -gt 30 ]]; then
    _skip=$(( _total - 30 ))
    awk -v skip="$_skip" '/^=== RUN /{n++} n>skip{print}' \
      "$_LOG" > "${_LOG}.tmp" && cat "${_LOG}.tmp" > "$_LOG" && rm -f "${_LOG}.tmp"
  fi
fi
if [[ -d "$(dirname "$_LOG")" ]]; then
  echo "=== RUN $RUN_ID ===" >> "$_LOG"
fi

# ── Retention window ─────────────────────────────────────────────────────────
DAYS=$(jq -r '.retention.download_days // empty' "$CONFIG" 2>/dev/null || true)
if [[ -z "$DAYS" ]]; then
  DAYS=$DEFAULT_DAYS
elif [[ ! "$DAYS" =~ ^[0-9]{1,6}$ ]]; then
  echo "$TAG WARN: retention.download_days is not a number — using $DEFAULT_DAYS" >&2
  DAYS=$DEFAULT_DAYS
else
  DAYS=$((10#$DAYS))
  if (( DAYS < MIN_DAYS || DAYS > MAX_DAYS )); then
    (( DAYS < MIN_DAYS )) && _clamped=$MIN_DAYS || _clamped=$MAX_DAYS
    echo "$TAG WARN: retention.download_days is outside $MIN_DAYS–$MAX_DAYS — using $_clamped" >&2
    DAYS=$_clamped
  fi
fi

# ── Sweep ────────────────────────────────────────────────────────────────────
DELETED=0; ERRORS=0; REFUSED=0; SWEPT=0
ERRF=$(mktemp "${TMPDIR:-/tmp}/juvant-sweep.XXXXXX")
trap 'rm -f "$ERRF"' EXIT

_sweep() {   # <root>
  local root="$1" n rc=0 e
  local -a action=(-print0)
  (( DRY_RUN )) || action=(-delete -print0)
  : > "$ERRF"
  n=$(find -P "$root" -mindepth 2 -maxdepth 2 -xdev -type f -name "$SHAPE" \
        -mmin "+$((DAYS * 1440))" "${action[@]}" 2>"$ERRF" | tr -dc '\000' | wc -c) || rc=$?
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  DELETED=$((DELETED + ${n:-0}))
  SWEPT=$((SWEPT + 1))
  e=$(grep -c . "$ERRF" 2>/dev/null || true)
  if (( rc != 0 || ${e:-0} > 0 )); then ERRORS=$((ERRORS + ${e:-0} + (e == 0 ? 1 : 0))); fi
}

for _d in m365-graph-mcp-server m365-mail-mcp-server; do
  _root="$HOME_REAL/.cache/$_d"
  [[ -L "$_root" ]] && { echo "$TAG WARN: default root is a symlink — refused" >&2; REFUSED=$((REFUSED + 1)); continue; }
  [[ -d "$_root" ]] || continue
  _sweep "$_root"
done

_i=0
_type=$(jq -r '.retention.download_roots | type' "$CONFIG" 2>/dev/null || echo null)
if [[ "$_type" == "array" ]]; then
  while IFS= read -r _b64; do
    _i=$((_i + 1))
    _root=$(printf '%s' "$_b64" | base64 --decode 2>/dev/null || true)
    _why=""
    case "$_root" in
      "")      _why="empty" ;;
      /*)      ;;
      *)       _why="not absolute" ;;
    esac
    if [[ -z "$_why" ]]; then
      [[ "$_root" == "/" ]] || _root="${_root%/}"
      if [[ -L "$_root" ]]; then
        _why="a symlink"
      elif [[ ! -d "$_root" ]]; then
        _real=""
        [[ -e "$_root" ]] && _why="not a directory"
      else
        _real="$(cd -P "$_root" 2>/dev/null && pwd)" || _real=""
        if [[ -z "$_real" ]]; then _why="unreadable"
        elif [[ "$_real" == "$HOME_REAL" ]]; then _why="the home directory"
        elif [[ "$_real" != "$HOME_REAL"/* ]]; then _why="outside the home directory"
        fi
      fi
    fi
    if [[ -n "$_why" ]]; then
      echo "$TAG WARN: retention.download_roots[$((_i - 1))] refused: $_why" >&2
      REFUSED=$((REFUSED + 1))
      continue
    fi
    # A declared root that doesn't exist yet: the server hasn't written there.
    [[ -n "${_real:-}" ]] || continue
    _sweep "$_real"
  done < <(jq -r '.retention.download_roots[] | (if type == "string" then . else "" end) | @base64' "$CONFIG" 2>/dev/null || true)
elif [[ "$_type" != "null" ]]; then
  echo "$TAG WARN: retention.download_roots is not an array" >&2
  REFUSED=$((REFUSED + 1))
fi

_verb="deleted"; (( DRY_RUN )) && _verb="would_delete"
echo "$TAG run=$RUN_ID days=$DAYS roots=$SWEPT $_verb=$DELETED errors=$ERRORS refused=$REFUSED"

if (( ERRORS == 0 && REFUSED == 0 )); then exit 0; fi

# ── Fail loud: a log nobody reads is not loud. Counts only; one row a day. ───
echo "$TAG FAILED: errors=$ERRORS refused=$REFUSED" >&2
(( DRY_RUN )) && exit 1
if [[ -f "$SCRIPT_DIR/../hooks/lib/db.sh" ]]; then
  export JUVANT_CONFIG="$CONFIG"
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/../hooks/lib/db.sh"
  juvant_db_resolve || true
  if [[ -n "${JUVANT_DB_PROVIDER:-}" ]]; then
    REF_ID="download-cache-sweep-fail-${RUN_ID:0:8}"
    _seen=$(juvant_db_query "SELECT COUNT(*) FROM messages WHERE ref_id='${REF_ID}';" 2>/dev/null | { grep -E '^[0-9]+$' || true; } | tail -1) || _seen=""
    if [[ "${_seen:-0}" == "0" ]]; then
      _msg="Download cache sweep failed (run ${RUN_ID}): ${ERRORS} delete error(s), ${REFUSED} refused root(s). Plaintext downloads may be kept past retention. Details in .juvant/logs/download-cache-sweep.err."
      JUVANT_DB_EXEC_NO_SPOOL=1 juvant_db_exec "INSERT INTO messages (from_agent, to_agent, type, content, priority, notify_ceo, ref_id) VALUES ('download-cache-sweep', 'cos', 'escalation', '${_msg}', 'high', 1, '${REF_ID}');" \
        || echo "$TAG WARN: could not write the messages row" >&2
    fi
  fi
fi
exit 1
