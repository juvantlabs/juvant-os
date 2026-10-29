#!/usr/bin/env bash
# hooks/lib/hooks-integrity.sh
# SessionStart integrity check of the guardrail tree — the DETECTION half of
# security_audit_log#148 (decisions#300 item 13), widened by decisions#303 B2
# (security_audit_log#160). Track 2f in pre-tool-use.sh is the PREVENTION half;
# it cannot see paths assembled at runtime, `patch` / archive extraction, or an
# edit made outside Claude Code. This check catches the result instead of the act.
#
# Checked files: the SYNCED part of the shared protected-path set
# (hooks/lib/guardrail-paths.sh): hooks/*.sh, hooks/lib/*.sh,
# hooks/bash-policy.json, helpers/*.sh, scripts/*.sh. (The spool and backups
# are runtime data — Track 2f protects them; there is nothing to compare.)
#
# Baseline — no recorded hash that an agent could re-record after tampering:
#   • canonical `upstream` remote with an `upstream/main` ref (every adopter
#     that runs Upstream sync has one): each file's git blob must be a blob that
#     its directory has held at SOME point in upstream/main history. An instance
#     that is behind upstream still passes (old upstream content is upstream
#     content); any byte not authored upstream fails.
#   • otherwise: the working tree must match HEAD (uncommitted drift only;
#     weaker — reported as such).
# Plus, in both modes: a protected file tracked in HEAD but missing on disk.
#
# Scheduled jobs (macOS): every installed ~/Library/LaunchAgents/
# io.juvant.guardrails.*.plist must match what helpers/install-schedules.sh
# would generate now — ProgramArguments and the schedule keys
# (StartCalendarInterval / StartInterval). A plist pointing launchd at other
# code, or with no generator counterpart, is a finding. (Paths baked from the
# installer's environment — HOME, PATH — are not compared.)
#
# Framework development (origin = juvantlabs/juvant-os, or
# JUVANT_FRAMEWORK_DEV=1) is skipped: these files change there by design. Same
# tri-state as Track 2f.
#
# API:
#   juvant_hooks_integrity_check <repo_root>
#     prints one finding per line on stdout ("<kind>: <path>"), then
#     returns 0 = clean, 1 = findings, 2 = skipped / indeterminate
#     (reason on stdout prefixed "skip: ").
# Test knob: JUVANT_LAUNCHAGENTS_DIR overrides ~/Library/LaunchAgents.

juvant_hooks_integrity_check() {
  local root="$1" mode origin up blobs f h rel found=0 synced_re
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

  # Shared protected-path set; fall back to the gate scripts alone if the lib
  # is missing (the missing lib is itself reported below as missing/untracked).
  if [[ -f "$root/hooks/lib/guardrail-paths.sh" ]]; then
    # shellcheck disable=SC1091
    . "$root/hooks/lib/guardrail-paths.sh"
  fi
  if ! declare -F juvant_guardrail_synced_files >/dev/null 2>&1; then
    juvant_guardrail_synced_files() {
      local r="$1" x
      for x in "$r"/hooks/*.sh "$r"/hooks/lib/*.sh "$r"/hooks/bash-policy.json; do
        [[ -e "$x" ]] && printf '%s\n' "${x#"$r"/}"
      done
    }
    juvant_guardrail_synced_re() { printf '%s' '^hooks/([^/]+\.sh|lib/[^/]+\.sh|bash-policy\.json)$'; }
  fi
  synced_re=$(juvant_guardrail_synced_re)

  up=$(git -C "$root" remote get-url upstream 2>/dev/null || echo "")
  if [[ "$up" =~ (^|[/:])juvantlabs/juvant-os(\.git)?$ ]] \
     && git -C "$root" rev-parse --verify -q upstream/main >/dev/null 2>&1; then
    mode="upstream"
    # Every blob these trees have held in upstream history (post-image of each
    # change) plus the current tree.
    blobs=$( {
      git -C "$root" log --no-abbrev --format= --raw upstream/main -- hooks/ helpers/ scripts/ 2>/dev/null \
        | awk '{print $4}'
      git -C "$root" ls-tree -r upstream/main -- hooks/ helpers/ scripts/ 2>/dev/null | awk '{print $3}'
    } | sort -u)
  else
    mode="head"
  fi

  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    f="$root/$rel"
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
  done < <(juvant_guardrail_synced_files "$root")

  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    if [[ "$rel" =~ $synced_re && ! -e "$root/$rel" ]]; then
      echo "missing: $rel"; found=1
    fi
  done < <(git -C "$root" ls-tree -r --name-only HEAD -- hooks/ helpers/ scripts/ 2>/dev/null)

  _juvant_plist_findings "$root" && found=1

  # decisions#305: an `env` block in .claude/settings*.json reaches every hook
  # process. JUVANT_FRAMEWORK_DEV=1 there would switch Track 2f off, and the
  # test-only policy / config overrides would redirect the policy source.
  local sf key
  for sf in "$root/.claude/settings.json" "$root/.claude/settings.local.json"; do
    [[ -f "$sf" ]] || continue
    while IFS= read -r key; do
      [[ -n "$key" ]] && { echo "settings-env-override: ${sf#"$root"/} sets $key"; found=1; }
    done < <(jq -r '(.env // {}) | keys[] | select(test("^JUVANT_(FRAMEWORK_DEV|POLICY_TEST|POLICY_FILE|CONFIG)$"))' "$sf" 2>/dev/null)
  done

  [[ "$mode" == head ]] && echo "baseline: HEAD (no canonical upstream/main ref — uncommitted drift only)"
  [[ "$found" == 1 ]] && return 1
  return 0
}

# Compare installed io.juvant.guardrails.*.plist with a fresh generation.
# Prints findings; returns 0 if there was at least one, 1 otherwise.
_juvant_plist_findings() {
  local root="$1" la tmp p base exp key a b any=1
  la="${JUVANT_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
  command -v plutil >/dev/null 2>&1 || return 1
  [[ -f "$root/helpers/install-schedules.sh" ]] || return 1
  compgen -G "$la/io.juvant.guardrails.*.plist" >/dev/null || return 1
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/juvant-plist-XXXXXX") || return 1
  # Generate into a scratch HOME. launchctl is replaced by `false` (nothing is
  # loaded; `print` reports not-loaded so the bootout wait exits at once) and
  # the post-install self-check is off. Only the plist files are used.
  # JUVANT_SCHED_GENERATE_ONLY: emit the plists for the mode already installed
  # (pinned checkout or working tree, BUG-089) without touching git.
  HOME="$tmp" JUVANT_LAUNCHCTL=false JUVANT_SCHED_SELFCHECK=0 JUVANT_SCHED_GENERATE_ONLY=1 \
    bash "$root/helpers/install-schedules.sh" install >/dev/null 2>&1 || true
  for p in "$la"/io.juvant.guardrails.*.plist; do
    base="${p##*/}"
    exp="$tmp/Library/LaunchAgents/$base"
    if [[ ! -f "$exp" ]]; then
      echo "plist-unexpected: $base"; any=0; continue
    fi
    for key in ProgramArguments StartCalendarInterval StartInterval; do
      a=$(plutil -extract "$key" json -o - "$p" 2>/dev/null || echo "<absent>")
      b=$(plutil -extract "$key" json -o - "$exp" 2>/dev/null || echo "<absent>")
      if [[ "$a" != "$b" ]]; then
        echo "plist-mismatch: $base ($key)"; any=0
      fi
    done
  done
  rm -rf "$tmp"
  return "$any"
}
