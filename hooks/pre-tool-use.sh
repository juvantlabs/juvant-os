#!/usr/bin/env bash
# hooks/pre-tool-use.sh
# Claude Code PreToolUse hook — runs BEFORE every tool call.
#
# Two responsibilities per handbook ADR 0004:
#
#   Track 2 — gate Bash via universal deny-list + per-agent allow-list.
#     Pattern source: hooks/bash-policy.json. On match, output
#     {"permissionDecision":"deny"} which Claude Code honors as a hard
#     block (the tool call never executes).
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
# Stdout: decision JSON
#   { "permissionDecision": "allow"|"deny",
#     "permissionDecisionReason": "..." }
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
  # Fallback to 'unknown' only outside a Juvant OS instance.
  if [[ -f "$SCRIPT_DIR/../.juvant/config.json" ]]; then
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

  # Universal deny-list
  while IFS= read -r pattern; do
    [[ -z "$pattern" || "$pattern" == "null" ]] && continue
    if [[ "$COMMAND" =~ $pattern ]]; then
      DECISION="deny"
      DENY_REASON="universal deny-list match: $pattern (handbook ADR 0004 Track 2)"
      break
    fi
  done < <(jq -r '.deny_patterns[]?' "$POLICY" 2>/dev/null)

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
        _ft_tok="${_ft_tok##*/}"   # strip path prefix (e.g. /opt/homebrew/bin/git → git)
        case "$_ft_tok" in
          for|while|until|if|case|do|then|else|elif|\
          fi|done|function|local|declare|readonly|typeset) continue ;;
        esac
        # Variable assignment (token contains '='): skip, but:
        # • If it opens a multi-line array (VAR=( with no ) on same line),
        #   enter array-skip mode so element lines aren't treated as commands.
        # • If it embeds $(cmd …), salvage cmd as the binary to check.
        if [[ "$_ft_tok" == *=* ]]; then
          if [[ "$_ft_line" == *"("* && "$_ft_line" != *")"* ]]; then
            _ft_in_array=1
          fi
          if [[ "$_ft_line" =~ \$\(([^[:space:]\|\&\;\)]+) ]]; then
            FIRST_TOKEN="${BASH_REMATCH[1]##*/}"
            break
          fi
          continue
        fi
        FIRST_TOKEN="$_ft_tok"
        break
      done <<< "$COMMAND"
      # F-28 fix (v0.7.3+): check universal_allow (POSIX shell builtins
      # like cd, pushd, echo — not real binaries, harmless across roles)
      # before falling through to per-role allow-list. Without this,
      # the Skill's `cd /tmp/... && sqlite3 ...` compound commands
      # got denied on `cd` even though sqlite3 was in cso allow-list.
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

# ─────────────────────────────────────────────
# Track 2b — Scope boundary guard (SYSTEM_INVARIANTS §4b / §4c)
# ─────────────────────────────────────────────
# Bidirectional block: project-scope agent → company DB (§4c hard-fail)
# and company-scope agent → project DB post-bootstrap (§4b hard-fail).
# Conservative whole-word token match on full command string.
# False positives acceptable; false negatives caught by Layer 3 drift audit.
if [[ "$TOOL_NAME" == "Bash" && "$DECISION" == "allow" ]]; then
  _T2B_CMD=$(echo "$EVENT_JSON" | jq -r '.tool_input.command // ""')

  # Detect write tokens (whole-word, case-insensitive)
  if echo "$_T2B_CMD" | grep -qiE \
      '\b(INSERT|UPDATE|DELETE|REPLACE)\b|CREATE[[:space:]]+TABLE|ALTER[[:space:]]+TABLE|DROP[[:space:]]+TABLE'; then

    _CFG="$SCRIPT_DIR/../.juvant/config.json"
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
      _CFG_T2C="$SCRIPT_DIR/../.juvant/config.json"
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
  if [[ "$COMMAND" =~ git[[:space:]]+(push|commit|merge) ]]; then
    _T2D_WRITE=1
  fi
  if [[ "$_T2D_WRITE" -eq 0 && -f "$POLICY" ]]; then
    while IFS= read -r _ghp; do
      [[ -z "$_ghp" ]] && continue
      if [[ "$COMMAND" =~ $_ghp ]]; then _T2D_WRITE=1; break; fi
    done < <(jq -r '.single_writer_gh_patterns[]?' "$POLICY" 2>/dev/null)
  fi
  # gh api with field flags (-f/-F/--field/--raw-field) is a POST by
  # default — a write — unless an explicit -X GET / --method GET is given.
  if [[ "$_T2D_WRITE" -eq 0 ]] \
     && [[ "$COMMAND" =~ gh[[:space:]]+api.*(-f|-F|--field|--raw-field)([[:space:]]|=) ]] \
     && [[ ! "$COMMAND" =~ (-X|--method)[[:space:]]+GET ]]; then
    _T2D_WRITE=1
  fi
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
      _T4_SPEC_ID=$(juvant_db_query \
        "SELECT id FROM decisions WHERE category IN ($_T4_CAT_SQL) AND status='approved' AND created_at > datetime('now','-7 days') LIMIT 1;" \
        2>/dev/null | grep -E '^[0-9]+$' | head -1 || echo "")
      if [[ -z "$_T4_SPEC_ID" ]]; then
        DECISION="deny"
        DENY_REASON="SPEC GATE (FEAT-040 Layer 3): action class '$_T4_MATCHED_CLASS' requires an approved spec [${_T4_REQUIRED_CATS}] created within 7 days. None found. Author a spec via the appropriate agent, obtain CEO approval, then retry."
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

# FEAT-051: spool the audit INSERT instead of executing it inline. This
# write is NOT a precondition for the allow/deny decision below, so it
# must not sit on the tool gating path. Spooled rows are drained to the
# DB out-of-band (helpers/drain-audit-spool.sh via session-start.sh).
juvant_db_exec_async "INSERT INTO agent_actions_log
  (session_id, agent, tool_name, args_hash, status, deny_reason, input_summary)
  VALUES
  ('$SESSION_ESC', '$ROLE_ESC', '$TOOL_ESC', '$ARGS_HASH', '$STATUS', $DENY_SQL, '$INPUT_SUMMARY_ESC');" \
  || echo "[pre-tool-use] WARN: failed to spool agent_actions_log row" >&2

# ─────────────────────────────────────────────
# Output decision
# ─────────────────────────────────────────────
if [[ "$DECISION" == "deny" ]]; then
  jq -n --arg reason "$DENY_REASON" \
    '{permissionDecision: "deny", permissionDecisionReason: $reason}'
else
  jq -n '{permissionDecision: "allow"}'
fi

exit 0
