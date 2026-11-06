#!/usr/bin/env bash
# hooks/lib/exec-scope.sh — BUG-103 (juvantlabs/juvant-os-pm#209)
#
# juvant_exec_scope_applies <policy-file> <lookup-role>
#   True for a role with no interpreter on its allow-list. A role with python3
#   or node can run anything, and its job is to run code, so these checks would
#   only add noise there.
#
# juvant_exec_scope_check <policy-file> <command> <instance-root> <cwd>
#   Track 2 for those roles. An allow-listed binary must not become a way to run
#   a binary the role doesn't have. Works on the parsed argv of every simple
#   command (hooks/lib/bash-segments.sh).
#     - bash/sh run only a framework script, the same files Track 2f keeps out
#       of agent writes. Not stdin, not a computed path, not anything else.
#     - git, gh, sort, awk and sed: the flags and program text that run commands.
#     - variables and config files that change what those run.
#   Returns 0 nothing to deny · 1 deny, the reason is on stdout.
#   This narrows what an agent can do by accident or under pressure. It is not
#   a sandbox: docs/adr/0038-bash-allow-list-scope.md says what it guarantees.
#
# juvant_exec_script_hashes <command> <cwd>
#   Prints a short sha256 for each script file the line runs, for the audit row:
#   `bash x.sh` alone doesn't say what ran.
#
# Requires hooks/lib/bash-segments.sh. Pure bash 3.2 (macOS /bin/bash).
#
# SC2016 / SC2088: the patterns are literal shell text, and a leading ~ in a
# parsed word is expanded by hand.
# shellcheck disable=SC2016,SC2088

