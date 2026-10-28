#!/usr/bin/env bash
# hooks/lib/hooks-integrity.sh
# SessionStart integrity check of the guardrail tree — the DETECTION half of
# security_audit_log#148 (decisions#300 item 13). Track 2f in pre-tool-use.sh
# is the PREVENTION half; it cannot see paths assembled at runtime, `patch` /
# archive extraction, or an edit made outside Claude Code. This check catches
# the result instead of the act.
#
# Guardrail files: hooks/*.sh, hooks/lib/*.sh, hooks/bash-policy.json (the same
# set Track 2f protects; tests/hooks/ is not part of it).
#
# Baseline — no recorded hash that an agent could re-record after tampering:
#   • canonical `upstream` remote with an `upstream/main` ref (every adopter
#     that runs Upstream sync has one): each guardrail file's git blob must be
#     a blob that hooks/ has held at SOME point in upstream/main history. An
#     instance that is behind upstream still passes (old upstream content is
#     upstream content); any byte not authored upstream fails.
#   • otherwise: the working tree must match HEAD (uncommitted drift only;
#     weaker — reported as such).
# Plus, in both modes: a guardrail file tracked in HEAD but missing on disk.
#
# Framework development (origin = juvantlabs/juvant-os, or
# JUVANT_FRAMEWORK_DEV=1) is skipped: hooks change there by design. Same
# tri-state as Track 2f.
#
# API:
#   juvant_hooks_integrity_check <repo_root>
#     prints one finding per line on stdout ("<kind>: <path>"), then
#     returns 0 = clean, 1 = findings, 2 = skipped / indeterminate
#     (reason on stdout prefixed "skip: ").

juvant_hooks_integrity_check() {
  local root="$1" mode origin up blobs f h rel found=0
  local fw="${JUVANT_FRAMEWORK_DEV:-auto}"
  if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "skip: not a git work tree"; return 2
  fi
  if [[ "$fw" == "1" ]]; then echo "skip: framework dev"; return 2; fi
  if [[ "$fw" != "0" ]]; then
    origin=$(git -C "$root" remote get-url origin 2>/dev/null || echo "")
    if [[ "$origin" =~ (^|[/:])juvantlabs/juvant-os(\.git)?$ ]]; then
      echo "skip: framework dev"; return 2
    fi
  fi

  up=$(git -C "$root" remote get-url upstream 2>/dev/null || echo "")
  if [[ "$up" =~ (^|[/:])juvantlabs/juvant-os(\.git)?$ ]] \
     && git -C "$root" rev-parse --verify -q upstream/main >/dev/null 2>&1; then
    mode="upstream"
    # Every blob hooks/ has held in upstream history (post-image of each
    # change) plus the current tree.
    blobs=$( {
      git -C "$root" log --no-abbrev --format= --raw upstream/main -- hooks/ 2>/dev/null \
        | awk '{print $4}'
      git -C "$root" ls-tree -r upstream/main -- hooks/ 2>/dev/null | awk '{print $3}'
    } | sort -u)
  else
    mode="head"
  fi

  shopt -s nullglob
  for f in "$root"/hooks/*.sh "$root"/hooks/lib/*.sh "$root"/hooks/bash-policy.json; do
    rel="${f#"$root"/}"
    if [[ "$mode" == upstream ]]; then
      h=$(git -C "$root" hash-object "$f" 2>/dev/null || echo "")
      if [[ -z "$h" ]] || ! grep -qx "$h" <<< "$blobs"; then
        echo "not-from-upstream: $rel"; found=1
      fi
    else
      if ! git -C "$root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
        echo "untracked: $rel"; found=1
      elif ! git -C "$root" diff --quiet HEAD -- "$rel" 2>/dev/null; then
        echo "modified-vs-HEAD: $rel"; found=1
      fi
    fi
  done
  shopt -u nullglob

  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    if [[ "$rel" =~ ^hooks/([^/]+\.sh|lib/[^/]+\.sh|bash-policy\.json)$ && ! -e "$root/$rel" ]]; then
      echo "missing: $rel"; found=1
    fi
  done < <(git -C "$root" ls-tree -r --name-only HEAD -- hooks/ 2>/dev/null)

  [[ "$mode" == head ]] && echo "baseline: HEAD (no canonical upstream/main ref — uncommitted drift only)"
  [[ "$found" == 1 ]] && return 1
  return 0
}
