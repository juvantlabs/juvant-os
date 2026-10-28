#!/usr/bin/env bash
# helpers/drain-audit-spool.sh
# FEAT-051 — drain the local audit spool to the database out-of-band.
#
# pre-tool-use.sh / post-tool-use.sh append Track-3 audit statements to
# .juvant/audit-spool.sql via juvant_db_exec_async (a local, network-free,
# hang-impossible append) instead of executing them on the tool gating
# path. This drainer flushes the spool to the configured backend (Turso /
# Local SQLite) where the audit log (agent_actions_log) actually lives.
#
# Ordering: the spool is append-only and drained in file order, so a
# pre-tool-use INSERT ('pending') is always applied before the matching
# post-tool-use UPDATE that finalizes it.
#
# Self-bootstrapping: launched in the background from session-start.sh on
# every session start, so the spool flushes without requiring cron. Also
# registered in helpers/install-schedules.sh for long-running sessions.
#
# Crash-safety: the current spool is atomically claimed (renamed) before
# draining, so writers starting a fresh spool never race the drain.
# Statements are applied one at a time, in order; on failure only the
# UNAPPLIED tail is re-queued ahead of any new appends — nothing is lost,
# nothing is applied twice (so no duplicate audit rows on a mid-batch
# failure), and a flaky/offline backend simply defers the remainder to the
# next run (eventual consistency; Track-3 is forensic, not real-time).

set -euo pipefail

# launchd / cron provide a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin) —
# APPEND the Homebrew dirs so turso/jq are found there, without shadowing
# a turso the caller deliberately put first on PATH (e.g. the fake-turso
# shim in tests/hooks/run-tests.sh). Append, not prepend, on purpose.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# db.sh expects SCRIPT_DIR to point at the hooks dir for path resolution.
SCRIPT_DIR="$REPO_ROOT/hooks"
# shellcheck disable=SC1091
. "$REPO_ROOT/hooks/lib/db.sh"
# Disable juvant_db_exec's own spool fallback: this script is the drain and
# is the single source of re-queueing (REMAINING+merge). Two spoolers on the
# same statement produce duplicate audit rows — the invariant this script is
# designed to prevent.
export JUVANT_DB_EXEC_NO_SPOOL=1

# Single source of truth for the spool path (honors JUVANT_SPOOL).
SPOOL="$(juvant_spool_path)"

# ── decisions#298 (L1-F1): re-claim stranded batches ─────────────────────────
# A drain killed mid-loop (sleep, SIGKILL, session exit) leaves its claimed
# batch behind as "$SPOOL.draining.<pid>" (or "$SPOOL.merge.<pid>" if killed
# while re-queueing). Nothing ever claimed those names again, so the audit
# rows inside were silently stranded. Every run now looks for them first.
#
# A file is STALE when its owner pid is gone (a live drain's file is never
# touched) or when it is older than DRAIN_STALE_MAX_AGE_MIN (default 60) — a
# drain that long is stuck, and a recycled pid must not shelter a file forever.
# Stale files are applied BEFORE the live spool (they are older; file order is
# audit order) with an idempotence guard (see _guard_reclaimed) because a killed
# drain may already have committed part of its batch.
_STALE_MAX_AGE_MIN="${DRAIN_STALE_MAX_AGE_MIN:-60}"
_stale_files() {
  local _f _pid
  for _f in "$SPOOL".draining.* "$SPOOL".merge.*; do
    [[ -f "$_f" ]] || continue
    _pid="${_f##*.}"
    [[ "$_pid" =~ ^[0-9]+$ ]] || continue
    [[ "$_pid" == "$$" ]] && continue
    if kill -0 "$_pid" 2>/dev/null; then
      # Owner alive: only stale if older than the max age.
      [[ -n "$(find "$_f" -mmin "+$_STALE_MAX_AGE_MIN" 2>/dev/null)" ]] || continue
    fi
    printf '%s\n' "$_f"
  done
}
STALE_LIST="$(_stale_files)"

# Nothing spooled and nothing stranded — no-op (fast, common path).
[[ -s "$SPOOL" || -n "$STALE_LIST" ]] || exit 0