_JES_US=$'\037'
# The same files as JUVANT_GUARDRAIL_FILE_RES in hooks/lib/guardrail-paths.sh.
# tests/ is left out on purpose: suites are instance-editable.
_JES_SCRIPT_RE='^(hooks|hooks/lib|helpers|scripts)/[^/]+\.sh$'
_JES_ENV_RE='(^|[[:space:];&|(])(BASH_ENV|ENV|CDPATH|PATH|SHELLOPTS|BASHOPTS|LD_PRELOAD|DYLD_[A-Z_]+|GIT_[A-Z_]*(SSH|SSH_COMMAND|PAGER|EDITOR|EXTERNAL_DIFF|CONFIG[A-Z_]*|ASKPASS|EXEC_PATH|PROXY_COMMAND|DIR|TEMPLATE_DIR)|PAGER|EDITOR|VISUAL|GH_PAGER|GH_EDITOR|BROWSER)='
_JES_CONFIG_RE='(^|/)(\.gitconfig|\.config/git/.*|\.config/gh/.*|\.bashrc|\.bash_profile|\.bash_login|\.profile|\.zshenv|\.zshrc|\.zprofile|\.zlogin)$'
_JES_WRITE_RE='>>?[[:space:]]*["'\'']?[^[:space:]"'\'']*(\.gitconfig|\.config/(git|gh)/|\.bashrc|\.bash_profile|\.bash_login|\.profile|\.zshenv|\.zshrc|\.zprofile|\.zlogin)'

juvant_exec_scope_applies() {
  local n
  n=$(jq -r --arg role "$2" '
    . as $doc
    | [($doc.agent_allow[$role] // [])[]
       | if startswith("@") then ($doc.tiers[ltrimstr("@")] // [])[] else . end]
    | map(select(. as $b | ($doc.exec_scope.interpreters // []) | index($b) != null))
    | length' "$1" 2>/dev/null) || return 1
  [[ "$n" == "0" ]]
}

juvant_exec_scope_path_denied() {
  [[ "$1" =~ $_JES_CONFIG_RE ]]
}

_jes_deny() {
  printf "deny:exec-scope:%s — %s This role has no interpreter on its allow-list, so an allowed tool can't be used to run other commands (handbook ADR 0004 Track 2, ADR 0038). Do NOT retry or rewrite the line another way: surface it to your parent (CoS) for a tool-matrix-change. Refs: BUG-103" "$1" "$2"
}

# _jes_real_dir <dir>: physical path, or nothing if it doesn't exist.
_jes_real_dir() {
  ( unset CDPATH; cd -- "$1" 2>/dev/null && pwd -P )
}

# _jes_base <command> <cwd>: the directory a relative path starts from.
# Empty when it can't be known. Only a leading `cd <literal> &&|;` counts: a cd
# anywhere else may be skipped, or run in a subshell or a pipeline.
_jes_base() {
  local cmd="$1" cwd="$2" line rest t first=1 late=0 lead=""
  local nl=$'\n'
  local re='^[[:space:]]*cd[[:space:]]+("[^"]*"|[^[:space:];&|()]+)[ 	]*(&&|;|'"$nl"'|$)'
  if [[ "$cmd" =~ $re ]]; then
    lead="${BASH_REMATCH[1]}"; lead="${lead#\"}"; lead="${lead%\"}"
  fi
  while IFS= read -r line; do
    [[ "$line" == "A$_JES_US"* ]] || continue
    rest="${line#A"$_JES_US"}"
    case "${rest%%"$_JES_US"*}" in
      cd|pushd|popd)
        if (( first )) && [[ -n "$lead" ]]; then first=0; else late=1; fi ;;
      *) first=0 ;;
    esac
    first=0
  done < <(juvant_bash_argv "$cmd")
  (( late )) && return 0
  if [[ -z "$lead" ]]; then printf '%s' "$cwd"; return 0; fi
  [[ "$lead" == *'$'* ]] && return 0
  t="$lead"
  [[ "$t" == "~/"* ]] && t="$HOME/${t#\~/}"
  [[ "$t" == "~" ]] && t="$HOME"
  [[ "$t" == /* ]] || t="$cwd/$t"
  _jes_real_dir "$t"
}

# _jes_script_file <word> <base>: the resolved file, or nothing.
_jes_script_file() {
  local p="$1" base="$2" dir name
  [[ "$p" == *'$'* ]] && return 0
  [[ "$p" == "~/"* ]] && p="$HOME/${p#\~/}"
  if [[ "$p" != /* ]]; then
    [[ -n "$base" ]] || return 0
    p="$base/$p"
  fi
  name="${p##*/}"
  dir=$(_jes_real_dir "${p%/*}")
  [[ -n "$dir" && -f "$dir/$name" && ! -L "$dir/$name" ]] || return 0
  printf '%s/%s' "$dir" "$name"
}

# _jes_shell_target <args…>: sets _JES_FORM to inline|file|stdin|bad and
# _JES_PATH to the file word.
_jes_shell_target() {
  local x
  _JES_FORM="stdin"; _JES_PATH=""
  while (( $# )); do
    x="$1"
    case "$x" in
      -o|+o|-O|+O) shift; [[ $# -gt 0 ]] && shift; continue ;;
      --) shift; [[ $# -gt 0 ]] && { _JES_FORM="file"; _JES_PATH="$1"; }; return ;;
      --*) _JES_FORM="bad"; _JES_PATH="$x"; return ;;
      -*c*) _JES_FORM="inline"; return ;;
      -*s*|-*i*) _JES_FORM="stdin"; return ;;
      -*|+*) shift; continue ;;
      *) _JES_FORM="file"; _JES_PATH="$x"; return ;;
    esac
  done
}

# A whole word that is one variable was computed at run time; `$1` in an awk
# program was not.
_jes_computed() {
  [[ "$1" == '$' || "$1" =~ ^\$(\{|[A-Za-z_][A-Za-z0-9_]*$) ]]
}

_jes_awk() {
  local x prog=""
  while (( $# )); do
    x="$1"
    case "$x" in
      -F|-v) shift; [[ $# -gt 0 ]] && shift; continue ;;
      -F*|-v*) shift; continue ;;
      --) shift; prog="${1:-}"; break ;;
      -*) _jes_deny "awk" "awk flag '$x' isn't allowed here: it can load a program."; return 1 ;;
      *) prog="$x"; break ;;
    esac
  done
  if _jes_computed "$prog"; then
    _jes_deny "awk" "an awk program computed at run time can't be checked."; return 1
  fi
  prog=$(printf '%s' "$prog" | sed -E 's/"([^"\\]|\\.)*"/""/g')
  if [[ "$prog" =~ (^|[^A-Za-z0-9_])system[[:space:]]*\( \
     || "$prog" =~ \|[[:space:]]*getline \
     || "$prog" =~ \|\& \
     || "$prog" =~ print[^\;\}]*[^\|]\|[^\|] ]]; then
    _jes_deny "awk" "this awk program runs a command (system(), a pipe, getline from a command)."; return 1
  fi
}

_jes_sed_script() {
  local s="$1"
  local addr='(^|[;{}])[[:space:]]*([0-9$,]+|/[^/]*/)?[[:space:]]*e([[:space:]]|$)'
  local subst='(^|[;{[:space:]])s/([^/\\]|\\.)*/([^/\\]|\\.)*/[gpiIm0-9]*e'
  if _jes_computed "$s"; then
    _jes_deny "sed" "a sed script computed at run time can't be checked."; return 1
  fi
  if [[ "$s" =~ $addr || "$s" =~ $subst ]]; then
    _jes_deny "sed" "this sed script runs a command (the e command or flag)."; return 1
  fi
}

_jes_sed() {
  local x seen=0
  while (( $# )); do
    x="$1"
    case "$x" in
      -f*|--file*) _jes_deny "sed" "sed scripts from a file can't be checked."; return 1 ;;
      -e) shift; seen=1; _jes_sed_script "${1:-}" || return 1 ;;
      -e*) seen=1; _jes_sed_script "${x#-e}" || return 1 ;;
      --expression=*) seen=1; _jes_sed_script "${x#--expression=}" || return 1 ;;
      -*) ;;
      *) (( seen )) && return 0; _jes_sed_script "$x" || return 1; return 0 ;;
    esac
    shift
  done
}

_jes_git() {
  local x sub=""
  while (( $# )); do
    x="$1"
    case "$x" in
      -c|-c*|--config-env*|--exec-path=*|--git-dir*|--work-tree*|--namespace*)
        _jes_deny "git" "the global flag '${x%%=*}' can change what git runs."; return 1 ;;
      -C) shift; [[ $# -gt 0 ]] && shift; continue ;;
      -*) shift; continue ;;
      *) sub="$x"; shift; break ;;
    esac
  done
  case "$sub" in
    bisect|filter-branch|difftool|mergetool|hook|daemon|send-email)
      _jes_deny "git" "'git $sub' runs external commands."; return 1 ;;
    apply|am|update-index|hash-object|read-tree|commit-tree|fast-import)
      # A patch writes wherever it says, past the Track 2f path check.
      _jes_deny "git" "'git $sub' can place files the framework-script check would then trust."; return 1 ;;
    submodule)
      if [[ "${1:-}" == "foreach" ]]; then _jes_deny "git" "'git submodule foreach' runs a command."; return 1; fi ;;
    config)
      for x in "$@"; do
        case "$x" in --get|--get-all|--get-regexp|--get-urlmatch|--list|-l) return 0 ;; esac
      done
      _jes_deny "git" "'git config' is read-only here: config can name commands for git to run."; return 1 ;;
  esac
  for x in "$@"; do
    case "$sub:$x" in
      rebase:-x|rebase:-x*|*:--exec*|grep:-O*|grep:--open-files-in-pager*|*:--ext-diff|*:--upload-pack*|*:--receive-pack*|clone:-u|fetch:-u*|*:--extcmd*)
        _jes_deny "git" "the flag '${x%%=*}' runs a command."; return 1 ;;
    esac
  done
}

