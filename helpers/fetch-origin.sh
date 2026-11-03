#!/usr/bin/env bash
# helpers/fetch-origin.sh
# ADR 0036 — `git fetch origin` for agents when the Claude Code Bash sandbox
# is on. The sandbox write-denies .git/refs/remotes/origin/ (the security
# policy is read from refs/remotes/origin/main, ADR 0034), so a sandboxed
# `git fetch` / `git pull` fails with "cannot lock ref". This helper is one
# of the two `excludedCommands` entries (exact match, no arguments): it does
# nothing but fetch the configured origin. It cannot be pointed elsewhere —
# .git/config (remotes, insteadOf, includes) is write-denied in the sandbox.
#
# Usage: bash helpers/fetch-origin.sh
# Then, to fast-forward a local branch: git merge --ff-only origin/<branch>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
export GIT_NO_REPLACE_OBJECTS=1
git fetch --prune --no-tags origin
echo "[fetch-origin] origin/main is $(git rev-parse --short origin/main 2>/dev/null || echo '?')"
