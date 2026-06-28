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

# Single source of truth for the spool path (honors JUVANT_SPOOL).
SPOOL="$(juvant_spool_path)"

# Nothing spooled — no-op (fast, common path).
[[ -s "$SPOOL" ]] || exit 0

juvant_db_resolve
if [[ -z "$JUVANT_DB_PROVIDER" ]]; then
  echo "[drain-audit-spool] WARN: no db.provider configured; leaving spool intact" >&2
  exit 0
fi

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