juvant_db_resolve
if [[ -z "$JUVANT_DB_PROVIDER" ]]; then
  echo "[drain-audit-spool] WARN: no db.provider configured; leaving spool intact" >&2
  exit 0
fi

# Rewrite one spooled agent_actions_log INSERT into an idempotent form, so that
# replaying a batch that was partially applied before the drain died does not
# duplicate rows. Key: session_id + agent + tool_name + args_hash, plus the
# explicit started_at when the row carries one (rows written since decisions#298
# do, which makes the key exact). Legacy rows without started_at are keyed
# without time, so a legitimately repeated identical command in the SAME session
# can be collapsed — a deliberate bias toward "no duplicate audit rows" for
# batches that are already known-damaged. Anything not matching the expected
# shape (UPDATEs are idempotent; other statements) is passed through unchanged.
_guard_reclaimed() {
  local _s="$1"
  local _re_stmt='^INSERT INTO agent_actions_log[[:space:]]*\(([^)]*)\)[[:space:]]*VALUES[[:space:]]*\((.*)\);[[:space:]]*$'
  local _re_key="^'([^']*)', '([^']*)', '([^']*)', '([0-9a-f]{64})', '"
  local _re_ts="'([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})'(, [0-9]+)?\$"
  local _cols _vals _key
  if [[ "$_s" =~ $_re_stmt ]]; then
    _cols="${BASH_REMATCH[1]}"; _vals="${BASH_REMATCH[2]}"
    if [[ "$_vals" =~ $_re_key ]]; then
      _key="session_id='${BASH_REMATCH[1]}' AND agent='${BASH_REMATCH[2]}' AND tool_name='${BASH_REMATCH[3]}' AND args_hash='${BASH_REMATCH[4]}'"
      if [[ "$_cols" == *started_at* && "$_vals" =~ $_re_ts ]]; then
        _key="$_key AND started_at='${BASH_REMATCH[1]}'"
      fi
      printf 'INSERT INTO agent_actions_log (%s) SELECT %s WHERE NOT EXISTS (SELECT 1 FROM agent_actions_log WHERE %s);' \
        "$_cols" "$_vals" "$_key"
      return 0
    fi
  fi
  printf '%s' "$_s"
}

# Apply one stranded batch. Statements already in the DB are skipped by the
# guard; an unapplied tail (backend failure) is re-queued ahead of the live
# spool, exactly like the main path. The original is copied aside first and
# removed only once every statement is applied or safely re-queued.
# Returns 0 if the batch was fully applied, 1 if a tail was re-queued.
_reclaim_one() {
  local _f="$1" _stmt _a=0 _failed=0 _rem="" _mt _age_min=0
  _mt=$(stat -f %m "$_f" 2>/dev/null || stat -c %Y "$_f" 2>/dev/null || echo 0)
  [[ "$_mt" =~ ^[0-9]+$ && "$_mt" -gt 0 ]] && _age_min=$(( ( $(date +%s) - _mt ) / 60 ))
  echo "[drain-audit-spool] WARN: re-claiming stranded batch $(basename "$_f") (age ${_age_min}m, $(grep -c . "$_f" || true) statement(s))" >&2
  local _kdir="${JUVANT_BACKUP_DIR:-$(dirname "$SPOOL")/backups}"
  if mkdir -p "$_kdir" 2>/dev/null; then
    cp "$_f" "$_kdir/audit-stale.$(date -u +%Y%m%dT%H%M%SZ).$(basename "$_f").sql" 2>/dev/null || {
      echo "[drain-audit-spool] WARN: could not preserve $(basename "$_f"); leaving it in place" >&2
      return 1
    }
  else
    echo "[drain-audit-spool] WARN: cannot create backup dir $_kdir; leaving $(basename "$_f") in place" >&2
    return 1
  fi
  while IFS= read -r _stmt || [[ -n "$_stmt" ]]; do
    [[ -z "$_stmt" ]] && continue
    if [[ "$_failed" -eq 1 ]]; then _rem+="$_stmt"$'\n'; continue; fi
    if juvant_db_exec "$(_guard_reclaimed "$_stmt")"; then
      _a=$(( _a + 1 ))
    else
      _failed=1; _rem+="$_stmt"$'\n'
    fi
  done < "$_f"
  if [[ "$_failed" -eq 1 ]]; then
    if [[ -s "$SPOOL" ]]; then
      { printf '%s' "$_rem"; cat "$SPOOL"; } > "$SPOOL.reclaim.$$" && mv "$SPOOL.reclaim.$$" "$SPOOL"
    else
      printf '%s' "$_rem" > "$SPOOL"
    fi
    rm -f "$_f"
    echo "[drain-audit-spool] WARN: stranded batch applied $_a then failed; $(printf '%s' "$_rem" | grep -c . || true) statement(s) re-queued" >&2
    return 1
  fi
  rm -f "$_f"
  echo "[drain-audit-spool] reclaimed $(basename "$_f"): $_a statement(s) applied (duplicates skipped)"
  return 0
}

