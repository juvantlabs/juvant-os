#!/usr/bin/env bash
# hooks/pre-tool-use.sh
# Claude Code PreToolUse hook — runs BEFORE every tool call.
#
# Two responsibilities per handbook ADR 0004:
#
#   Track 2 — gate Bash via universal deny-list + per-agent allow-list.
#     Pattern source: hooks/bash-policy.json. On match, output the
#     hookSpecificOutput deny wrapper (see "Output decision" below) which
#     Claude Code honors as a hard block (the tool call never executes).
#
#   Track 3 — write a 'pending' row to agent_actions_log BEFORE the
#     tool runs, so the audit trail exists independent of what the
#     agent later writes via decisions / messages. Cover-up by
#     fabricating decisions rows is detectable by reconciling against
#     this log (helpers/audit-reconcile.sh, weekly).
#
# Stdin: Claude Code event JSON
#   { "session_id": "...", "tool_name": "Bash"|...,
#     "tool_input": { ... } }
# Stdout: decision JSON (Claude Code 2.x hookSpecificOutput wrapper — BUG-053)
#   { "hookSpecificOutput": { "hookEventName": "PreToolUse",
#     "permissionDecision": "allow"|"deny", "permissionDecisionReason": "..." } }
#
# Env vars: TURSO_URL, TURSO_TOKEN (fallback to .juvant/config.json)
#           AGENT_ROLE (set by Skill at session boot)
#
# Latency budget: < 100ms typical. Turso INSERT is the bottleneck.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="$SCRIPT_DIR/bash-policy.json"

# Read event from stdin
EVENT_JSON=""
if [ ! -t 0 ]; then
  EVENT_JSON=$(cat -)
fi

# Parse event fields (default to safe fallbacks if event shape unexpected)
TOOL_NAME=$(echo "$EVENT_JSON" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
SESSION_ID=$(echo "$EVENT_JSON" | jq -r '.session_id // ""' 2>/dev/null || echo "")
# Resolve role precedence (F-2 fix, v0.7.3+): when the hook fires inside
# a subagent, Claude Code populates `.agent_type` in the event payload
# (per https://code.claude.com/docs/en/hooks). Use it as the primary
# source of truth — env-derived AGENT_ROLE was never set in subagent
# context (operator mode bypass triggered every CSO tool call as
# `agent='unknown'`, masked Layer 5 §11 fail-safe predicate (b), and
# bypassed the per-agent allow-list in bash-policy.json — closing both
# F-2 and F-10 in one fix).
ROLE=$(echo "$EVENT_JSON" | jq -r '.agent_type // ""' 2>/dev/null || echo "")
ROLE="${ROLE:-${AGENT_ROLE:-}}"
if [[ -z "$ROLE" ]]; then
  # Main thread in a Juvant OS instance = CoS operating as orchestrator.
  # Fallback to 'unknown' only outside a Juvant OS instance. Honours
  # JUVANT_CONFIG like every track does (BUG-056; decisions#302 — the hook
  # suite points it at a non-instance path so adopter runs are isolated).
  if [[ -f "${JUVANT_CONFIG:-$SCRIPT_DIR/../.juvant/config.json}" ]]; then
    ROLE="cos"
  else
    ROLE="unknown"
  fi
fi

# BUG-049: normalize ROLE → LOOKUP_ROLE for the Bash allow-list lookup.
# Project-scope agents carry a project-slug prefix in agent_type
# (e.g. "dog-ai-eng-lead"), but bash-policy.json `agent_allow` keys are
# canonical/unprefixed ("eng-lead"). Without normalization, project agents
# are denied every DIRECT git/gh/… command (only commands starting with a
# universal_allow token like `cd` slipped through, via the compound-command
# caveat) — which also blocks gh-CLI-only (FEAT-052) for project eng-leads.
# Exact agent_allow key wins; else the longest key K such that ROLE ends
# with "-K". Only the allow-list/tier lookup uses LOOKUP_ROLE; the Track-2b
# scope checks and the Track-2d writer gate keep the full prefixed ROLE.
LOOKUP_ROLE="$ROLE"
if [[ -f "$POLICY" ]] && ! jq -e --arg r "$ROLE" '.agent_allow | has($r)' "$POLICY" >/dev/null 2>&1; then
  _canon=$(jq -r --arg r "$ROLE" \
    '.agent_allow | keys[] as $k | select($r == $k or ($r | endswith("-" + $k))) | $k' \
    "$POLICY" 2>/dev/null | awk '{ if (length($0) > length(b)) b=$0 } END{ print b }')
  [[ -n "$_canon" ]] && LOOKUP_ROLE="$_canon"
fi

# Compute SHA-256 of canonical (sorted-keys) JSON of tool_input
ARGS_JSON=$(echo "$EVENT_JSON" | jq -c -S '.tool_input // {}' 2>/dev/null || echo "{}")
ARGS_HASH=$(printf '%s' "$ARGS_JSON" | shasum -a 256 | awk '{print $1}')
# decisions#298 (L1-F2): capture the hook clock at tool-call time. The audit row
# is spooled and drained later; without an explicit started_at the DB DEFAULT
# CURRENT_TIMESTAMP stamps DRAIN time, skewing every time-window correlation
# (orphan checks, continuity-gap, halt-window attribution). Same UTC format as
# the ended_at written by post-tool-use.sh.
STARTED_AT=$(date -u +"%Y-%m-%d %H:%M:%S")

# Build input_summary — human-readable, max 200 chars (FEAT-040 Layer 1d)
case "$TOOL_NAME" in
  Bash)
    _RAW=$(echo "$EVENT_JSON" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
    INPUT_SUMMARY=$(printf '%.200s' "$_RAW") ;;
  Edit)
    _FILE=$(echo "$EVENT_JSON" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
    _OLD=$(echo "$EVENT_JSON" | jq -r '.tool_input.old_string // ""' 2>/dev/null | head -c 80 || echo "")
    INPUT_SUMMARY=$(printf '%.200s' "Edit $_FILE: $_OLD") ;;
  Write)
    _FILE=$(echo "$EVENT_JSON" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
    INPUT_SUMMARY=$(printf '%.200s' "Write $_FILE") ;;
  Read)
    _FILE=$(echo "$EVENT_JSON" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
    INPUT_SUMMARY=$(printf '%.200s' "Read $_FILE") ;;
  *)
    INPUT_SUMMARY=$(printf '%.200s' "$ARGS_JSON") ;;
esac

# Default: allow
DECISION="allow"
DENY_REASON=""

