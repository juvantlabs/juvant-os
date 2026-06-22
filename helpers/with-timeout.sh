#!/usr/bin/env bash
# helpers/with-timeout.sh
# Portable hard timeout for a single command (FEAT-052).
#
# The framework primitive for bounding any network/IO call that could
# hang. macOS ships neither `timeout` nor `gtimeout`, so this falls back
# to a perl alarm (perl is present on macOS by default). Use it to wrap
# `gh` / `gh api` GitHub calls so a wedged request fails fast instead of
# stalling the agent until Claude Code's 600s stream watchdog
# (agent_timeout_seconds) — the cause of the GitHub-MCP stalls FEAT-052
# replaces. MCP tool calls cannot be wrapped (internal to Claude Code);
# gh-via-Bash can, which is the whole point of going CLI-only.
#
# Usage:
#   bash helpers/with-timeout.sh <seconds> <command> [args...]
#   bash helpers/with-timeout.sh 60 gh pr view 123 --json state
#   bash helpers/with-timeout.sh 90 gh api repos/o/r/pulls/1/reviews -X POST -f event=APPROVE
#
# Exit code: the command's own exit code, or 124 if it timed out
# (matching GNU `timeout` convention).

set -uo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: with-timeout.sh <seconds> <command> [args...]" >&2
  exit 2
fi

secs="$1"
shift

if command -v timeout &>/dev/null; then
  exec timeout "$secs" "$@"
elif command -v gtimeout &>/dev/null; then
  exec gtimeout "$secs" "$@"
else
  # perl alarm fallback: fork the command, SIGKILL it if the deadline
  # passes, and translate a timeout kill into exit 124.
  exec perl -e '
    my $s = shift;
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) { exec @ARGV or exit 127; }
    local $SIG{ALRM} = sub { kill "KILL", $pid; };
    alarm $s;
    waitpid($pid, 0);
    my $status = $?;
    alarm 0;
    exit 124 if ($status & 127);   # killed by a signal => treat as timeout
    exit($status >> 8);
  ' "$secs" "$@"
fi
