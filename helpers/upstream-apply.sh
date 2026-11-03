#!/usr/bin/env bash
# helpers/upstream-apply.sh
# ADR 0036 — the Upstream sync apply step (JUVANT_OS.md "Upstream sync"
# step 7) as ONE command, so it can be the only entry in the Claude Code
# sandbox `excludedCommands`: with the sandbox on, agent Bash cannot write
# hooks/, helpers/, scripts/ or .claude/settings.json, and this helper is
# what restores them from upstream.
#
# It applies nothing but canonical upstream content:
#   - the `upstream` remote must be the canonical juvantlabs/juvant-os
#     (.git/config is write-denied in the sandbox, so an agent cannot repoint it);
#   - it resolves upstream main itself (`git ls-remote`) and fetches it,
#     then applies from THAT commit — never from refs/remotes/upstream/*,
#     which sandboxed Bash can still move;
#   - every file must match the Framework whitelist read from that same
#     upstream commit's JUVANT_OS.md (globs such as agents/projects/*.md
#     included); no absolute paths, no `..`, nothing under .git/;
#   - it runs only on a sync branch (`sync/…`, created in step 7), never on main.
# Afterwards it reconciles .claude/settings.json (scripts/sync-hooks.sh and
# scripts/sync-sandbox.sh — both idempotent). Each applied file is logged to
# .juvant/logs/upstream-apply.log; the call itself is audited by the
# PreToolUse hook like any Bash call.
#
# Usage:
#   bash helpers/upstream-apply.sh <file> [<file>…]
#   bash helpers/upstream-apply.sh --settings-only     reconcile settings, apply nothing
# Exit: 0 all applied; 1 refused / failed (nothing partial is hidden: each
# file is reported); 2 usage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
export GIT_NO_REPLACE_OBJECTS=1
LOG="$REPO_ROOT/.juvant/logs/upstream-apply.log"
TAG="[upstream-apply]"

log() { echo "$TAG $*"; if [[ -d "$(dirname "$LOG")" ]]; then echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"; fi; }

_settings() {
  bash "$REPO_ROOT/scripts/sync-hooks.sh" || { log "WARN: sync-hooks.sh failed"; return 1; }
  bash "$REPO_ROOT/scripts/sync-sandbox.sh" || { log "WARN: sync-sandbox.sh failed"; return 1; }
}

[[ $# -gt 0 ]] || { echo "usage: $0 <file>… | --settings-only" >&2; exit 2; }
if [[ "$1" == "--settings-only" ]]; then _settings; exit $?; fi

URL=$(git remote get-url upstream 2>/dev/null || echo "")
if [[ ! "$URL" =~ (^|[/:])juvantlabs/juvant-os(\.git)?$ ]]; then
  log "REFUSED: the 'upstream' remote is '${URL:-<none>}', not the canonical juvantlabs/juvant-os"; exit 1
fi
BRANCH=$(git symbolic-ref --short -q HEAD || echo "")
if [[ "$BRANCH" != sync/* ]]; then
  log "REFUSED: current branch is '${BRANCH:-<detached>}' — create the sync branch first (git checkout -b sync/upstream-<tag>)"; exit 1
fi

SHA=$(git ls-remote upstream refs/heads/main 2>/dev/null | awk '{print $1; exit}')
if [[ ! "$SHA" =~ ^[0-9a-f]{40}$ ]]; then log "REFUSED: cannot resolve upstream main (git ls-remote)"; exit 1; fi
git fetch --no-tags -q upstream main
if ! git cat-file -e "${SHA}^{commit}" 2>/dev/null; then log "REFUSED: upstream main $SHA not present after fetch"; exit 1; fi

WHITELIST=$(git show "${SHA}:JUVANT_OS.md" 2>/dev/null \
  | awk '/^\*\*Framework whitelist\*\*/{f=1} f&&/^```$/{c++; if (c==2) exit; next} f&&c==1{print}' \
  | tr -s ' \t' '\n' | grep -v '^$' || true)
if [[ -z "$WHITELIST" ]]; then log "REFUSED: no Framework whitelist in upstream JUVANT_OS.md at $SHA"; exit 1; fi

_whitelisted() {
  local f="$1" pat
  while IFS= read -r pat; do
    # shellcheck disable=SC2053  # $pat is a glob on purpose (agents/projects/*.md)
    [[ "$f" == $pat ]] && return 0
  done <<<"$WHITELIST"
  return 1
}

rc=0
for f in "$@"; do
  f="${f#./}"
  if [[ "$f" == /* || "$f" == *..* || "$f" == .git/* || "$f" == .git ]]; then
    log "REFUSED $f — not a repo-relative path"; rc=1; continue
  fi
  if ! _whitelisted "$f"; then
    log "REFUSED $f — not on the upstream Framework whitelist"; rc=1; continue
  fi
  if ! git cat-file -e "${SHA}:${f}" 2>/dev/null; then
    log "SKIPPED $f — not present in upstream main ${SHA:0:12}"; rc=1; continue
  fi
  if git checkout "$SHA" -- "$f"; then
    log "APPLIED $f @ upstream ${SHA:0:12}"
  else
    log "FAILED $f"; rc=1
  fi
done

_settings || rc=1
exit "$rc"