# ─────────────────────────────────────────────
# Track 2 — Bash policy enforcement
# ─────────────────────────────────────────────
if [[ "$TOOL_NAME" == "Bash" && -f "$POLICY" ]]; then
  COMMAND=$(echo "$EVENT_JSON" | jq -r '.tool_input.command // ""')

  # ── decisions#272 (BUG-066): turso SQL mode detection ─────────────────────
  # When FIRST_TOKEN is turso (after stripping inline env-prefix assignments)
  # and the invocation is `turso db shell/exec <db> <SQL>`, the meaningful
  # denial surface is the SQL payload — not the full shell command string.
  # In this mode the universal deny_patterns (shell-binary oriented, matching
  # anywhere in the command string) are skipped to prevent false-positive
  # denials on prose inside SQL VALUES/rationale columns that happens to
  # mention names of shell binaries (e.g. "the shutdown procedure", "git commit
  # fixes this", "we TRUNCATE TABLE in the runbook"). sql_deny_patterns
  # (bash-policy.json) are checked against the extracted SQL payload instead.
  # Track 2d write-verb detection is also skipped in this mode: the SQL payload
  # is not a shell command and cannot invoke git or gh write operations.
  # Option A (FIRST_TOKEN routing) + Option C (sql_deny_patterns for payload).
  #
  # ── BUG-072 ──────────────────────────────────────────────────────────────
  # Turso SQL mode is a HOLE PUNCHED IN TWO GUARDRAILS, so it must only open
  # for a command that is EXCLUSIVELY a turso invocation. The original
  # activation test was "first token is turso" AND "the string contains
  # `turso db shell|exec `" — the second condition matching ANYWHERE. Both
  # hold for a compound command whose turso half is a decoy:
  #
  #   turso db shell db "SELECT 1" && rm -rf / --no-preserve-root
  #   turso db shell db "SELECT 1" && gh repo delete <org>/<repo> --yes
  #   turso db shell db "SELECT 1" && turso db destroy <db>
  #   turso db shell db "SELECT 1" | sudo tee /etc/hosts
  #   turso db shell db "SELECT 1" && git push origin main    ← §4 single-writer
  #
  # Every one of those was allowed. An eight-character prefix disarmed the
  # ENTIRE universal deny-list and the Track 2d single-writer gate for any
  # role — and `turso` is allow-listed for every agent, because it is the
  # DB write path. Track 2d's own `gh api` check already evaluates each
  # shell SEGMENT separately for exactly this reason (see below); the flaw
  # was letting a whole-command mode decide before any segmenting happened.
  #
  # Fix: activate only when the command is a single simple command — no shell
  # control operator (| & ; < > newline, backtick, $( ) outside quotes. A `;`
  # INSIDE the quoted SQL is untouched (statement stacking still works, and
  # sql_deny_patterns still split on it); an UNQUOTED `;` is a real shell
  # separator, which is precisely the case that must not qualify.
  #
  # Consequence, deliberate: heredoc and redirect forms
  # (`turso db shell "$URL" < schema.sql`, `… <<SQL … SQL`) no longer enter
  # turso mode and are checked against the full deny-list like any other
  # command. Pass SQL as a quoted argument — the form the framework uses
  # everywhere — to keep the BUG-066 prose exemption.
  # SC2016 / SC1003 are intentional here: every pattern in this scanner is a
  # LITERAL shell metacharacter (including the two-character `$(` and a lone
  # backslash), so single quotes are exactly right — nothing may expand.
  # shellcheck disable=SC2016,SC1003
  _juvant_cmd_is_simple() {
    local _s="$1" _i _c _q=''
    local _n=${#_s}
    # Fast path: no operator character anywhere → nothing to scan for.
    case "$_s" in
      *'|'*|*'&'*|*';'*|*'<'*|*'>'*|*'`'*|*'$('*|*$'\n'*) ;;
      *) return 0 ;;
    esac
    for (( _i=0; _i<_n; _i++ )); do
      _c="${_s:_i:1}"
      if [[ "$_q" == "'" ]]; then
        [[ "$_c" == "'" ]] && _q=''
        continue
      fi
      if [[ "$_q" == '"' ]]; then
        # Command substitution IS live inside double quotes.
        case "$_c" in
          '\') (( _i++ )) ;;
          '"') _q='' ;;
          '`') return 1 ;;
          '$') [[ "${_s:_i+1:1}" == '(' ]] && return 1 ;;
        esac
        continue
      fi
      case "$_c" in
        "'"|'"') _q="$_c" ;;
        '\')     (( _i++ )) ;;
        '|'|'&'|';'|'<'|'>'|'`'|$'\n') return 1 ;;
        '$')     [[ "${_s:_i+1:1}" == '(' ]] && return 1 ;;
      esac
    done
    return 0
  }
  # ── decisions#300 items 5 + 12: a prose-free view of the command ──────────
  # The universal deny-list and the Track 2d write-verb scan matched the WHOLE
  # string, quoted text included, so prose inside an argument false-denied a
  # benign command (a decisions INSERT whose rationale mentioned a pause
  # window hit the `halt` rule; a `git push` mentioned in a VALUES column hit
  # Track 2d) whenever the command was not a BUG-072 simple turso command.
  # _juvant_strip_prose: quoted literals that contain whitespace (prose, SQL)
  # are emptied; single-word literals are only unwrapped, so a quoted
  # destructive ARGUMENT stays visible (`rm -rf "/"` → `rm -rf /`). A literal
  # with whitespace cannot name the same target (`"/ "` is not `/`).
  # shellcheck disable=SC2016,SC1003
  _juvant_strip_prose() {
    local s="$1" n=${#1} i=0 c q="" lit="" out=""
    while [[ $i -lt $n ]]; do
      c="${s:$i:1}"
      if [[ -n "$q" ]]; then
        if [[ "$c" == "$q" ]]; then
          case "$lit" in *[[:space:]]*) out+="$q$q" ;; *) out+="$lit" ;; esac
          q=""; lit=""
        elif [[ "$q" == '"' && "$c" == '\' ]]; then
          i=$((i + 1)); lit+="${s:$i:1}"
        else
          lit+="$c"
        fi
      else
        case "$c" in
          "'"|'"') q="$c"; lit="" ;;
          '\') out+="$c${s:$((i + 1)):1}"; i=$((i + 1)) ;;
          *) out+="$c" ;;
        esac
      fi
      i=$((i + 1))
    done
    # Unterminated quote: keep the remainder verbatim (fail toward scanning).
    [[ -n "$q" ]] && out+="$q$lit"
    printf '%s' "$out"
  }
  # A command that EVALUATES text as code (a shell or interpreter, eval,
  # command substitution, ANSI-C $'…' quoting) keeps the full view: its quoted
  # text is code, not data (`bash -c "shutdown now"`, `echo x | sh`).
  # shellcheck disable=SC2016
  _juvant_cmd_evaluates() {
    local full="$1" stripped="$2"
    local re='(^|[^A-Za-z0-9_.-])(bash|sh|zsh|dash|ksh|fish|eval|exec|ssh|su|xargs|watch|script|parallel|python[0-9.]*|node|nodejs|deno|bun|perl|ruby|php|osascript|awk|gawk|mawk|lua|source)([[:space:]]|$)'
    [[ "$stripped" =~ $re ]] && return 0
    [[ "$full" == *'$('* || "$full" == *'`'* || "$full" == *"\$'"* ]] && return 0
    return 1
  }
  _CMD_SCAN="$COMMAND"
  if [[ "$COMMAND" == *[\'\"]* ]]; then
    _cmd_stripped=$(_juvant_strip_prose "$COMMAND")
    if ! _juvant_cmd_evaluates "$COMMAND" "$_cmd_stripped"; then
      _CMD_SCAN="$_cmd_stripped"
    fi
  fi

  _TURSO_SQL_MODE=0
  _TURSO_SQL_PAYLOAD=""
  _dft_line=""
  read -r _dft_line <<< "$COMMAND"
  # Strip leading whitespace from the first line.
  while [[ "${_dft_line:0:1}" == " " || "${_dft_line:0:1}" == $'\t' ]]; do _dft_line="${_dft_line:1}"; done
  _dft_tok="${_dft_line%% *}"
  # Advance past inline VAR=val env-prefix tokens to find the first real binary.
  while [[ "$_dft_tok" == *=* && "$_dft_line" == *" "* ]]; do
    _dft_line="${_dft_line#* }"
    while [[ "${_dft_line:0:1}" == " " || "${_dft_line:0:1}" == $'\t' ]]; do _dft_line="${_dft_line:1}"; done
    _dft_tok="${_dft_line%% *}"
  done
  _dft_tok="${_dft_tok##*/}"  # strip any path prefix (e.g. /usr/local/bin/turso → turso)
  # BUG-072: the invocation regex is anchored at the HEAD of the command (after
  # env-prefix stripping, allowing an absolute path to the binary) rather than
  # matched anywhere, and the command must be a single simple command.
  if [[ "$_dft_tok" == "turso" ]] && \
     _juvant_cmd_is_simple "$COMMAND" && \
     [[ "$_dft_line" =~ ^([^[:space:]]*/)?turso[[:space:]]+db[[:space:]]+(shell|exec)[[:space:]] ]]; then
    _TURSO_SQL_MODE=1
    # ── BUG-072, second surface: payload extraction ──────────────────────────
    # The exemption is only sound if the thing handed to sql_deny_patterns is
    # ACTUALLY the SQL. The previous `sed -E 's/.*turso…shell…[^[:space:]"]+…//'`
    # failed that three ways, each of which let a destructive statement through
    # as `allow` while the universal deny-list stayed skipped:
    #
    #   • QUOTED DB ARG — the class `[^[:space:]"]+` excludes the quote, so the
    #     whole expression failed to match and sed returned the string
    #     UNCHANGED. The payload became the entire command, starting with
    #     "turso", so the `^`-anchored DROP/TRUNCATE patterns could never fire.
    #       turso db shell "$TURSO_DATABASE_URL" "TRUNCATE TABLE sessions" → allow
    #     That is the form JUVANT_OS.md itself documents.
    #   • SINGLE-QUOTED SQL — only enclosing DOUBLE quotes were stripped, so the
    #     payload began with `'` and the `^`-anchored patterns missed again.
    #       turso db shell mydb 'TRUNCATE TABLE sessions' → allow
    #   • GREEDY `.*` — it consumed up to the LAST `turso db shell ` in the
    #     string, so a decoy inside the SQL, placed after the verb, strips the
    #     verb out of the payload before any pattern sees it. This defeats even
    #     the position-independent scope='global' escalation rule:
    #       turso db shell mydb "UPDATE decisions SET scope='global' WHERE id=1;
    #                            SELECT 'turso db shell zz'" → allow
    #
    # Replaced with a HEAD-ANCHORED match that understands a quoted DB argument,
    # and — the load-bearing part — FAILS CLOSED: if the invocation head cannot
    # be identified, we do not know what the SQL is, so the exemption is not
    # granted and the universal deny-list runs on the full command.
    _turso_head_re="^([^[:space:]]+=[^[:space:]]*[[:space:]]+)*([^[:space:]]*/)?turso[[:space:]]+db[[:space:]]+(shell|exec)[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+)([[:space:]]+|$)"
    if [[ "$COMMAND" =~ $_turso_head_re ]]; then
      _TURSO_SQL_PAYLOAD="${COMMAND:${#BASH_REMATCH[0]}}"
      # Strip enclosing quotes, either kind (turso accepts bare or quoted SQL).
      if [[ "$_TURSO_SQL_PAYLOAD" == '"'*'"' ]]; then
        _TURSO_SQL_PAYLOAD="${_TURSO_SQL_PAYLOAD#\"}"
        _TURSO_SQL_PAYLOAD="${_TURSO_SQL_PAYLOAD%\"}"
      elif [[ "$_TURSO_SQL_PAYLOAD" == "'"*"'" ]]; then
        _TURSO_SQL_PAYLOAD="${_TURSO_SQL_PAYLOAD#\'}"
        _TURSO_SQL_PAYLOAD="${_TURSO_SQL_PAYLOAD%\'}"
      fi
    else
      _TURSO_SQL_MODE=0
      _TURSO_SQL_PAYLOAD=""
    fi
  fi

  # Universal deny-list (skipped in turso SQL mode; sql_deny_patterns applied instead)
  # Shell-binary rules run on the prose-free view (_CMD_SCAN); the SQL-CONTENT
  # rules (DROP/TRUNCATE/scope='global') describe text that legitimately lives
  # inside quotes, so they keep the full command.
  if [[ "$_TURSO_SQL_MODE" -eq 0 ]]; then
    while IFS= read -r pattern; do
      [[ -z "$pattern" || "$pattern" == "null" ]] && continue
      _pat_view="$_CMD_SCAN"
      case "$pattern" in DROP*|TRUNCATE*|'(INSERT|UPDATE)'*) _pat_view="$COMMAND" ;; esac
      if [[ "$_pat_view" =~ $pattern ]]; then
        DECISION="deny"
        DENY_REASON="universal deny-list match: $pattern (handbook ADR 0004 Track 2)"
        break
      fi
    done < <(jq -r '.deny_patterns[]?' "$POLICY" 2>/dev/null)
  fi

  # SQL deny-list: destructive / privilege-escalating patterns checked against
  # the turso SQL payload, PER STATEMENT (split on ';'). Closes two under-deny
  # holes found reviewing decisions#272's original single-anchor approach:
  #   • per-statement — a destructive verb after statement stacking
  #     (`SELECT 1; DROP TABLE x`, `SELECT 1; TRUNCATE …`) is caught, not only a
  #     verb that heads the whole payload;
  #   • DROP/TRUNCATE patterns stay `^`-anchored *within each statement*, so a
  #     verb inside a string literal (VALUES ('DROP TABLE foo')) is not a
  #     statement head and does NOT false-deny;
  #   • the `scope='global'` escalation rule lives in deny_patterns, but that
  #     loop is SKIPPED in turso mode — so it MUST be mirrored in
  #     sql_deny_patterns (position-independent within a statement) or the
  #     escalation guard is lost for the primary DB-write path.
  # Guard on a non-empty payload: a bare `turso db shell <db>` (interactive open,
  # no SQL arg) yields an empty payload; iterating an empty array under `set -u`
  # would abort the hook (→ empty decision, a fail-open crash). Nothing to deny
  # when there is no SQL, so skip.
  if [[ "$DECISION" == "allow" && "$_TURSO_SQL_MODE" -eq 1 && -n "$_TURSO_SQL_PAYLOAD" ]]; then
    _sql_norm="${_TURSO_SQL_PAYLOAD//$'\n'/ }"
    IFS=';' read -ra _sql_stmts <<< "$_sql_norm"
    for _sql_stmt in "${_sql_stmts[@]}"; do
      [[ "$DECISION" == "deny" ]] && break
      while IFS= read -r pattern; do
        [[ -z "$pattern" || "$pattern" == "null" ]] && continue
        if [[ "$_sql_stmt" =~ $pattern ]]; then
          DECISION="deny"
          DENY_REASON="turso:sql deny-list match: $pattern (handbook ADR 0004 Track 2)"
          break
        fi
      done < <(jq -r '.sql_deny_patterns[]?' "$POLICY" 2>/dev/null)
    done
  fi

  # Agent-role deny-list (R3 defense-in-depth, security incident class:
  # framework-bug-enabled agent cloud-writes). Applies to any real agent
  # role; operator path (unknown/ceo/operator) is exempt. Patterns target
  # cloud-mutating CLI commands (az/aws/gcloud write verbs + destructive
  # terraform subcommands); read-only `az ... show|list|account|version`
  # and `terraform fmt|validate|plan|init|workspace|providers|version`
  # remain allowed. Cloud mutations must flow via the CEO-triggered
  # terraform-apply GitHub workflow (gated by Track 4 deployment-spec /
  # eng-platform-spec), never local CLI from an agent.
  if [[ "$DECISION" == "allow" ]]; then
    if [[ -n "$ROLE" && "$ROLE" != "unknown" && "$ROLE" != "ceo" && "$ROLE" != "operator" ]]; then
      while IFS= read -r pattern; do
        [[ -z "$pattern" || "$pattern" == "null" ]] && continue
        if [[ "$COMMAND" =~ $pattern ]]; then
          DECISION="deny"
          DENY_REASON="agent-role deny-list match (R3 cloud-write defense-in-depth): $pattern. Cloud mutations must flow via the terraform-apply GitHub workflow (deployment-spec / eng-platform-spec), never local CLI. Read-only operations (az … show|list|account, terraform fmt|validate|plan) are allowed. Refs: agent_role_deny_patterns in bash-policy.json"
          break
        fi
      done < <(jq -r '.agent_role_deny_patterns[]?' "$POLICY" 2>/dev/null)
    fi
  fi

  # Per-agent allow-list (only if not already denied universally).
  # Operator mode: when AGENT_ROLE is unset/unknown/ceo/operator, the
  # human is driving Claude Code directly (not via the Skill agent
  # dispatcher). Per-role allow-list does not apply — only the
  # universal deny-list. Auditing still applies (Track 3).
  if [[ "$DECISION" == "allow" ]]; then
    if [[ -z "$ROLE" || "$ROLE" == "unknown" || "$ROLE" == "ceo" || "$ROLE" == "operator" ]]; then
      : # operator mode — universal deny already enforced; allow continues
    else
      # F-30 fix (v0.7.4+): skip leading blank lines.
      # F-37 fix (v0.8.3+): also skip comment lines (#), shell keywords
      # (for/while/if/…), and variable-assignment lines (VAR=…). All three
      # produced false-positive denials: '#', 'WHITELIST=(', 'content=$(gh'
      # were extracted as the "binary" instead of the real command.
      # For variable assignments that embed a command substitution
      # (VAR=$(cmd …)), salvage the cmd as the binary to check.
      FIRST_TOKEN=""
      _ft_in_array=0
      while IFS= read -r _ft_line; do
        # strip leading whitespace — pure bash, no subshell
        while [[ "${_ft_line:0:1}" == " " || "${_ft_line:0:1}" == $'\t' ]]; do
          _ft_line="${_ft_line:1}"
        done
        [[ -z "$_ft_line" ]] && continue
        # skip lines inside a multi-line array definition (VAR=(\n…\n))
        if [[ "$_ft_in_array" == "1" ]]; then
          [[ "$_ft_line" == *")" ]] && _ft_in_array=0
          continue
        fi
        [[ "$_ft_line" == \#* ]] && continue
        _ft_tok="${_ft_line%% *}"
        # decisions#300 item 12: a shell keyword introduces a command on the
        # SAME line — resolve it instead of discarding the line. A one-line
        # `for f in a b; do turso …; done` used to skip its only line and end
        # with an EMPTY first token (→ deny:allow-list:), and a `do turso …`
        # line was skipped outright. `for`/`select` resolve to the body after
        # `do`; `while`/`until`/`if`/`elif` to their condition command;
        # `then`/`do`/`else`/`!`/`{` to what follows; closers carry nothing.
        _ft_kw=1
        while [[ "$_ft_kw" == 1 ]]; do
          _ft_kw=0
          case "${_ft_tok%;}" in
            for|select)
              if [[ "$_ft_line" =~ [\;[:space:]]do[[:space:]]+(.*)$ ]]; then
                _ft_line="${BASH_REMATCH[1]}"; _ft_kw=1
              else
                _ft_line=""
              fi ;;
            while|until|if|elif|then|do|else|'!'|'{')
              _ft_line="${_ft_line#"$_ft_tok"}"; _ft_kw=1 ;;
            'fi'|'done'|'esac'|'}'|'case')
              _ft_line="" ;;
          esac
          if [[ "$_ft_kw" == 1 ]]; then
            while [[ "${_ft_line:0:1}" == " " || "${_ft_line:0:1}" == $'\t' || "${_ft_line:0:1}" == ";" ]]; do
              _ft_line="${_ft_line:1}"
            done
            [[ -z "$_ft_line" ]] && break
            _ft_tok="${_ft_line%% *}"
          fi
        done
        [[ -z "$_ft_line" ]] && continue
        # BUG-054 (juvantlabs/juvant-os-pm#140): the assignment (*=*) check MUST
        # run BEFORE the ##*/ path-strip. The old order stripped the path first,
        # which ate '=' out of an inline env-prefix token whose value contained
        # a '/' — e.g. TURSO_DATABASE_URL=libsql://host/db collapsed to the
        # fragment "db" — so the assignment branch never fired and the fragment
        # was treated as a binary and denied against the allow-list. Handle
        # assignments, then URL schemes, then strip confirmed binaries.
        #
        # Variable assignment (token contains '='):
        # • VAR=( with no ) on this line → enter array-skip mode.
        # • VAR=$(cmd …) → salvage cmd as the binary to check.
        # • VAR=(a b) single-line array → a var assignment, no binary. Skip.
        # • VAR=val [VAR2=val2 …] binary args → advance past ALL leading
        #   assignment tokens and resolve the real binary.
        if [[ "$_ft_tok" == *=* ]]; then
          if [[ "$_ft_line" == *"("* && "$_ft_line" != *")"* ]]; then
            _ft_in_array=1
            continue
          fi
          if [[ "$_ft_line" =~ \$\(([^[:space:]\|\&\;\)]+) ]]; then
            FIRST_TOKEN="${BASH_REMATCH[1]##*/}"
            break
          fi
          if [[ "$_ft_tok" == *"("* ]]; then
            continue
          fi
          # Inline env-prefix(es): skip every leading VAR=val token, then take
          # the next token as the binary. Loop (not a single hop) so
          # A=1 B=2 binary resolves to 'binary', not to 'B=2'.
          _ft_rest="$_ft_line"
          while [[ "$_ft_rest" == *" "* ]]; do
            _ft_head="${_ft_rest%% *}"
            [[ "$_ft_head" != *=* || "$_ft_head" == *"("* ]] && break
            _ft_rest="${_ft_rest#* }"
            while [[ "${_ft_rest:0:1}" == " " || "${_ft_rest:0:1}" == $'\t' ]]; do
              _ft_rest="${_ft_rest:1}"
            done
          done
          _ft_head="${_ft_rest%% *}"
          if [[ -z "$_ft_head" || "$_ft_head" == *=* ]]; then
            continue   # only assignments on this line, no binary
          fi
          _ft_tok="$_ft_head"   # fall through to URL-scheme check + path-strip
        fi
        # URL-scheme token (libsql://, https://, …): not a valid binary name.
        # Capture it raw for deny:parse: below rather than mangling via ##*/
        # (which would strip the scheme and silently misidentify the tail).
        if [[ "$_ft_tok" == *"://"* ]]; then
          FIRST_TOKEN="$_ft_tok"
          break
        fi
        # decisions#302: a control operator glued to the binary (`ls; rm …`,
        # `cmd&& …`, `cmd|…`) is not part of its name — the deny still stood,
        # but it reported the binary as `ls;`.
        _ft_tok="${_ft_tok%%[;\&|]*}"
        # Path-strip ONLY confirmed non-assignment binary tokens.
        _ft_tok="${_ft_tok##*/}"   # /opt/homebrew/bin/git → git
        case "$_ft_tok" in
          for|while|until|if|case|do|then|else|elif|\
          fi|done|function|local|declare|readonly|typeset) continue ;;
        esac
        FIRST_TOKEN="$_ft_tok"
        break
      done <<< "$COMMAND"
      # F-28 fix (v0.7.3+): check universal_allow (POSIX shell builtins
      # like cd, pushd, echo — not real binaries, harmless across roles)
      # before falling through to per-role allow-list. Without this,
      # the Skill's `cd /tmp/... && sqlite3 ...` compound commands
      # got denied on `cd` even though sqlite3 was in cso allow-list.
      # BUG-054 (juvantlabs/juvant-os-pm#140): tokens that remain unparseable
      # after all handling above (still contain '=' or a URL scheme '://')
      # get deny:parse: — distinct from deny:allow-list: ("valid binary, not
      # permitted"). Guard so they never reach the jq binary-lookup, which
      # would return a misleading allow/deny on a mangled token.
      if [[ -n "$FIRST_TOKEN" && ( "$FIRST_TOKEN" == *=* || "$FIRST_TOKEN" == *"://"* ) ]]; then
        DECISION="deny"
        DENY_REASON="deny:parse:$FIRST_TOKEN — token is not a valid binary (contains '=' or URL scheme '://'); cannot determine the command to check against the allow-list. Re-issue with an explicit binary (e.g. 'turso db shell …' rather than a bare URL or an env-only line). Refs: juvantlabs/juvant-os-pm#140 BUG-054"
      else
        UNIVERSAL_OK=$(jq -r --arg bin "$FIRST_TOKEN" \
          '(.universal_allow // []) | index($bin) // empty' \
          "$POLICY" 2>/dev/null || echo "")
        if [[ -z "$UNIVERSAL_OK" ]]; then
          ALLOW_OK=$(jq -r --arg role "$LOOKUP_ROLE" --arg bin "$FIRST_TOKEN" '
            . as $doc |
            [
              ($doc.agent_allow[$role] // [])[] |
              if startswith("@") then
                ($doc.tiers[ltrimstr("@")] // [])[]
              else
                .
              end
            ] | index($bin) // empty
          ' "$POLICY" 2>/dev/null || echo "")
          if [[ -z "$ALLOW_OK" ]]; then
            DECISION="deny"
            # BUG-039: self-remediating deny message — diagnostic prefix +
            # no-retry + native-tool remedy. Interim materialization of the
            # FEAT-025 deny contract until its full escalate-deny flow lands
            # (juvantlabs/juvant-os-pm#110). The old message ("Escalate to CoS
            # for tool-matrix-change") drove a ~50x retry-loop on file-IO-via-
            # shell because it named a remedy the agent cannot perform in-session.
            DENY_REASON="deny:allow-list:$FIRST_TOKEN — binary not in agent '$ROLE' allow-list (handbook ADR 0004 Track 2). Do NOT retry: repeating this command will never pass. If this is file I/O (cat/tee/heredoc, python3 -c, node -e fs.*), use the Write/Edit/Read tools instead — they are always available and not gated. For a genuine remote read (e.g. 'gh api .../contents'), that is read-only and legitimate — surface it rather than abandoning. Otherwise surface this denial to your parent (CoS) for a tool-matrix-change; do not work around it. Refs: FEAT-025 BUG-039 juvantlabs/juvant-os-pm#110"
          fi
        fi
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────
# Track 2b — Scope boundary guard (SYSTEM_INVARIANTS §4b / §4c)
# ─────────────────────────────────────────────
# Bidirectional block: project-scope agent → company DB (§4c hard-fail)
# and company-scope agent → project DB post-bootstrap (§4b hard-fail).
# Conservative whole-word token match on full command string.
# False positives acceptable; false negatives caught by Layer 3 drift audit.
if [[ "$TOOL_NAME" == "Bash" && "$DECISION" == "allow" ]]; then
  _T2B_CMD=$(echo "$EVENT_JSON" | jq -r '.tool_input.command // ""')

  # Detect a SQL WRITE (decisions#300 item 5, security_audit_log#150). The old
  # whole-word match over the full command fired on `replace(` and on verbs in
  # quoted prose, so a read-only `turso db shell project-x "SELECT replace(a,
  # 'b','c') FROM t"` from a company agent was denied as a §4b write. Now:
  #   • candidates = every quoted literal in the command, plus the unquoted
  #     remainder (heredoc bodies live there);
  #   • inside each, SQL string literals ('…', '' escaped) and comments are
  #     removed, then it is split into statements (on ; and newline);
  #   • a write verb counts only at STATEMENT START — INSERT (incl. INSERT OR
  #     REPLACE), UPDATE, DELETE, REPLACE INTO, CREATE/ALTER/DROP TABLE — or
  #     after a leading WITH … CTE. REPLACE alone is the string function.
  # shellcheck disable=SC1003
  _t2b_is_write() {
    local cmd="$1" cand st c i n q lit sql nolit
    local -a cands=()
    # Shell-level split: quoted literals → candidates; the rest → one more.
    n=${#cmd}; i=0; q=""; lit=""; local rest=""
    while [[ $i -lt $n ]]; do
      c="${cmd:$i:1}"
      if [[ -n "$q" ]]; then
        if [[ "$c" == "$q" ]]; then
          # SQL '' inside a single-quoted shell literal is two adjacent shell
          # quotes: keep it in the same candidate.
          if [[ "$q" == "'" && "${cmd:$((i + 1)):1}" == "'" ]]; then lit+="''"; i=$((i + 2)); continue; fi
          cands+=("$lit"); q=""; lit=""
        elif [[ "$q" == '"' && "$c" == '\' ]]; then
          i=$((i + 1)); lit+="${cmd:$i:1}"
        else
          lit+="$c"
        fi
      else
        case "$c" in
          "'"|'"') q="$c"; lit="" ;;
          *) rest+="$c" ;;
        esac
      fi
      i=$((i + 1))
    done
    [[ -n "$q" ]] && cands+=("$lit")
    cands+=("$rest")
    for cand in "${cands[@]}"; do
      # Strip SQL string literals ('…' with '' escapes) and comments.
      nolit=""; n=${#cand}; i=0; q=0
      while [[ $i -lt $n ]]; do
        c="${cand:$i:1}"
        if [[ "$q" == 1 ]]; then
          if [[ "$c" == "'" ]]; then
            if [[ "${cand:$((i + 1)):1}" == "'" ]]; then i=$((i + 2)); continue; fi
            q=0; nolit+="''"
          fi
        elif [[ "$c" == "'" ]]; then
          q=1
        elif [[ "$c" == "-" && "${cand:$((i + 1)):1}" == "-" ]]; then
          while [[ $i -lt $n && "${cand:$i:1}" != $'\n' ]]; do i=$((i + 1)); done
          continue
        elif [[ "$c" == "/" && "${cand:$((i + 1)):1}" == "*" ]]; then
          # /* … */ — a leading comment must not hide the statement's verb.
          i=$((i + 2))
          while [[ $i -lt $n && "${cand:$i:2}" != "*/" ]]; do i=$((i + 1)); done
          i=$((i + 2)); nolit+=" "
          continue
        else
          nolit+="$c"
        fi
        i=$((i + 1))
      done
      sql="${nolit//$'\n'/;}"
      IFS=';' read -ra _t2b_stmts <<< "$sql"
      for st in ${_t2b_stmts[@]+"${_t2b_stmts[@]}"}; do
        shopt -s nocasematch
        if [[ "$st" =~ ^[[:space:]]*(INSERT|UPDATE|DELETE|REPLACE[[:space:]]+INTO|CREATE[[:space:]]+TABLE|ALTER[[:space:]]+TABLE|DROP[[:space:]]+TABLE)([^A-Za-z0-9_]|$) ]] \
           || [[ "$st" =~ ^[[:space:]]*WITH[[:space:]].*[^A-Za-z0-9_](INSERT|UPDATE|DELETE|REPLACE[[:space:]]+INTO)[[:space:]] ]]; then
          shopt -u nocasematch
          return 0
        fi
        shopt -u nocasematch
      done
    done
    return 1
  }
  if _t2b_is_write "$_T2B_CMD"; then

    # BUG-056 (juvantlabs/juvant-os-pm#143): honor JUVANT_CONFIG like Track 2c/2d/2e — the hardcoded path
    # ignored the override, silently bypassing Track-2b in any fixture/testco
    # run and mis-resolving in future multi-config scenarios.
    _CFG="${JUVANT_CONFIG:-$SCRIPT_DIR/../.juvant/config.json}"
    _COMPANY_URL=$(jq -r '.turso_url // ""'      "$_CFG" 2>/dev/null || echo "")
    _COMPANY_DB=$(jq -r '.turso_db_name // ""'   "$_CFG" 2>/dev/null || echo "")

    # Classify DB target.
    # Match both libsql URL form AND short DB-name form (`turso db shell <name>`).
    # DB-name uses whole-word grep: "company-juvant" matches but
    # "company-juvant-external" does not. False positives acceptable per
    # Track 2b design; this fix closes the false negatives (BUG-033).
    _T2B_COMPANY=false
    _T2B_PROJECT=false
    _T2B_HIT=false
    if [[ -n "$_COMPANY_URL" && "$_T2B_CMD" == *"$_COMPANY_URL"* ]]; then
      _T2B_HIT=true
    elif [[ -n "$_COMPANY_DB" ]] && \
         echo "$_T2B_CMD" | grep -qE "(^|[^[:alnum:]_-])${_COMPANY_DB}([^[:alnum:]_-]|$)"; then
      _T2B_HIT=true
    fi
    if [[ "$_T2B_HIT" == "true" ]]; then
      _T2B_COMPANY=true
    else
      # Bug 1 fix: field is .value.url not .value.db_url
      while IFS= read -r _PU; do
        [[ -z "$_PU" || "$_PU" == "null" ]] && continue
        if [[ "$_T2B_CMD" == *"$_PU"* ]]; then _T2B_PROJECT=true; break; fi
      done < <(jq -r '.projects | to_entries[].value.url // empty' "$_CFG" 2>/dev/null)
      # Bug 2 fix: also match short DB-name form per project
      if [[ "$_T2B_PROJECT" == "false" ]]; then
        while IFS= read -r _PN; do
          [[ -z "$_PN" || "$_PN" == "null" ]] && continue
          if echo "$_T2B_CMD" | \
             grep -qE "(^|[^[:alnum:]_-])${_PN}([^[:alnum:]_-]|$)"; then
            _T2B_PROJECT=true; break
          fi
        done < <(jq -r '.projects | to_entries[].value.turso_db_name // empty' "$_CFG" 2>/dev/null)
      fi
    fi

    # Classify agent scope
    _COMPANY_ROLES=" cos cfo clo cmo cco cso cto chro cetho cro eng-platform vpe ca "
    _T2B_IS_CO=false
    _T2B_IS_PROJ=false
    if [[ -n "$ROLE" && "$ROLE" != "unknown" && "$ROLE" != "ceo" && "$ROLE" != "operator" ]]; then
      if echo "$_COMPANY_ROLES" | grep -q " $ROLE "; then
        _T2B_IS_CO=true
      else
        _T2B_IS_PROJ=true
      fi
    fi

    # Case a — §4c: project agent → company DB
    if [[ "$_T2B_IS_PROJ" == "true" && "$_T2B_COMPANY" == "true" ]]; then
      DECISION="deny"
      DENY_REASON="SCOPE BOUNDARY VIOLATION §4c (SYSTEM_INVARIANTS): project-scope agent '$ROLE' may not write to company DB. Write to project DB or route spec to company agent via CoS. Refs: FEAT-042 juvantlabs/juvant-os-pm#90"

    # Case b — §4b: company agent → project DB (post-bootstrap, with exceptions)
    elif [[ "$_T2B_IS_CO" == "true" && "$_T2B_PROJECT" == "true" ]]; then
      _BW=$(jq -r '.bootstrap_window // "0"' "$_CFG" 2>/dev/null || echo "0")
      _EXEMPT=false
      if [[ "$_BW" == "1" ]] && \
         [[ "$ROLE" == "chro" || "$ROLE" == "cos" || "$ROLE" == "cso" ]]; then
        _EXEMPT=true
      fi
      if [[ "$_EXEMPT" == "false" ]]; then
        DECISION="deny"
        DENY_REASON="SCOPE BOUNDARY VIOLATION §4b (SYSTEM_INVARIANTS): company-scope agent '$ROLE' may not write to project DB post-bootstrap. Refs: FEAT-042 juvantlabs/juvant-os-pm#90"
      fi
    fi

    # Case c — §4d: company agent inserting project-scoped content into company DB
    # Fires when: company agent + INSERT decisions + company DB + project ref in SQL.
    # Override: SQL contains 'company-wide' token → genuine company-scope exception.
    # False positives acceptable per Track 2b design; false negatives caught by Layer 3.
    if [[ "$_T2B_IS_CO" == "true" && "$_T2B_COMPANY" == "true" && \
          "$DECISION" == "allow" ]]; then
      if echo "$_T2B_CMD" | grep -qiE '\bINSERT\b.*\bdecisions\b|\bdecisions\b.*\bINSERT\b'; then
        if ! echo "$_T2B_CMD" | grep -qiE '\bcompany-wide\b'; then
          # Load project identifiers: slugs + optional repos[] array
          _T2B_PROJ_REFS=()
          while IFS= read -r _ref; do
            [[ -n "$_ref" && "$_ref" != "null" ]] && _T2B_PROJ_REFS+=("$_ref")
          done < <(jq -r '
            .projects | to_entries[] |
            .key,
            (.value.repos[]? // empty)
          ' "$_CFG" 2>/dev/null || true)
          for _ref in "${_T2B_PROJ_REFS[@]}"; do
            if echo "$_T2B_CMD" | \
               grep -qE "(^|[^[:alnum:]_/-])${_ref}([^[:alnum:]_/-]|$)"; then
              DECISION="deny"
              DENY_REASON="§4d AUTHORSHIP VIOLATION (SYSTEM_INVARIANTS): company-scope agent '$ROLE' is inserting a decisions row into company DB with content referencing project '${_ref}'. Return the finding to the project agent (PCA/Eng Lead); they author the row in project-${_ref} DB. Exception: include literal token 'company-wide' in title or rationale and re-issue. Refs: FEAT-045 FEAT-046 juvantlabs/juvant-os-pm#98"
              break
            fi
          done
        fi
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────
# Track 2c — Orchestrator boundary (SYSTEM_INVARIANTS §9)
# ─────────────────────────────────────────────
# Deny Write/Edit for ROLE='cos' (main thread) on files inside a
# project working tree. CoS is an orchestrator; it must dispatch to
# the appropriate project agent instead of editing project files directly.
# Company-level files (.juvant/, .claude/, *.md, hooks/, scripts/) are
# outside project working trees and remain fully accessible.
# Git and Bash operations (upstream sync, compile-templates, Turso
# queries) are unaffected — they go through Bash, not Write/Edit.
if [[ "$ROLE" == "cos" && "$DECISION" == "allow" ]]; then
  if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
    _T2C_PATH=$(echo "$EVENT_JSON" | \
      jq -r '.tool_input.path // .tool_input.file_path // ""' 2>/dev/null || echo "")
    if [[ -n "$_T2C_PATH" ]]; then
      _CFG_T2C="${JUVANT_CONFIG:-$SCRIPT_DIR/../.juvant/config.json}"
      while IFS= read -r _wt; do
        [[ -z "$_wt" || "$_wt" == "null" ]] && continue
        if [[ "$_T2C_PATH" == "$_wt"/* || "$_T2C_PATH" == "$_wt" ]]; then
          DECISION="deny"
          DENY_REASON="ORCHESTRATOR BOUNDARY (SYSTEM_INVARIANTS §9): main thread may not directly edit files in a project/component working tree '${_wt}'. Identify the correct agent (Eng Lead, PCA, Product Lead, the component's <slug>-maintainer, etc.) and dispatch via Task(). Refs: FEAT-047 + FEAT-053 juvantlabs/juvant-os-pm#100"
          break
        fi
        # FEAT-053: component working trees are gated too — the <slug>-maintainer
        # edits them, not the orchestrator.
      done < <(jq -r '(.projects[].working_tree // empty), (.components[]?.working_tree // empty)' "$_CFG_T2C" 2>/dev/null || true)
    fi
  fi
fi

# ─────────────────────────────────────────────
# Track 2d — Single-writer git gate (FEAT-047)
# ─────────────────────────────────────────────
# Only eng-lead (project scope) and eng-platform (company scope) may
# commit, push, or merge. Any other subagent attempting a git write
# operation is denied unconditionally — it must author a pr-spec and
# delegate to eng-lead via Task(). SYSTEM_INVARIANTS §4.
#
# CEO direct bypass: agent_type absent from hook event = main operator
# thread. Same bypass pattern as Track 4 (FEAT-040 Q2 design decision).
#
# Read-only git ops (pull, fetch, log, diff, status, show, clone) are
# not gated. git commit --amend and git push --force are already caught
# by the universal deny-list (Track 2).
#
# FEAT-052: the gate also covers gh WRITE operations. With the deprecated
# github MCP removed, gh is the GitHub mechanism and gh is broadly
# allow-listed, so writes must be restricted to the single writer the same
# way git writes are. Write patterns live in bash-policy.json
# (single_writer_gh_patterns); read-only gh (view/list/diff/checks, api
# GET) is not listed and stays open. gh api with field flags defaults to
# POST, so it is gated unless an explicit -X GET is present.
if [[ "$TOOL_NAME" == "Bash" && "$DECISION" == "allow" ]]; then
  _T2D_WRITE=0
  # decisions#272 (BUG-066): skip write-verb detection entirely for turso SQL
  # payloads. The SQL payload cannot invoke git or gh; prose in VALUES columns
  # that describes single-writer operations ("the git commit fixes…", "gh pr
  # create for…") would false-positive against these patterns. _TURSO_SQL_MODE
  # is set by Track 2 detection above; default to 0 when Track 2 did not run.
  if [[ "${_TURSO_SQL_MODE:-0}" -eq 0 ]]; then
  # Strip git's argument-taking GLOBAL options so a write verb behind a
  # directory redirect (`git -C /other push`, `git --work-tree=/other commit`)
  # is exposed. NOTE: `-c` is deliberately NOT in this list — it is also
  # bash's own `-c` flag, so stripping it ate the verb in `bash -c 'git push'`
  # (a regression); and `git -c key=val push` still leaves the verb reachable
  # by the looser match below, so stripping `-c` was never load-bearing.
  # decisions#300 item 5: scan the prose-free view (Track 2 above), so a write
  # verb mentioned inside quoted text (a VALUES column, a commit message body)
  # is not a write. Commands that evaluate code keep the full view.
  _T2D_VIEW="${_CMD_SCAN:-$COMMAND}"
  _GIT_NORM=$(printf '%s' "$_T2D_VIEW" | sed -E 's/(^|[[:space:]])(-C|--git-dir|--work-tree|--namespace|--exec-path)([[:space:]]+|=)[^[:space:]]+/ /g')
  # Match a git WRITE verb that may sit behind ANY number of intervening
  # tokens — no-arg globals (`--no-pager`, `--bare`), a quoted `-c` value with
  # internal spaces, or the shell wrapper in `bash -c 'git push'`. Biased to
  # OVER-detect: a read that merely mentions a verb as a standalone token may
  # be gated and must be re-issued — the safe direction for a single-writer
  # gate. (Anchored at a token boundary so `--grep=push` is not a verb.)
  # Trailing boundary is "non-letter or end" (not just whitespace) so the verb
  # is still detected when followed by a closing quote (`bash -c 'git push'`),
  # a `;`, `&`, etc. — while `pushed`/`commits` (verb + letter) do NOT match.
  if [[ "$_GIT_NORM" =~ git[[:space:]]+([^[:space:]]+[[:space:]]+)*(push|commit|merge)([^[:alpha:]]|$) ]]; then
    _T2D_WRITE=1
  fi
  if [[ "$_T2D_WRITE" -eq 0 && -f "$POLICY" ]]; then
    while IFS= read -r _ghp; do
      [[ -z "$_ghp" ]] && continue
      if [[ "$_T2D_VIEW" =~ $_ghp ]]; then _T2D_WRITE=1; break; fi
    done < <(jq -r '.single_writer_gh_patterns[]?' "$POLICY" 2>/dev/null)
  fi
  # gh api is a WRITE unless it is an explicit GET. A body can come from field
  # flags (-f/-F/--field/--raw-field) OR --input <file>; an explicit non-GET
  # method is a write even with no body. Three traps the naive form fell into,
  # all closed here:
  #   - CASE: gh upper-cases the method (strings.ToUpper), so `--method post`
  #     / `-X delete` are real writes — match case-insensitively (nocasematch;
  #     bash 3.2-safe, unlike ${v^^}).
  #   - COMPACT short flag: pflag/curl accept `-XPOST` (no separator) — so the
  #     -X form allows zero separators; --method (long) still requires one.
  #   - SCOPE: evaluate each shell SEGMENT (split on ; && || | & and drop a
  #     trailing # comment) independently, so a sibling read (`&& gh api … -X
  #     GET`) or a comment can't disable the write check for a real write in
  #     another segment.
  if [[ "$_T2D_WRITE" -eq 0 && "$COMMAND" =~ gh[[:space:]]+api ]]; then
    _gh_body="${COMMAND%%#*}"
    _gh_body=$(printf '%s' "$_gh_body" | sed -E 's/(&&|\|\||[;|&])/\n/g')
    shopt -s nocasematch
    while IFS= read -r _seg; do
      [[ "$_seg" =~ gh[[:space:]]+api ]] || continue
      # explicit GET on THIS segment ⇒ a read; leave it alone.
      if [[ "$_seg" =~ -X[[:space:]=]*GET ]] || [[ "$_seg" =~ --method[[:space:]=]+GET ]]; then
        continue
      fi
      if [[ "$_seg" =~ (-f|-F|--field|--raw-field|--input)([[:space:]]|=) ]] \
         || [[ "$_seg" =~ -X[[:space:]=]*(POST|PUT|PATCH|DELETE) ]] \
         || [[ "$_seg" =~ --method[[:space:]=]+(POST|PUT|PATCH|DELETE) ]]; then
        _T2D_WRITE=1; break
      fi
    done <<< "$_gh_body"
    shopt -u nocasematch
  fi
  fi  # _TURSO_SQL_MODE guard (decisions#272 BUG-066) — end of write-detection block
  if [[ "$_T2D_WRITE" -eq 1 ]]; then
    _T2D_AGENT_TYPE=$(echo "$EVENT_JSON" | jq -r '.agent_type // ""' 2>/dev/null || echo "")
    if [[ -n "$_T2D_AGENT_TYPE" ]]; then
      case "$ROLE" in
        *-eng-lead|eng-lead|eng-platform|*-maintainer|maintainer) ;;
        *)
          DECISION="deny"
          DENY_REASON="SINGLE-WRITER §4 (Track 2d / FEAT-047 + FEAT-052 + FEAT-053): only eng-lead (project scope), eng-platform (company scope), or a component's <slug>-maintainer (component scope, its own repo) may perform git or gh WRITE operations — git commit/push/merge, or gh pr/issue/release/repo/secret/workflow/api writes. Agent '$ROLE' must author the appropriate spec (pr-spec / gh-issue-spec / gh-project-update-spec / release-spec / deployment-spec) and delegate the write to the scope's single writer via Task(). Read-only gh (view/list/diff/checks/status, api GET, repo clone) is allowed — re-issue as a read if that was the intent."
          ;;
      esac

      # FEAT-054 — repo-scope the SCOPE-BOUND writers to their OWN repo(s)/tree(s).
      # eng-platform is company-broad and exempt. The owned set comes from the
      # registry (components[].{repo,working_tree,additional_working_trees} for a
      # maintainer; projects[<slug>].{github_repos|github_repo, working_tree,
      # additional_working_trees} for an eng-lead — N repos supported, e.g.
      # hardys). The command's target is parsed from an explicit gh repo
      # (-R/--repo or api repos/<O>/<R>) and/or a leading `cd <abs-path>`. A
      # target OUTSIDE the owned set is denied; an undeterminable target FAILS
      # OPEN to the role gate above (no false-deny on own-repo writes).
      if [[ "$DECISION" == "allow" ]]; then
        _CFG_T2D="${JUVANT_CONFIG:-$SCRIPT_DIR/../.juvant/config.json}"
        if [[ -f "$_CFG_T2D" ]]; then
          _OWNED=""
          case "$ROLE" in
            *-maintainer|maintainer)
              _OWNED=$(jq -r --arg r "$ROLE" '.components[]? | select(.maintainer==$r) | (.repo // empty), (.working_tree // empty), (.additional_working_trees[]? // empty)' "$_CFG_T2D" 2>/dev/null || true)
              ;;
            *-eng-lead)
              _SLUG="${ROLE%-eng-lead}"
              _OWNED=$(jq -r --arg s "$_SLUG" '.projects[$s]? | ((.github_repos // (if .github_repo then [(.github_repo.org + "/" + .github_repo.repo_name)] else [] end))[]? // empty), (.working_tree // empty), (.additional_working_trees[]? // empty)' "$_CFG_T2D" 2>/dev/null || true)
              ;;
          esac
          if [[ -n "$_OWNED" ]]; then
            _TGT_REPO=""; _TGT_TREE=""; _VIOL=""
            if [[ "$COMMAND" =~ (-R|--repo)[[:space:]=]+([A-Za-z0-9._-]+/[A-Za-z0-9._-]+) ]]; then
              _TGT_REPO="${BASH_REMATCH[2]}"
            elif [[ "$COMMAND" =~ repos/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+) ]]; then
              _TGT_REPO="${BASH_REMATCH[1]}"
            fi
            if [[ "$COMMAND" =~ (^|[\;\&[:space:]])cd[[:space:]]+(/[^[:space:]\;\&]+) ]]; then
              _TGT_TREE="${BASH_REMATCH[2]}"
            fi
            # git's own directory redirects target a tree just like `cd` does;
            # an absolute -C/--work-tree/--git-dir path outside the owned set
            # must be caught (else `git -C /other-tree push` evades repo-scope
            # even after passing the role gate). `-C` is parsed AFTER `cd` and
            # OVERRIDES it (no `-z` guard) — git changes its own CWD via -C
            # before doing anything, so `cd /owned && git -C /other push`
            # writes to /other, not /owned; the gate must check /other.
            if [[ "$COMMAND" =~ (-C|--work-tree|--git-dir)[[:space:]=]+(/[^[:space:]\;\&]+) ]]; then
              _TGT_TREE="${BASH_REMATCH[2]}"
            fi
            # Fail-closed on path traversal: the membership test below is a
            # string-prefix glob with no path normalization, so `/owned/../x`
            # would pass it while the kernel resolves it OUTSIDE the owned set.
            # A '..' segment in a repo target has no legitimate use here.
            if [[ -n "$_TGT_TREE" && "$_TGT_TREE" =~ (^|/)\.\.(/|$) ]]; then
              _VIOL="working tree '$_TGT_TREE' (path traversal '..' is not allowed)"
            fi
            if [[ -z "$_VIOL" && -n "$_TGT_REPO" ]] && ! printf '%s\n' "$_OWNED" | grep -qxF "$_TGT_REPO"; then
              _VIOL="repo '$_TGT_REPO'"
            fi
            if [[ -z "$_VIOL" && -n "$_TGT_TREE" ]]; then
              _IN=0
              while IFS= read -r _o; do
                [[ -z "$_o" ]] && continue
                [[ "$_TGT_TREE" == "$_o" || "$_TGT_TREE" == "$_o"/* ]] && { _IN=1; break; }
              done <<< "$_OWNED"
              [[ "$_IN" -eq 0 ]] && _VIOL="working tree '$_TGT_TREE'"
            fi
            if [[ -n "$_VIOL" ]]; then
              DECISION="deny"
              DENY_REASON="SINGLE-WRITER §4 repo-scope (Track 2d / FEAT-054): '$ROLE' may write only its own repo(s)/working-tree(s), but this command targets $_VIOL — outside its owned set. Author a spec and delegate to that scope's writer via Task(). (Undeterminable targets fail open to the role gate; an explicit cross-repo/cross-tree target is blocked.)"
            fi
          fi
        fi
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────
# Track 4 — Spec-lookup gate (FEAT-040 Layer 3)
# ─────────────────────────────────────────────
# For high-risk Bash action classes defined in bash-policy.json
# (gated_action_classes[]), requires an approved spec in the company
# decisions table before allowing. Classes currently gated:
#   infra-change     → deployment-spec | eng-platform-spec
#   db-schema-change → install-spec    | eng-platform-spec
#
# Bypass: agent_type absent from hook event = main operator thread
# (CEO direct session). Allowed unconditionally but INPUT_SUMMARY is
# prefixed with [CEO-BYPASS: <class>] so morning-brief can surface it
# as a retroactive spec obligation (FEAT-040 Q2 design decision).
if [[ "$DECISION" == "allow" && "$TOOL_NAME" == "Bash" && -f "$POLICY" ]]; then
  _T4_AGENT_TYPE=$(echo "$EVENT_JSON" | jq -r '.agent_type // ""' 2>/dev/null || echo "")
  _T4_CEO_DIRECT=0
  [[ -z "$_T4_AGENT_TYPE" ]] && _T4_CEO_DIRECT=1

  _T4_CMD=$(echo "$EVENT_JSON" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
  _T4_MATCHED_CLASS=""
  _T4_REQUIRED_CATS=""

  _T4_N=$(jq -r '.gated_action_classes | length' "$POLICY" 2>/dev/null || echo "0")
  _T4_I=0
  while [[ "$_T4_I" -lt "$_T4_N" && -z "$_T4_MATCHED_CLASS" ]]; do
    _T4_CLASS=$(jq -r ".gated_action_classes[$_T4_I].class" "$POLICY" 2>/dev/null || echo "")
    _T4_CATS=$(jq -r ".gated_action_classes[$_T4_I].required_spec_categories | join(\",\")" "$POLICY" 2>/dev/null || echo "")
    _T4_NP=$(jq -r ".gated_action_classes[$_T4_I].patterns | length" "$POLICY" 2>/dev/null || echo "0")
    _T4_J=0
    while [[ "$_T4_J" -lt "$_T4_NP" && -z "$_T4_MATCHED_CLASS" ]]; do
      _T4_PAT=$(jq -r ".gated_action_classes[$_T4_I].patterns[$_T4_J]" "$POLICY" 2>/dev/null || echo "")
      if [[ -n "$_T4_PAT" && "$_T4_CMD" =~ $_T4_PAT ]]; then
        _T4_MATCHED_CLASS="$_T4_CLASS"
        _T4_REQUIRED_CATS="$_T4_CATS"
      fi
      _T4_J=$(( _T4_J + 1 ))
    done
    _T4_I=$(( _T4_I + 1 ))
  done

  if [[ -n "$_T4_MATCHED_CLASS" ]]; then
    if [[ "$_T4_CEO_DIRECT" -eq 1 ]]; then
      INPUT_SUMMARY="[CEO-BYPASS: $_T4_MATCHED_CLASS] $INPUT_SUMMARY"
    else
      # Subagent: look up approved spec in Turso
      # shellcheck disable=SC1091
      . "$SCRIPT_DIR/lib/db.sh"
      _T4_CAT_SQL=$(echo "$_T4_REQUIRED_CATS" | tr ',' '\n' | sed "s/.*/'&'/" | tr '\n' ',' | sed 's/,$//')
      # COUNT(*) (not SELECT id) so a SUCCESSFUL query always yields a number
      # — "0" for no-spec, ">=1" for spec-found. An EMPTY result therefore
      # means the query did not run (DB unreachable / timed out), which is
      # distinct from "no approved spec". juvant_db_query's rc cannot tell
      # these apart (its turso path pipes through grep, whose rc is 1 for both
      # an empty result and a failure), so we discriminate on the value.
      _T4_CNT=$(juvant_db_query \
        "SELECT COUNT(*) FROM decisions WHERE category IN ($_T4_CAT_SQL) AND status='approved' AND created_at > datetime('now','-7 days');" \
        2>/dev/null | grep -E '^[0-9]+$' | head -1 || echo "")
      if [[ -z "$_T4_CNT" ]]; then
        # DB unreachable — cannot verify. Still fail-closed (deny), but with a
        # DISTINCT, retryable message: do NOT tell the agent to author a spec
        # (a transient infra hiccup is not a missing-spec condition).
        DECISION="deny"
        DENY_REASON="SPEC GATE (FEAT-040 Layer 3): could not verify an approved spec for action class '$_T4_MATCHED_CLASS' — the decisions DB is unreachable (transient infrastructure error, NOT a missing spec). Do not author a new spec; retry shortly, and if it persists surface to eng-platform."
      elif [[ "$_T4_CNT" == "0" ]]; then
        DECISION="deny"
        DENY_REASON="SPEC GATE (FEAT-040 Layer 3): action class '$_T4_MATCHED_CLASS' requires an approved spec [${_T4_REQUIRED_CATS}] created within 7 days. None found. Author a spec via the appropriate agent, obtain CEO approval, then retry."
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────
# Track 2e — sensitive-space deny-list (ADR 0025 / ADR 0027)
# ─────────────────────────────────────────────
# Deny-by-default perimeter for MCP tool calls targeting a SENSITIVE
# document space — a Universal-CONFIDENTIAL library that had to be promoted
# to an org container because it has an external party (e.g. legal-ip read
# by outside counsel). Keyed on (AGENT_ROLE, driveId match || path-pattern
# match). Enforcement lives HERE, not in the MCP server: the server is one
# delegated token in one process and cannot authenticate the caller
# (ADR 0025); AGENT_ROLE is spawn-set and non-spoofable — the framework's
# real trust floor.
#
# Rules are INSTANCE-LOCAL — read from .juvant/config.json
#   .security.space_access[]   (gitignored; NEVER in a synced file — ADR 0025)
# Each entry:
#   { "space": "<name>", "tool_prefix": "mcp__<server>__",
#     "drive_ids": ["b!…"], "path_patterns": ["legal-ip","/IP/"],
#     "allowlist": ["lex","atlas","cso"] }
# Absent / empty .security.space_access ⇒ this Track is a no-op (the default
# framework state — most instances have no promoted sensitive space).
#
# Coverage gates (harvested from the instance reference proven by the canary
# that gated go-live, decisions#210):
#   (a) path-only ops also match the space's path_patterns;
#   (b) search ops must carry a site/drive scope, else deny;
#   (c) resolution helpers refuse to surface the sensitive driveId;
#   (d) any op with no hook-visible target + unclassified ⇒ deny.
# Op classification A=Read / B=Write / C=Escalation pre-empts future tools.
# Every resolved op writes security_audit_log severity=high + same-turn CoS
# notification (allowlisted agents tagged expected=true — the row still fires,
# to catch authorized-but-anomalous access).
_T2E_CFG="${JUVANT_CONFIG:-$SCRIPT_DIR/../.juvant/config.json}"
if [[ -f "$_T2E_CFG" ]] && jq -e '(.security.space_access // []) | length > 0' "$_T2E_CFG" >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/lib/db.sh"
  _t2e_esc() { printf '%s' "$1" | sed "s/'/''/g"; }

  _T2E_ARGS=$(echo "$EVENT_JSON" | jq -c '.tool_input // {}' 2>/dev/null || echo "{}")
  _T2E_DRIVE_ID=$(echo "$_T2E_ARGS" | jq -r '.drive_id // .driveId // ""' 2>/dev/null || echo "")
  _T2E_SITE_ID=$(echo "$_T2E_ARGS"  | jq -r '.site_id // .siteId // ""'   2>/dev/null || echo "")
  _T2E_PATH=$(echo "$_T2E_ARGS"     | jq -r '.path // .file_path // .folder_path // .item_path // ""' 2>/dev/null || echo "")

  # Generic op classification (Graph-like MCPs). A=Read B=Write C=Escalation.
  _T2E_OP_CLASS="unclassified"
  case "$TOOL_NAME" in
    # Read verbs FIRST (first-match-wins) so a read whose name merely contains an
    # escalation token — list_shared_drives, list_members, get_permissions — is
    # classified A, not C (bug_011). Genuine escalation ops (create_sharing_link,
    # add_member, grant_access) carry no read verb and fall through to C.
    *list*|*get*|*read*|*search*|*resolve*|*whoami*|*who_am_i*|*download*) _T2E_OP_CLASS="A" ;;
    *shar*|*permission*|*invite*|*grant*|*member*|*role*|*access*) _T2E_OP_CLASS="C" ;;
    *upload*|*create*|*update*|*delete*|*write*|*move*|*copy*|*rename*|*put*) _T2E_OP_CLASS="B" ;;
  esac
  _T2E_HAS_TARGET=false
  [[ -n "$_T2E_DRIVE_ID" || -n "$_T2E_SITE_ID" || -n "$_T2E_PATH" ]] && _T2E_HAS_TARGET=true

  _T2E_NSPACE=$(jq -r '.security.space_access | length' "$_T2E_CFG" 2>/dev/null || echo 0)
  _t2e_i=0
  while [[ "$_t2e_i" -lt "$_T2E_NSPACE" ]]; do
    _SP=$(jq -c ".security.space_access[$_t2e_i]" "$_T2E_CFG" 2>/dev/null || echo "{}")
    _t2e_i=$(( _t2e_i + 1 ))
    _SP_PREFIX=$(echo "$_SP" | jq -r '.tool_prefix // ""')
    [[ -n "$_SP_PREFIX" && "$TOOL_NAME" == "$_SP_PREFIX"* ]] || continue
    _SP_NAME=$(echo "$_SP" | jq -r '.space // "sensitive-space"')

    # allowlist membership (role or <project>-role)
    _SP_ALLOW=false
    while IFS= read -r _al; do
      [[ -z "$_al" ]] && continue
      [[ "$ROLE" == "$_al" || "$ROLE" == *"-$_al" ]] && { _SP_ALLOW=true; break; }
    done < <(echo "$_SP" | jq -r '.allowlist[]?' 2>/dev/null)

    # driveId hit (exact) + arg-contains (gate-c resolution helpers)
    _SP_DRIVE_HIT=false; _SP_DRIVE_IN_ARGS=false
    while IFS= read -r _did; do
      [[ -z "$_did" ]] && continue
      [[ "$_T2E_DRIVE_ID" == "$_did" ]] && _SP_DRIVE_HIT=true
      [[ "$_T2E_ARGS" == *"$_did"* ]] && _SP_DRIVE_IN_ARGS=true
    done < <(echo "$_SP" | jq -r '.drive_ids[]?' 2>/dev/null)

    # path-pattern hit (gate a)
    _SP_PATH_HIT=false
    while IFS= read -r _pp; do
      [[ -z "$_pp" ]] && continue
      [[ "$_T2E_PATH" == *"$_pp"* ]] && _SP_PATH_HIT=true
    done < <(echo "$_SP" | jq -r '.path_patterns[]?' 2>/dev/null)

    if [[ "$_SP_ALLOW" == "false" && "$DECISION" == "allow" ]]; then
      if [[ "$TOOL_NAME" == *"search"* && -z "$_T2E_DRIVE_ID" && -z "$_T2E_SITE_ID" ]]; then
        # gate (b): search must be scope-bound
        DECISION="deny"
        DENY_REASON="SPACE-ACCESS POLICY (ADR 0025 gate-b): a search on '$_SP_PREFIX' must be pre-scoped to a site_id or drive_id for non-allowlisted agents. Agent '$ROLE' is not in the '${_SP_NAME}' allowlist. Re-scope explicitly, or route via an allowlisted agent."
      elif [[ "$TOOL_NAME" == *"resolve"* || "$TOOL_NAME" == *"get_drive"* || "$TOOL_NAME" == *"get_site"* || ( "$TOOL_NAME" == *"list"* && ( "$TOOL_NAME" == *"drive"* || "$TOOL_NAME" == *"site"* ) ) ]]; then
        # gate (c): drive/site enumeration + resolution. Denied UNCONDITIONALLY
        # for non-allowlisted agents (bug_010) — blind enumeration on a server
        # that hosts a sensitive space would surface the sensitive driveId, which
        # the perimeter exists to hide. Catches list_drives, list_shared_drives,
        # list_sites, resolve_*, get_drive, get_site. Scoped file ops
        # (list_files / get_file_content on a specific drive) are NOT enumeration
        # and pass here — they are caught by core/path matching if sensitive.
        DECISION="deny"
        DENY_REASON="SPACE-ACCESS POLICY (ADR 0025 gate-c): drive/site enumeration or resolution on '$_SP_PREFIX' is denied for non-allowlisted agent '$ROLE' — only the '${_SP_NAME}' allowlist may enumerate or resolve identities on a server hosting a sensitive space. Use an explicitly-scoped op, or route via the allowlist."
      elif [[ "$_SP_DRIVE_HIT" == "true" || "$_SP_PATH_HIT" == "true" ]]; then
        # core: driveId hit || path-pattern hit
        DECISION="deny"
        DENY_REASON="SPACE-ACCESS POLICY (ADR 0025 Class ${_T2E_OP_CLASS}): agent '$ROLE' is not in the '${_SP_NAME}' allowlist. Access to the sensitive document space is denied; route this request via an allowlisted agent."
      elif [[ "$_T2E_HAS_TARGET" == "false" ]]; then
        # gate (d): NO hook-visible target → deny regardless of op-class
        # (deny-by-default, ADR 0025 clause d; bug_011). A target-less op on a
        # server hosting a sensitive space may return everything; the previous
        # `unclassified`-only restriction let mis-/well-classified target-less
        # reads (e.g. list_members '{}') slip through.
        DECISION="deny"
        DENY_REASON="SPACE-ACCESS POLICY (ADR 0025 gate-d + deny-by-default): tool '$TOOL_NAME' has no hook-visible target — denied for non-allowlisted agent '$ROLE' on a server hosting the '${_SP_NAME}' space. Re-issue with an explicit non-sensitive site/drive/path scope, or route via the allowlist."
      fi
    fi

    # Condition-#1 high-severity audit + CoS alert: ONLY on actual evidence the
    # op touched the space — a driveId/path hit, or the sensitive driveId in the
    # args. Precautionary gate-b/c/d denies (recon attempts that did NOT touch
    # the space) are still DENIED but are not alerted as space incidents
    # (bug_005 — else every unscoped search / unclassified probe fans out a false
    # legal-ip alert). Allowlisted agents still fire the row (expected=true) to
    # catch authorized-but-anomalous access.
    _SP_AUDIT=false
    [[ "$_SP_DRIVE_HIT" == "true" || "$_SP_PATH_HIT" == "true" || "$_SP_DRIVE_IN_ARGS" == "true" ]] && _SP_AUDIT=true
    if [[ "$_SP_AUDIT" == "true" ]]; then
      _SP_EXPECTED="false"; [[ "$_SP_ALLOW" == "true" ]] && _SP_EXPECTED="true"
      _SP_FINDING="space-access ${_T2E_OP_CLASS} op on '${_SP_NAME}' by agent '${ROLE}' (expected=${_SP_EXPECTED}); tool=${TOOL_NAME}; drive_match=${_SP_DRIVE_HIT}; path_match=${_SP_PATH_HIT}; decision=${DECISION}"
      # Structured category derived from (op-class, decision) so Layer-5 / CSO
      # roll-ups filter correctly (bug_004 — not every row is 'unauthorized-write').
      case "${_T2E_OP_CLASS}:${DECISION}" in
        C:deny) _SP_CATEGORY="unauthorized-escalation" ;;
        B:deny) _SP_CATEGORY="unauthorized-write" ;;
        A:deny) _SP_CATEGORY="unauthorized-read" ;;
        *:deny) _SP_CATEGORY="unauthorized-access" ;;
        *)      _SP_CATEGORY="access-event" ;;
      esac
      # Spool the audit row instead of writing it inline (FEAT-051). The
      # allow/deny decision was already computed above and does NOT depend on
      # this write, so it must not sit on the gating path — a synchronous
      # network INSERT here adds latency to (or, on a degraded backend, stalls)
      # every sensitive-space tool call. The async append is local and
      # hang-impossible; drain-audit-spool flushes it to security_audit_log
      # out-of-band. (This is the very rule the notification block below already
      # cites; the INSERT had simply not been converted.)
      juvant_db_exec_async "INSERT INTO security_audit_log
        (auditor, scope, audit_type, layer, finding, severity, category, status)
        VALUES
        ('hook:pre-tool-use', 'company', 'incident', 'agents',
         '$(_t2e_esc "$_SP_FINDING")', 'high', '$(_t2e_esc "$_SP_CATEGORY")', 'open');" \
        || echo "[pre-tool-use] WARN: failed to spool security_audit_log for space-access op" >&2

      _SP_MSG="[SECURITY ALERT] sensitive-space op: space=${_SP_NAME} agent=${ROLE} tool=${TOOL_NAME} decision=${DECISION} expected=${_SP_EXPECTED} (ADR 0025)"
      # Notifications are fire-and-forget — NOT a precondition of the allow/deny
      # decision, so they must not block the gating path (bug_003; same rule as
      # FEAT-051 for the audit INSERT). Backgrounded with fds closed so the hook
      # emits its decision immediately instead of waiting up to ~20s on a
      # degraded network.
      _SP_WEBHOOK=$(jq -r '.notifications.teams_webhooks.approvals // ""' "$_T2E_CFG" 2>/dev/null || echo "")
      if [[ -n "$_SP_WEBHOOK" ]]; then
        _SP_CARD=$(jq -n --arg msg "$_SP_MSG" '{type:"AdaptiveCard","$schema":"http://adaptivecards.io/schemas/adaptive-card.json",version:"1.4",body:[{type:"TextBlock",text:$msg,wrap:true}]}')
        curl -s --connect-timeout 5 --max-time 10 -X POST "$_SP_WEBHOOK" \
          -H "Content-Type: application/json" -d "$_SP_CARD" >/dev/null 2>&1 &
      fi
      _SP_TG_TOKEN=$(jq -r '.notifications.telegram_bot_token // ""' "$_T2E_CFG" 2>/dev/null || echo "")
      _SP_TG_CHAT=$(jq -r '.notifications.telegram_chat_id // ""' "$_T2E_CFG" 2>/dev/null || echo "")
      if [[ -n "$_SP_TG_TOKEN" && -n "$_SP_TG_CHAT" ]]; then
        curl -s --connect-timeout 5 --max-time 10 -X POST \
          "https://api.telegram.org/bot${_SP_TG_TOKEN}/sendMessage" \
          -d "chat_id=${_SP_TG_CHAT}" --data-urlencode "text=${_SP_MSG}" >/dev/null 2>&1 &
      fi
    fi
  done
fi

# ─────────────────────────────────────────────
# Track 2g — per-agent shared-mailbox gate (decisions#301 K2)
# ─────────────────────────────────────────────
# m365-mail-mcp-server enforces ONE server-side allowlist
# (M365_MAIL_ALLOWED_SHARED_USERS) — the union of every shared mailbox the
# instance uses — so any agent that loads the server could read ALL of them
# (decisions#301 risk R1), and its write-class tools were bounded only by the
# matrix and the prompt (R2). Same reasoning as Track 2e: the server holds one
# delegated token and cannot authenticate the caller; the agent identity
# (agent_type / AGENT_ROLE) is only visible here.
#
# Policy is INSTANCE-LOCAL (.juvant/config.json, never synced):
#   "shared_mailboxes": {
#     "tool_prefix": "mcp__m365-mail__",            (optional, this default)
#     "main_thread": "explicit",                     (optional, see below)
#     "by_agent": {
#       "cfo": [ { "upn": "finance@<domain>", "scope": "read" } ],
#       "cco": [] } }
# Absent .shared_mailboxes.by_agent ⇒ this Track is a no-op.
#
# Gated calls: tool name starts with tool_prefix AND tool_input.shared_user is
# non-empty. Calls on the caller's OWN delegated mailbox (no shared_user) are
# out of scope and untouched.
#   • the agent must have a by_agent entry whose upn == shared_user
#     (case-insensitive), else deny;
#   • op class from the tool's verb: A (list/get/search/download) needs scope
#     read or readwrite; B (create/update/mark/move/delete/send/reply/forward)
#     needs readwrite; anything unclassified is denied (deny-by-default).
# Main thread (no agent_type in the event — the CEO-present CoS session) is
# governed by .shared_mailboxes.main_thread:
#   "explicit"         (DEFAULT) — treated as role 'cos': needs by_agent.cos;
#   "ceo_present_read" — class A allowed on ANY upn that some by_agent entry
#                        allowlists; class B still needs a cos readwrite entry;
#   "deny"             — every shared-mailbox call from the main thread denied.
# Every gated call (allow or deny) writes a security_audit_log row (high on
# deny, info on allow) for the CSO drift check; a deny also notifies.
_T2G_CFG="${JUVANT_CONFIG:-$SCRIPT_DIR/../.juvant/config.json}"
if [[ "$DECISION" == "allow" && -f "$_T2G_CFG" ]] \
   && jq -e '(.shared_mailboxes.by_agent // null) | type == "object"' "$_T2G_CFG" >/dev/null 2>&1; then
  _T2G_PREFIX=$(jq -r '.shared_mailboxes.tool_prefix // "mcp__m365-mail__"' "$_T2G_CFG" 2>/dev/null || echo "mcp__m365-mail__")
  _T2G_UPN=""
  if [[ "$TOOL_NAME" == "$_T2G_PREFIX"* ]]; then
    _T2G_UPN=$(echo "$EVENT_JSON" | jq -r '.tool_input.shared_user // ""' 2>/dev/null || echo "")
  fi
  if [[ -n "$_T2G_UPN" ]]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/lib/db.sh"
    _t2g_esc() { printf '%s' "$1" | sed "s/'/''/g"; }
    _T2G_UPN_LC=$(printf '%s' "$_T2G_UPN" | tr '[:upper:]' '[:lower:]')

    # Op class from the tool verb. The live name is
    # mcp__m365-mail__m365-mail_<tool>; strip the prefix and the optional
    # server-name stem to reach <tool>.
    _T2G_TOOL="${TOOL_NAME#"$_T2G_PREFIX"}"
    _T2G_TOOL="${_T2G_TOOL#m365-mail_}"
    case "$_T2G_TOOL" in
      list_*|get_*|search_*|download_*)                                   _T2G_CLASS="A" ;;
      create_*|update_*|mark_*|move_*|delete_*|send_*|reply_*|forward_*)  _T2G_CLASS="B" ;;
      *)                                                                  _T2G_CLASS="unclassified" ;;
    esac

    _T2G_AGENT_TYPE=$(echo "$EVENT_JSON" | jq -r '.agent_type // ""' 2>/dev/null || echo "")
    _T2G_MAIN=false; [[ -z "$_T2G_AGENT_TYPE" ]] && _T2G_MAIN=true
    _T2G_MODE=$(jq -r '.shared_mailboxes.main_thread // "explicit"' "$_T2G_CFG" 2>/dev/null || echo "explicit")
    _T2G_ROLE="$ROLE"
    [[ "$_T2G_MAIN" == "true" ]] && _T2G_ROLE="cos"

    # Scope of the agent's entry for this upn ("" = not allowlisted).
    _t2g_scope_for() {
      jq -r --arg r "$1" --arg u "$_T2G_UPN_LC" '
        [ (.shared_mailboxes.by_agent[$r] // [])[]
          | select((.upn // "" | ascii_downcase) == $u) | (.scope // "read") ]
        | if any(. == "readwrite") then "readwrite" elif length > 0 then .[0] else "" end
      ' "$_T2G_CFG" 2>/dev/null || echo ""
    }
    _T2G_SCOPE=$(_t2g_scope_for "$_T2G_ROLE")
    _T2G_BASIS="by_agent.${_T2G_ROLE}"
    if [[ "$_T2G_MAIN" == "true" && "$_T2G_MODE" == "ceo_present_read" && "$_T2G_CLASS" == "A" && -z "$_T2G_SCOPE" ]]; then
      # Option (a): a CEO-present session may READ any mailbox the instance
      # allowlists for some agent — never one that no agent is allowed.
      if jq -e --arg u "$_T2G_UPN_LC" '
           [ .shared_mailboxes.by_agent[][]? | (.upn // "" | ascii_downcase) ] | index($u) != null
         ' "$_T2G_CFG" >/dev/null 2>&1; then
        _T2G_SCOPE="read"; _T2G_BASIS="main_thread=ceo_present_read"
      fi
    fi

    _T2G_DECISION="allow"; _T2G_WHY=""
    if [[ "$_T2G_MAIN" == "true" && "$_T2G_MODE" == "deny" ]]; then
      _T2G_DECISION="deny"
      _T2G_WHY="main thread is not allowed shared-mailbox access (shared_mailboxes.main_thread=deny)"
    elif [[ -z "$_T2G_SCOPE" ]]; then
      _T2G_DECISION="deny"
      _T2G_WHY="agent '${_T2G_ROLE}' is not allowlisted for shared mailbox '${_T2G_UPN}'"
    elif [[ "$_T2G_CLASS" == "unclassified" ]]; then
      _T2G_DECISION="deny"
      _T2G_WHY="tool '${_T2G_TOOL}' is not a recognised read or write operation (deny-by-default)"
    elif [[ "$_T2G_CLASS" == "B" && "$_T2G_SCOPE" != "readwrite" ]]; then
      _T2G_DECISION="deny"
      _T2G_WHY="'${_T2G_TOOL}' is a write-class operation and agent '${_T2G_ROLE}' has scope=${_T2G_SCOPE} on '${_T2G_UPN}'"
    elif [[ "$_T2G_SCOPE" != "read" && "$_T2G_SCOPE" != "readwrite" ]]; then
      _T2G_DECISION="deny"
      _T2G_WHY="unknown scope '${_T2G_SCOPE}' for agent '${_T2G_ROLE}' on '${_T2G_UPN}'"
    fi

    if [[ "$_T2G_DECISION" == "deny" ]]; then
      DECISION="deny"
      DENY_REASON="MAILBOX-ACCESS POLICY (decisions#301 K2): ${_T2G_WHY}. Route the request via the agent that owns this mailbox, or record a matrix change (CTO proposes, CSO reviews, CEO approves) to extend .shared_mailboxes.by_agent."
    fi

    _T2G_FINDING="shared-mailbox ${_T2G_CLASS} op on '${_T2G_UPN}' by agent '${_T2G_ROLE}' (main_thread=${_T2G_MAIN}, basis=${_T2G_BASIS}, scope=${_T2G_SCOPE:-none}); tool=${TOOL_NAME}; decision=${_T2G_DECISION}"
    if [[ "$_T2G_DECISION" == "deny" ]]; then
      case "$_T2G_CLASS" in
        B) _T2G_CATEGORY="unauthorized-write" ;;
        A) _T2G_CATEGORY="unauthorized-read" ;;
        *) _T2G_CATEGORY="unauthorized-access" ;;
      esac
      _T2G_SEV="high"
    else
      _T2G_CATEGORY="access-event"; _T2G_SEV="info"
    fi
    # Spooled, off the gating path (FEAT-051), like Track 2e.
    juvant_db_exec_async "INSERT INTO security_audit_log
      (auditor, scope, audit_type, layer, finding, severity, category, status)
      VALUES
      ('hook:pre-tool-use', 'company', 'incident', 'agents',
       '$(_t2g_esc "$_T2G_FINDING")', '${_T2G_SEV}', '$(_t2g_esc "$_T2G_CATEGORY")', 'open');" \
      || echo "[pre-tool-use] WARN: failed to spool security_audit_log for shared-mailbox op" >&2

    if [[ "$_T2G_DECISION" == "deny" ]]; then
      _T2G_MSG="[SECURITY ALERT] shared-mailbox op denied: mailbox=${_T2G_UPN} agent=${_T2G_ROLE} tool=${_T2G_TOOL} class=${_T2G_CLASS} (decisions#301 K2)"
      # Fire-and-forget, fds closed — never on the gating path (Track 2e rule).
      _T2G_WEBHOOK=$(jq -r '.notifications.teams_webhooks.approvals // ""' "$_T2G_CFG" 2>/dev/null || echo "")
      if [[ -n "$_T2G_WEBHOOK" ]]; then
        _T2G_CARD=$(jq -n --arg msg "$_T2G_MSG" '{type:"AdaptiveCard","$schema":"http://adaptivecards.io/schemas/adaptive-card.json",version:"1.4",body:[{type:"TextBlock",text:$msg,wrap:true}]}')
        curl -s --connect-timeout 5 --max-time 10 -X POST "$_T2G_WEBHOOK" \
          -H "Content-Type: application/json" -d "$_T2G_CARD" >/dev/null 2>&1 &
      fi
      _T2G_TG_TOKEN=$(jq -r '.notifications.telegram_bot_token // ""' "$_T2G_CFG" 2>/dev/null || echo "")
      _T2G_TG_CHAT=$(jq -r '.notifications.telegram_chat_id // ""' "$_T2G_CFG" 2>/dev/null || echo "")
      if [[ -n "$_T2G_TG_TOKEN" && -n "$_T2G_TG_CHAT" ]]; then
        curl -s --connect-timeout 5 --max-time 10 -X POST \
          "https://api.telegram.org/bot${_T2G_TG_TOKEN}/sendMessage" \
          -d "chat_id=${_T2G_TG_CHAT}" --data-urlencode "text=${_T2G_MSG}" >/dev/null 2>&1 &
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────
# Track 2f — guardrail-config tamper floor (FEAT-064)
# ─────────────────────────────────────────────
# In a deployed instance the structural-safety files — the PreToolUse gate
# scripts (hooks/*.sh, hooks/lib/*.sh) and the universal deny-list
# (hooks/bash-policy.json) — are framework artifacts that arrive via upstream
# sync, never by a live agent edit. Deny Write/Edit AND Bash writes that target
# them, so an agent cannot weaken its own guardrails mid-session. The deny is
# itself audit-logged by Track 3 below (the attempt leaves a forensic trail).
#
# NOT covered here: .claude/settings.json — the Skill legitimately edits its
# permissions.allow / additionalDirectories at bootstrap and project-add. Its
# changes are instead RECORDED by the ConfigChange forensic hook (FEAT-062):
# prevention for the hook files, detection for settings.json.
#
# Adopter-scoped — framework development of these very files happens in the
# upstream repo. JUVANT_FRAMEWORK_DEV is tri-state:
#   1     → exempt (framework dev / fork contributor)
#   0     → enforce (the test suite uses this to simulate an adopter)
#   unset → auto: exempt iff `origin` is the canonical upstream juvantlabs/juvant-os
if [[ "$DECISION" == "allow" && ( "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Bash" ) ]]; then
  _fw_dev=0
  case "${JUVANT_FRAMEWORK_DEV:-auto}" in
    1) _fw_dev=1 ;;
    0) _fw_dev=0 ;;
    *) _gr_origin=$(git -C "$SCRIPT_DIR/.." remote get-url origin 2>/dev/null || echo "")
       [[ "$_gr_origin" =~ (^|[/:])juvantlabs/juvant-os(\.git)?$ ]] && _fw_dev=1 ;;
  esac
  if [[ "$_fw_dev" -eq 0 ]]; then
    # The protected-path set lives in hooks/lib/guardrail-paths.sh, shared with
    # the SessionStart integrity check (decisions#303 R1 + B2): gate scripts,
    # bash-policy.json, helpers/*.sh, scripts/*.sh, the audit spool family and
    # .juvant/backups/. tests/ is never protected (decisions#300 item 9).
    # shellcheck disable=SC1091
    if [[ -f "$SCRIPT_DIR/lib/guardrail-paths.sh" ]]; then
      . "$SCRIPT_DIR/lib/guardrail-paths.sh"
    else
      # Lib missing (partial sync / deletion): keep the original hooks/ floor so
      # the gate scripts themselves stay protected; the integrity check flags it.
      juvant_guardrail_is_path() {
        [[ "$1" =~ (^|/)tests/ ]] && return 1
        [[ "$1" =~ (^|/)hooks(/|$) ]]
      }
      juvant_guardrail_cd_dir() { [[ "${1%/}" =~ (^|/)hooks(/lib)?$ ]] && printf 'hooks'; }
      juvant_guardrail_raw_ref() { [[ "$1" =~ hooks/ && ! "$1" =~ tests/hooks/ ]]; }
    fi
    _gr_cwd=""   # protected dir entered by a preceding `cd` in the same command
    _gr_is_path() { juvant_guardrail_is_path "$1" "$_gr_cwd"; }
    if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
      _gr_tgt=$(echo "$EVENT_JSON" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
      # Absolute paths inside this repo are checked relative to its root.
      _gr_tgt_rel="${_gr_tgt#"$(cd "$SCRIPT_DIR/.." && pwd)"/}"
      if _gr_is_path "$_gr_tgt_rel"; then
        DECISION="deny"
        DENY_REASON="guardrail tamper floor (Track 2f / FEAT-064, decisions#303): $TOOL_NAME to '$_gr_tgt' is denied in a deployed instance — gate scripts, bash-policy.json, helpers/, scripts/, the audit spool and its backups change via upstream sync or their own helper process, not live agent edits. (Framework dev: export JUVANT_FRAMEWORK_DEV=1.)"
      fi
    else
      # Bash (decisions#300 item 4, security_audit_log#148b). The original
      # floor only matched a redirect / tee / `sed -i` naming the file, so
      # `git checkout|restore|rm|mv`, `cp x hooks/…`, `find hooks -delete`,
      # `cd hooks && rm …` and interpreter writes (python3/node/perl
      # `open('hooks/…','w')`) all passed. The scan is now:
      #   1. raw scan — an interpreter, `bash -c`, `eval`, command
      #      substitution or a heredoc in a command that mentions a guardrail
      #      path → deny (their write target lives inside code we don't parse);
      #   2. per segment (split on unquoted ; & | newline ( ) `) — a segment
      #      that references a guardrail path is allowed only for a recognised
      #      read-only verb; any redirect onto a guardrail path → deny.
      # The single sanctioned Bash write is the upstream-sync apply step
      # (JUVANT_OS.md "Upstream sync" step 7): `git checkout upstream/main --
      # <file>` / `git restore --source=upstream/main`, and only while the
      # `upstream` remote is the canonical juvantlabs/juvant-os.
      # Residual (detection, not prevention — the SessionStart integrity check,
      # hooks/lib/hooks-integrity.sh, catches the result): paths assembled at
      # runtime (`f=hooks; rm "$f/x.sh"`), `patch`/`git apply`/archive
      # extraction whose targets live inside a file.
      _gr_cmd=$(echo "$EVENT_JSON" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
      _GR_DENY_WHY=""

      # Raw substring scan: any protected path in the text, quotes included,
      # except under tests/.
      _gr_raw_ref() { juvant_guardrail_raw_ref "$1"; }

      # `git checkout upstream/main -- …` / `git restore --source=upstream/main …`
      # against the canonical upstream remote.
      _gr_upstream_restore() {
        local a prev="" src="" u
        for a in "$@"; do
          case "$a" in --source=*) src="${a#--source=}" ;; esac
          if [[ "$prev" == "--source" || "$prev" == "-s" ]]; then src="$a"; fi
          if [[ "$a" == "upstream/main" && -z "$src" ]]; then src="$a"; fi
          prev="$a"
        done
        [[ "$src" == "upstream/main" ]] || return 1
        u=$(git -C "$SCRIPT_DIR/.." remote get-url upstream 2>/dev/null || echo "")
        [[ "$u" =~ (^|[/:])juvantlabs/juvant-os(\.git)?$ ]]
      }

      # Evaluate one segment (shell words, quotes removed; redirect targets in
      # _GR_REDIR). Returns 0 = deny (reason in _GR_DENY_WHY), 1 = fine.
      _gr_eval_segment() {
        local i=0 x verb sub has=0 last prev=""
        local -a w=() args=()
        [[ $# -gt 0 ]] && w=("$@")
        for x in ${_GR_REDIR[@]+"${_GR_REDIR[@]}"}; do
          if _gr_is_path "$x"; then _GR_DENY_WHY="output redirect onto '$x'"; return 0; fi
        done
        # Skip inline assignments and transparent wrappers to the real verb.
        while [[ $i -lt ${#w[@]} ]]; do
          x="${w[$i]}"
          if [[ "$x" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then i=$((i + 1)); continue; fi
          case "${x##*/}" in
            command|env|nice|nohup|time|exec|xargs|builtin) i=$((i + 1)); continue ;;
          esac
          break
        done
        [[ $i -lt ${#w[@]} ]] || return 1
        verb="${w[$i]##*/}"
        [[ $((i + 1)) -lt ${#w[@]} ]] && args=("${w[@]:$((i + 1))}")
        case "$verb" in
          cd|pushd)
            _gr_cwd=""
            if [[ ${#args[@]} -gt 0 ]]; then
              _gr_cwd=$(juvant_guardrail_cd_dir "${args[0]}")
            fi
            return 1 ;;
        esac
        for x in ${args[@]+"${args[@]}"}; do
          if _gr_is_path "$x"; then has=1; break; fi
        done
        [[ "$has" == 1 ]] || return 1
        case "$verb" in
          cat|less|more|head|tail|grep|egrep|fgrep|rg|ag|wc|diff|cmp|comm|\
          shasum|sha1sum|sha256sum|md5|md5sum|cksum|stat|file|ls|tree|bat|\
          shellcheck|jq|echo|printf|test|'['|realpath|readlink|basename|dirname|\
          sort|uniq|cut|tr|source|.)
            return 1 ;;
          bash|sh|zsh|dash|ksh)
            # Executing a hook script reads it; inline -c code is caught by the
            # raw scan above.
            return 1 ;;
          sed)
            for x in "${args[@]}"; do
              if [[ "$x" == --in-place* ]] || [[ "$x" =~ ^-[a-zA-Z]*i ]]; then
                _GR_DENY_WHY="sed in-place edit"; return 0
              fi
            done
            return 1 ;;
          find)
            for x in "${args[@]}"; do
              case "$x" in
                -delete|-exec|-execdir|-ok|-okdir|-fprint|-fprint0|-fprintf|-fls)
                  _GR_DENY_WHY="find $x over a guardrail path"; return 0 ;;
              esac
            done
            return 1 ;;
          cp|rsync|install|ln)
            # Reading a guardrail file into a copy elsewhere is fine; the
            # destination (last operand, or -t / --target-directory) is not.
            last="${args[${#args[@]}-1]}"
            if _gr_is_path "$last"; then _GR_DENY_WHY="$verb onto '$last'"; return 0; fi
            for x in "${args[@]}"; do
              if [[ "$prev" == "-t" ]] && _gr_is_path "$x"; then _GR_DENY_WHY="$verb -t '$x'"; return 0; fi
              if [[ "$x" == --target-directory=* ]] && _gr_is_path "${x#*=}"; then _GR_DENY_WHY="$verb $x"; return 0; fi
              prev="$x"
            done
            return 1 ;;
          git)
            sub=""
            for x in "${args[@]}"; do
              if [[ "$prev" == "-C" || "$prev" == "-c" || "$prev" == "--git-dir" || "$prev" == "--work-tree" ]]; then prev="$x"; continue; fi
              if [[ "$x" != -* ]]; then sub="$x"; break; fi
              prev="$x"
            done
            case "$sub" in
              status|diff|log|show|blame|annotate|ls-files|ls-tree|cat-file|grep|\
              rev-parse|add|commit|fetch|describe|shortlog|whatchanged|hash-object|\
              check-ignore|check-attr)
                return 1 ;;
              checkout|restore)
                if _gr_upstream_restore "${args[@]}"; then return 1; fi
                _GR_DENY_WHY="git $sub of a guardrail path (only a restore from the canonical upstream/main is allowed — Upstream sync step 7)"
                return 0 ;;
              *)
                _GR_DENY_WHY="git ${sub:-<?>} on a guardrail path"; return 0 ;;
            esac ;;
          *)
            _GR_DENY_WHY="'$verb' on a guardrail path (not a recognised read-only command)"
            return 0 ;;
        esac
      }

      # Quote-aware split into segments of words; evaluate each.
      # SC1003: the lone-backslash patterns are literal by design.
      # shellcheck disable=SC1003
      _gr_scan_bash() {
        local s="$1" n=${#1} i=0 c q="" word="" inword=0 expect_redir=0
        local -a words=()
        _GR_REDIR=()
        while [[ $i -lt $n ]]; do
          c="${s:$i:1}"
          if [[ -n "$q" ]]; then
            if [[ "$c" == "$q" ]]; then
              q=""
            elif [[ "$q" == '"' && "$c" == '\' ]]; then
              i=$((i + 1)); word+="${s:$i:1}"
            else
              word+="$c"
            fi
            i=$((i + 1)); continue
          fi
          case "$c" in
            "'"|'"') q="$c"; inword=1 ;;
            '\') i=$((i + 1)); word+="${s:$i:1}"; inword=1 ;;
            ' '|$'\t'|';'|'|'|'&'|$'\n'|'('|')'|'`'|'>'|'<')
              if [[ -n "$word" || "$inword" == 1 ]]; then
                if [[ "$expect_redir" == 1 ]]; then _GR_REDIR+=("$word"); expect_redir=0
                else words+=("$word"); fi
              fi
              word=""; inword=0
              case "$c" in
                ' '|$'\t'|'<') ;;
                '>')
                  # >>, >| ; >&N / >&- duplicate an fd (no file target).
                  if [[ "${s:$((i + 1)):1}" == '>' || "${s:$((i + 1)):1}" == '|' ]]; then i=$((i + 1)); fi
                  if [[ "${s:$((i + 1)):1}" == '&' ]]; then
                    i=$((i + 1))
                    while [[ "${s:$((i + 1)):1}" =~ [0-9-] ]]; do i=$((i + 1)); done
                  else
                    expect_redir=1
                  fi ;;
                *)
                  if _gr_eval_segment ${words[@]+"${words[@]}"}; then return 0; fi
                  words=(); _GR_REDIR=(); expect_redir=0 ;;
              esac ;;
            *) word+="$c"; inword=1 ;;
          esac
          i=$((i + 1))
        done
        if [[ -n "$word" || "$inword" == 1 ]]; then
          if [[ "$expect_redir" == 1 ]]; then _GR_REDIR+=("$word"); else words+=("$word"); fi
        fi
        _gr_eval_segment ${words[@]+"${words[@]}"}
      }

      if [[ "$_gr_cmd" == *hooks* || "$_gr_cmd" == *bash-policy* || "$_gr_cmd" == *helpers* \
            || "$_gr_cmd" == *scripts* || "$_gr_cmd" == *.juvant* || "$_gr_cmd" == *audit-spool* ]]; then
        _gr_interp_re='(^|[^A-Za-z0-9_.-])(python[0-9.]*|node|nodejs|deno|bun|perl|ruby|php|osascript|awk|gawk|mawk|lua|eval)([[:space:]]|$)|(^|[^A-Za-z0-9_.-])(bash|sh|zsh|dash|ksh)[[:space:]]+-[A-Za-z]*c'
        # Heredoc `<<` (not a `<<<` here-string, which only feeds stdin).
        _gr_heredoc_re='(^|[^<])<<-?[^<]'
        # SC2016: '$(' and '`' are literal metacharacters to look for.
        # shellcheck disable=SC2016
        if _gr_raw_ref "$_gr_cmd" && { [[ "$_gr_cmd" =~ $_gr_interp_re ]] || [[ "$_gr_cmd" =~ $_gr_heredoc_re ]] || [[ "$_gr_cmd" == *'$('* || "$_gr_cmd" == *'`'* ]]; }; then
          _GR_DENY_WHY="interpreter / inline code / command substitution / heredoc in a command that references a guardrail file"
        elif _gr_scan_bash "$_gr_cmd"; then
          :
        else
          _GR_DENY_WHY=""
        fi
        if [[ -n "$_GR_DENY_WHY" ]]; then
          DECISION="deny"
          DENY_REASON="guardrail tamper floor (Track 2f / FEAT-064, decisions#303): Bash write to a protected path (gate scripts, bash-policy.json, helpers/, scripts/, the audit spool or its backups) is denied in a deployed instance — $_GR_DENY_WHY. Synced files change only via upstream sync (git checkout upstream/main -- <file>); the spool is written by the hook and drained by its helper. Read-only access (cat/grep/diff/git diff/log/show) and running a hook or helper (bash helpers/drain-audit-spool.sh) are allowed. (Framework dev: export JUVANT_FRAMEWORK_DEV=1.)"
        fi
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────
# Track 3 — append-only audit log
# ─────────────────────────────────────────────
# Routes via hooks/lib/db.sh so Local SQLite adopters get audit-log
# writes too. Pre-v0.6.3 the hook only used `turso db shell` directly,
# which silently no-ops on Local installations (the turso CLI cannot
# read filesystem paths) — Track 3 of handbook ADR 0004 was effectively
# disabled for every Local adopter. v0.6.3 fix.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/db.sh"

# SQL-escape single quotes via sed (bash 3.2 parameter expansion
# `${V//\'/\'\'}` produces `\'\'` on macOS default bash, which is
# not valid SQL escaping — would silently fail every INSERT carrying
# apostrophes. See FEAT-008 layer-2 dogfood finding (2026-05-08).
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

STATUS="pending"
DENY_SQL="NULL"
if [[ "$DECISION" == "deny" ]]; then
  STATUS="denied"
  DENY_ESCAPED=$(sql_escape "$DENY_REASON")
  DENY_SQL="'$DENY_ESCAPED'"
fi

SESSION_ESC=$(sql_escape "$SESSION_ID")
ROLE_ESC=$(sql_escape "$ROLE")
TOOL_ESC=$(sql_escape "$TOOL_NAME")
INPUT_SUMMARY_ESC=$(sql_escape "$INPUT_SUMMARY")

# ARCH-017 / ADR 0029: if the agent ran a Bash landing command prefixed
# `JUVANT_EXECUTING_SPEC=<id> …`, stamp that decision id onto the audit row so
# the Layer-1 spec-marking gate can cover artifact-less executions (no PR/issue
# to recover a link from). The signal is read from the COMMAND text (an inline
# env-prefix — no real env needed, scoped-by-construction to this one command).
# Only Bash carries it (Edit/Write have no per-call channel — out of scope, ADR
# 0029 S2). Include the column ONLY when set, so the common audit write stays
# byte-identical and needs no migration dependency.
_SPEC_COL=""; _SPEC_VAL=""
if [[ "$TOOL_NAME" == "Bash" ]]; then
  _SPEC_RAW=$(echo "$EVENT_JSON" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
  if [[ "$_SPEC_RAW" =~ JUVANT_EXECUTING_SPEC=([0-9]+) ]]; then
    _SPEC_COL=", spec_id"; _SPEC_VAL=", ${BASH_REMATCH[1]}"
  fi
fi

# FEAT-051: spool the audit INSERT instead of executing it inline. This
# write is NOT a precondition for the allow/deny decision below, so it
# must not sit on the tool gating path. Spooled rows are drained to the
# DB out-of-band (helpers/drain-audit-spool.sh via session-start.sh).
juvant_db_exec_async "INSERT INTO agent_actions_log
  (session_id, agent, tool_name, args_hash, status, deny_reason, input_summary, started_at${_SPEC_COL})
  VALUES
  ('$SESSION_ESC', '$ROLE_ESC', '$TOOL_ESC', '$ARGS_HASH', '$STATUS', $DENY_SQL, '$INPUT_SUMMARY_ESC', '$STARTED_AT'${_SPEC_VAL});" \
  || echo "[pre-tool-use] WARN: failed to spool agent_actions_log row" >&2

# ─────────────────────────────────────────────
# Output decision
# ─────────────────────────────────────────────
# BUG-053: emit the `hookSpecificOutput` wrapper — the ONLY form Claude Code 2.x
# honors for a PreToolUse permission decision. The legacy TOP-LEVEL
# {"permissionDecision":"deny",...} form is silently IGNORED for MCP (mcp__*)
# tools: the hook fired and logged status='denied', but the tool executed
# anyway — a silent bypass of the Track-2e sensitive-space gate (and, since this
# is the single shared emission path, of the Bash single-writer / deny-list gate
# too). Both built-in and MCP tools require the wrapper with hookEventName.
if [[ "$DECISION" == "deny" ]]; then
  jq -n --arg reason "$DENY_REASON" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  # BUG-053 defense-in-depth: ALSO hard-block via exit code 2 — the mechanism
  # Claude Code honors UNIFORMLY for built-in AND MCP tools, independent of any
  # stdout JSON-schema evolution. After a P0 silent-bypass (deny logged but not
  # enforced because the legacy top-level form was ignored), the security deny
  # path must not ride on stdout-schema honoring alone. CC surfaces hook stderr
  # to the model, so the reason is echoed there for the exit-2 path.
  printf '%s\n' "$DENY_REASON" >&2
  exit 2
fi

jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow"}}'
exit 0