_RECLAIM_FAILED=0
if [[ -n "$STALE_LIST" ]]; then
  while IFS= read -r _sf; do
    [[ -z "$_sf" ]] && continue
    _reclaim_one "$_sf" || { _RECLAIM_FAILED=1; break; }
  done <<< "$STALE_LIST"
  # Keep the preserved copies bounded (newest 20).
  # shellcheck disable=SC2012
  ls -1t "${JUVANT_BACKUP_DIR:-$(dirname "$SPOOL")/backups}"/audit-stale.*.sql 2>/dev/null \
    | tail -n +21 | while IFS= read -r _old; do rm -f "$_old"; done
fi
# Backend failed while reclaiming: the tail is re-queued; stop here, retry next run.
[[ "$_RECLAIM_FAILED" -eq 0 ]] || exit 1
# Reclaim may have been the only work (live spool empty).
[[ -s "$SPOOL" ]] || exit 0

# Pre-drain backup: timestamped copy before the atomic rename so that a
# mid-drain failure (SIGKILL, disk-full on apply, hung backend) leaves a
# recoverable snapshot.  Fail-closed: if the backup directory cannot be
# created, the copy fails, or the integrity check fails, leave the spool
# intact and defer to the next run rather than risking silent loss of
# queued audit rows.  Override JUVANT_BACKUP_DIR to redirect backups
# (useful in tests).  Override DRAIN_BACKUP_RETAIN to change the
# retention window (default: 7 most-recent backups).
_BACKUP_DIR="${JUVANT_BACKUP_DIR:-$(dirname "$SPOOL")/backups}"
mkdir -p "$_BACKUP_DIR" 2>/dev/null || {
  echo "[drain-audit-spool] WARN: cannot create backup dir $_BACKUP_DIR; aborting drain" >&2
  exit 0
}
_BACKUP="$_BACKUP_DIR/audit-spool.$(date -u +%Y%m%dT%H%M%SZ).sql"
cp "$SPOOL" "$_BACKUP" 2>/dev/null || {
  echo "[drain-audit-spool] WARN: backup failed ($SPOOL → $_BACKUP); aborting drain" >&2
  exit 0
}
# Integrity check: line counts of source and backup must agree.
# tr strips the leading whitespace that BSD/macOS wc -l pads into its output.
_SRC_LINES=$(wc -l < "$SPOOL"    | tr -d '[:space:]')
_BAK_LINES=$(wc -l < "$_BACKUP"  | tr -d '[:space:]')
if [[ "$_SRC_LINES" -ne "$_BAK_LINES" ]]; then
  echo "[drain-audit-spool] WARN: backup integrity check failed (src=${_SRC_LINES} bak=${_BAK_LINES}); aborting drain" >&2
  rm -f "$_BACKUP"
  exit 0