_jes_gh() {
  case "${1:-}" in
    alias|extension|ext|extensions)
      _jes_deny "gh" "'gh ${1}' can run shell commands."; return 1 ;;
    config)
      if [[ "${2:-}" == "set" ]]; then _jes_deny "gh" "'gh config set' can name commands for gh to run."; return 1; fi ;;
  esac
}

juvant_exec_scope_check() {
  local cmd="$2" root="$3" cwd="${4:-$PWD}" line rest name base file rootp rel
  local -a w
  local lines has_runner=0
  lines=$(juvant_bash_argv "$cmd")
  [[ "$lines" == *$'\nP '* || "$lines" == "P "* ]] && return 0   # the segment check denies it
  case " $(printf '%s' "$lines" | sed -n 's/^B //p' | tr '\n' ' ') " in
    *" bash "*|*" sh "*|*" git "*|*" gh "*) has_runner=1 ;;
  esac
  if (( has_runner )) && [[ "$cmd" =~ $_JES_ENV_RE ]]; then
    _jes_deny "env" "setting ${BASH_REMATCH[2]} on a line that runs bash, git or gh changes what they run."
    return 1
  fi
  if [[ "$cmd" =~ $_JES_WRITE_RE ]]; then
    _jes_deny "config" "shell and git config files can name commands to run."
    return 1
  fi
  base=$(_jes_base "$cmd" "$cwd")
  rootp=$(_jes_real_dir "$root")
  while IFS= read -r line; do
    [[ "$line" == "A$_JES_US"* ]] || continue
    rest="${line#A"$_JES_US"}"
    IFS="$_JES_US" read -r -a w <<<"$rest"
    name="${w[0]:-}"
    case "$name" in
      bash|sh|zsh|dash|ksh)
        _jes_shell_target ${w[@]+"${w[@]:1}"}
        case "$_JES_FORM" in
          inline) ;;   # the parser walks the code; computed code is a parse failure
          stdin) _jes_deny "$name" "running a shell on stdin, a pipe or a heredoc can't be checked. Only a framework script can run."; return 1 ;;
          bad) _jes_deny "$name" "the flag '$_JES_PATH' can load other code."; return 1 ;;
          file)
            file=$(_jes_script_file "$_JES_PATH" "$base")
            rel="${file#"$rootp"/}"
            if [[ -z "$file" || "$rel" == "$file" || ! "$rel" =~ $_JES_SCRIPT_RE ]]; then
              _jes_deny "$name" "'$_JES_PATH' is not a framework script of this instance (hooks/, helpers/ or scripts/). A relative path after anything but a leading cd can't be resolved: use the absolute path."
              return 1
            fi ;;
        esac ;;
      git) _jes_git ${w[@]+"${w[@]:1}"} || return 1 ;;
      gh)  _jes_gh ${w[@]+"${w[@]:1}"} || return 1 ;;
      sort)
        for rel in ${w[@]+"${w[@]:1}"}; do
          case "$rel" in --compress-program*)
            _jes_deny "sort" "--compress-program runs a command."; return 1 ;;
          esac
        done ;;
      awk|gawk|mawk|nawk) _jes_awk ${w[@]+"${w[@]:1}"} || return 1 ;;
      sed|gsed) _jes_sed ${w[@]+"${w[@]:1}"} || return 1 ;;
    esac
  done <<<"$lines"
  return 0
}

juvant_exec_script_hashes() {
  local cmd="$1" cwd="${2:-$PWD}" line rest base file out=""
  local -a w
  base=$(_jes_base "$cmd" "$cwd")
  while IFS= read -r line; do
    [[ "$line" == "A$_JES_US"* ]] || continue
    rest="${line#A"$_JES_US"}"
    IFS="$_JES_US" read -r -a w <<<"$rest"
    case "${w[0]:-}" in
      bash|sh|zsh|dash|ksh)
        _jes_shell_target ${w[@]+"${w[@]:1}"}
        [[ "$_JES_FORM" == "file" ]] || continue
        file=$(_jes_script_file "$_JES_PATH" "$base")
        [[ -n "$file" ]] || continue
        out="$out$(shasum -a 256 "$file" 2>/dev/null | cut -c1-12) " ;;
    esac
  done < <(juvant_bash_argv "$cmd")
  printf '%s' "${out% }"
}
