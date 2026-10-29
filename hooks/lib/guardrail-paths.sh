#!/usr/bin/env bash
# hooks/lib/guardrail-paths.sh
# The ONE protected-path set shared by the Track 2f tamper floor
# (hooks/pre-tool-use.sh) and the SessionStart integrity check
# (hooks/lib/hooks-integrity.sh) — decisions#303 R1 + B2 (security_audit_log
# #154, #160). Defining it once keeps prevention and detection from drifting.
#
# Protected (in a deployed instance; framework dev is exempt upstream):
#   • gate scripts + deny-list   hooks/*.sh, hooks/lib/*.sh, hooks/bash-policy.json
#   • scheduled / admin code     helpers/*.sh (incl. drain-audit-spool.sh,
#                                install-schedules.sh, kb-sync.sh), scripts/*.sh
#                                (incl. governance-backfill.sh)
#   • the audit spool family     .juvant/audit-spool.sql and every sibling
#                                (.draining.<pid>, .merge.<pid>, .reclaim.*),
#                                .juvant/audit-spool.quarantine
#   • pre-drain backups          .juvant/backups/**
#   • alert delivery receipts    .juvant/alert-receipts.jsonl (BUG-087)
# Directories and globs over those trees count too (`rm -rf helpers`,
# `cp x hooks/*`). Anything under a tests/ directory is NOT protected — the
# suites are instance-editable (decisions#300 item 9).
#
# Content-checked at SessionStart (synced files only; the spool and backups are
# runtime data): juvant_guardrail_synced_files.

# File-level patterns (bash ERE, matched against a normalised relative path).
JUVANT_GUARDRAIL_FILE_RES=(
  '(^|/)hooks/([^/]+\.sh|lib/[^/]+\.sh|bash-policy\.json)$'
  '(^|/)helpers/[^/]+\.sh$'
  '(^|/)scripts/[^/]+\.sh$'
  '(^|/)\.juvant/audit-spool\.(sql([.][^/]*)?|quarantine)$'
  '(^|/)\.juvant/backups(/.*)?$'
  # decisions#305 (B1a): the committed security policy, the git store whose
  # remote refs the hook reads it from (refs, packed-refs, config, objects),
  # and the SessionStart "last policy blob seen" marker.
  '(^|/)security/policy\.json$'
  '(^|/)\.git(/.*)?$'
  '(^|/)\.juvant/policy-blob-seen$'
  # BUG-087: alert delivery receipts (hook-only append).
  '(^|/)\.juvant/alert-receipts\.jsonl$'
)
# Directory / glob targets (whole-tree operations).
JUVANT_GUARDRAIL_DIR_RES=(
  '(^|/)hooks(/lib)?/?$'
  '(^|/)hooks/(lib/)?\*[^/]*$'
  '(^|/)(helpers|scripts)/?$'
  '(^|/)(helpers|scripts)/\*[^/]*$'
  '(^|/)\.juvant/?$'
  '(^|/)\.juvant/(\*[^/]*|audit-spool\*[^/]*)$'
  '(^|/)security/?$'
  '(^|/)security/\*[^/]*$'
)
# Raw substrings that reference a protected path inside code we do not parse
# (interpreters, heredocs, $(…)). The captured prefix is checked for tests/.
JUVANT_GUARDRAIL_RAW_RE='([^[:space:]"'"'"'(),=:;`]*)(hooks/([A-Za-z0-9_.*-]+\.sh|lib/[A-Za-z0-9_.*-]+\.sh|bash-policy\.json|lib/?|\*)|helpers/[A-Za-z0-9_.*-]+\.sh|scripts/[A-Za-z0-9_.*-]+\.sh|\.juvant/audit-spool|\.juvant/backups|audit-spool\.(sql|quarantine)|security/policy\.json|\.git/|policy-blob-seen|alert-receipts\.jsonl)'
# Directories a `cd` may enter, after which bare names are resolved inside.
JUVANT_GUARDRAIL_CD_RE='(^|/)(hooks(/lib)?|helpers|scripts|\.juvant(/backups)?|security|\.git(/[^/]+)*)$'

# juvant_guardrail_is_path <path> [cwd-dir]
#   0 if <path> (quotes already removed) is protected. When [cwd-dir] is set
#   (a protected dir entered by an earlier `cd` in the same command), a
#   relative <path> is also resolved inside it.
juvant_guardrail_is_path() {
  local p="$1" cwd="${2:-}" re
  [[ -n "$p" ]] || return 1
  p="${p#./}"
  if [[ "$p" =~ (^|/)tests/ ]]; then return 1; fi
  for re in "${JUVANT_GUARDRAIL_FILE_RES[@]}" "${JUVANT_GUARDRAIL_DIR_RES[@]}"; do
    if [[ "$p" =~ $re ]]; then return 0; fi
  done
  if [[ -n "$cwd" && "$p" != /* && "$p" != "$cwd"/* ]]; then
    juvant_guardrail_is_path "$cwd/$p"
    return $?
  fi
  return 1
}

# juvant_guardrail_cd_dir <cd-target> → prints the normalised protected dir
# a `cd` enters, or nothing.
juvant_guardrail_cd_dir() {
  local t="${1%/}"
  t="${t#./}"
  if [[ "$t" =~ (^|/)tests/ ]]; then return 0; fi
  if [[ "$t" =~ $JUVANT_GUARDRAIL_CD_RE ]]; then
    printf '%s' "${BASH_REMATCH[0]#/}"
  fi
}

# juvant_guardrail_raw_ref <text> → 0 if a protected path occurs as a raw
# substring (quotes included), excluding occurrences under tests/.
juvant_guardrail_raw_ref() {
  local s="$1"
  while [[ "$s" =~ $JUVANT_GUARDRAIL_RAW_RE ]]; do
    if [[ "${BASH_REMATCH[1]}" != *tests/ ]]; then return 0; fi
    s="${s#*"${BASH_REMATCH[0]}"}"
  done
  return 1
}

# juvant_guardrail_synced_files <root> → the synced protected files present
# on disk, one relative path per line (for the integrity check).
juvant_guardrail_synced_files() {
  local root="$1" f
  for f in "$root"/hooks/*.sh "$root"/hooks/lib/*.sh "$root"/hooks/bash-policy.json \
           "$root"/helpers/*.sh "$root"/scripts/*.sh; do
    [[ -e "$f" ]] && printf '%s\n' "${f#"$root"/}"
  done
}

# juvant_guardrail_synced_re → ERE matching a synced protected file path
# (used to find tracked-but-missing files).
juvant_guardrail_synced_re() {
  printf '%s' '^(hooks/([^/]+\.sh|lib/[^/]+\.sh|bash-policy\.json)|helpers/[^/]+\.sh|scripts/[^/]+\.sh)$'
}