fi
# Retention prune: keep the most-recent N backups; delete anything older.
_BACKUP_RETAIN="${DRAIN_BACKUP_RETAIN:-7}"
# ls -1t lists newest-first; tail skips the N we keep and feeds the rest to rm.
# shellcheck disable=SC2012
ls -1t "$_BACKUP_DIR"/audit-spool.*.sql 2>/dev/null \
  | tail -n "+$(( _BACKUP_RETAIN + 1 ))" \
  | while IFS= read -r _old; do rm -f "$_old"; done

# Atomically claim the current batch so concurrent writers (which open the
# spool fresh per append) start a new file instead of racing the drain.
WORK="$SPOOL.draining.$$"
mv "$SPOOL" "$WORK" 2>/dev/null || exit 0

# Apply the claimed batch one statement per line, in order. The async
# writer (juvant_db_exec_async) collapses every statement to a single
# physical line, so a line == a statement. Incremental apply is what makes
# a PARTIAL failure safe: if the backend drops after N statements have
# already auto-committed, the old single-stream path re-queued the WHOLE
# batch — re-applying those N already-committed INSERTs on the next run and
# DUPLICATING those audit rows. Here only the unapplied tail is re-queued.
APPLIED=0
FAILED=0
REMAINING=""
while IFS= read -r _stmt || [[ -n "$_stmt" ]]; do
  [[ -z "$_stmt" ]] && continue
  if [[ "$FAILED" -eq 1 ]]; then
    REMAINING+="$_stmt"$'\n'           # already failed — defer the rest in order
    continue
  fi
  if juvant_db_exec "$_stmt"; then
    APPLIED=$(( APPLIED + 1 ))
  else
    FAILED=1
    REMAINING+="$_stmt"$'\n'
  fi
done < "$WORK"
rm -f "$WORK"

if [[ "$FAILED" -eq 0 ]]; then
  echo "[drain-audit-spool] drained $APPLIED statement(s) to $JUVANT_DB_PROVIDER"

  # BUG-052: finalize orphaned 'pending' rows the PostToolUse UPDATE never
  # closed. Two sources: (1) async / fire-and-forget tools (SendMessage,
  # ExitPlanMode) for which Claude Code emits no synchronous PostToolUse, so
  # the finalizing UPDATE in post-tool-use.sh never matches; (2) spool
  # tail-loss on SIGKILL / hook-timeout. This reconcile runs HERE — right after
  # a successful drain, the one point where every spooled INSERT ('pending')
  # and UPDATE ('success'/'failure') is in the DB and true orphans are visible.
  # It deliberately does NOT live in session-end.sh / subagent-stop.sh: there
  # the current session's audit rows are still in the spool (drained only at
  # the NEXT session-start), so a DB sweep there would miss exactly the rows it
  # must close. Threshold 1h == audit-reconcile's stuck-pending definition and
  # is far longer than any real in-flight tool call, so a live action of the
  # just-started session is never swept. (Edge case: a concurrent session with
  # a genuine >1h in-flight action would be marked 'terminated'; benign — this
  # is forensic telemetry, and a late PostToolUse UPDATE simply no-ops against
  # the already-closed row since it targets status='pending'.)
  _NOW=$(date -u +"%Y-%m-%d %H:%M:%S")
  juvant_db_exec "UPDATE agent_actions_log
    SET status='terminated', ended_at='$_NOW'
    WHERE status='pending'
      AND started_at < datetime('now','-1 hour');" \
    || echo "[drain-audit-spool] WARN: orphaned-pending reconcile failed" >&2

  exit 0
fi

# Re-queue ONLY the unapplied tail, ahead of any rows appended while we were
# draining, preserving order. The $APPLIED already-committed statements are
# not re-queued → no duplicate audit rows.
_REQ=$(printf '%s' "$REMAINING" | grep -c . || true)
if [[ -s "$SPOOL" ]]; then
  { printf '%s' "$REMAINING"; cat "$SPOOL"; } > "$SPOOL.merge.$$" && mv "$SPOOL.merge.$$" "$SPOOL"
else
  printf '%s' "$REMAINING" > "$SPOOL"
fi
echo "[drain-audit-spool] WARN: drain failed after $APPLIED applied; ${_REQ} statement(s) re-queued for next run" >&2
exit 1
