#!/usr/bin/env bash
# hooks/lib/bash-segments.sh — BUG-098 (juvantlabs/juvant-os-pm#201)
#
# juvant_bash_binaries <command>
#   Lists the command in position of EVERY simple command of a Bash line, one
#   per line, so Track 2 can check each against the agent's allow-list (not
#   only the first one):
#     B <name>     a binary / builtin that will run (path stripped)
#     P <reason>   the line cannot be parsed reliably → the caller denies
#
#   Split on ; & && | || |& newline ( ) { } and inside $( ), ` `, <( ), >( ),
#   ${…} and double quotes. Heredoc bodies, comments, case patterns, [[ ]],
#   (( )), array literals and redirect targets are data, not commands.
#   Leading VAR=value words and shell keywords are skipped; the wrappers
#   env / nice / nohup / timeout / xargs are listed AND unwrapped, command /
#   builtin / exec / time are unwrapped; sudo / doas are listed, not unwrapped.
#   Inline code is followed: bash|sh|zsh|dash|ksh -c <code>, eval <words>,
#   find -exec|-execdir|-ok|-okdir <cmd>.
#   Fail closed (P): unbalanced quotes / parens, an unterminated $( or
#   backtick, a command name computed at run time ($cmd, "$(…)"), env -S,
#   nesting deeper than _JBS_MAX_DEPTH.
#
# juvant_bash_argv <command>  (BUG-076)
#   Same walk, plus one line per listed command with its unwrapped arguments:
#     A<US><name><US><arg1><US>…   (US = 0x1F; newlines in a word become spaces)
#   A word holding a `$` marker is computed at run time.
#
# Pure bash 3.2 (macOS /bin/bash): no associative arrays. Every helper works
# on the caller's locals through bash's dynamic scoping.
#
# SC2016 / SC1003: the patterns are literal shell metacharacters.
# shellcheck disable=SC2016,SC1003

_JBS_MAX_DEPTH=8

juvant_bash_binaries() {
  _JBS_ARGV=0
  _jbs_run "$1"
}

juvant_bash_argv() {
  _JBS_ARGV=1
  _jbs_run "$1"
}

_jbs_run() {
  local LC_ALL=C
  _JBS_FAIL=""
  _JBS_POS=0
  _JBS_FUNCS=" "
  _jbs_parse "$1" 0 "" 0
  if [[ -n "$_JBS_FAIL" ]]; then printf 'P %s\n' "$_JBS_FAIL"; fi
  return 0
}

# _jbs_parse <string> <start> <terminator ""|")"> <depth>
#   Parses commands from <start>. With terminator ")" it stops at the
#   unmatched ')' and leaves its index in _JBS_POS.
_jbs_parse() {
  local s="$1" i="$2" term="$3" depth="$4"
  local n=${#s} c c2 rest pre word="" inword=0 redir=0 hd_expect=0 hd_strip=0
  local pdepth=0 casepat=0 dbr=0
  local -a words=() hd=() hds=()
  if (( depth > _JBS_MAX_DEPTH )); then _JBS_FAIL="nesting deeper than $_JBS_MAX_DEPTH levels"; return; fi
  while (( i < n )); do
    [[ -n "$_JBS_FAIL" ]] && return
    c="${s:i:1}"
    if (( casepat )); then
      # case pattern: data up to the unquoted ')'; `esac` ends the case.
      case "$c" in
        ' '|$'\t'|$'\n'|';') i=$((i + 1)); continue ;;
      esac
      if [[ "${s:i:4}" == "esac" && ! "${s:i+4:1}" =~ [A-Za-z0-9_] ]]; then casepat=0; continue; fi
      while (( i < n )); do
        c="${s:i:1}"
        case "$c" in
          ')') i=$((i + 1)); break ;;
          '\') i=$((i + 2)) ;;
          "'"|'"')
            rest="${s:i+1}"; pre="${rest%%"$c"*}"
            if [[ "$pre" == "$rest" ]]; then _JBS_FAIL="unbalanced quote in a case pattern"; return; fi
            i=$((i + ${#pre} + 2)) ;;
          *) i=$((i + 1)) ;;
        esac
      done
      casepat=0
      continue
    fi
    case "$c" in
      '\')
        if [[ "${s:i+1:1}" == $'\n' ]]; then i=$((i + 2)); continue; fi
        word+="${s:i+1:1}"; inword=1; i=$((i + 2)) ;;
      "'")
        rest="${s:i+1}"; pre="${rest%%\'*}"
        if [[ "$pre" == "$rest" ]]; then _JBS_FAIL="unbalanced single quote"; return; fi
        word+="$pre"; inword=1; i=$((i + ${#pre} + 2)) ;;
      '"') _jbs_dq ;;
      '`') _jbs_backtick ;;
      '$') _jbs_dollar ;;
      '#')
        if (( inword == 0 )); then
          rest="${s:i}"; pre="${rest%%$'\n'*}"; i=$((i + ${#pre}))
        else
          word+="#"; i=$((i + 1))
        fi ;;
      ' '|$'\t') _jbs_endword; i=$((i + 1)) ;;
      $'\n') _jbs_endseg; i=$((i + 1)); _jbs_heredoc_bodies ;;
      ';')
        _jbs_endseg; i=$((i + 1))
        if [[ "${s:i:1}" == ";" ]]; then
          i=$((i + 1)); [[ "${s:i:1}" == "&" ]] && i=$((i + 1)); casepat=1
        elif [[ "${s:i:1}" == "&" ]]; then
          i=$((i + 1)); casepat=1
        fi ;;
      '&')
        if (( dbr )); then word+="&"; inword=1; i=$((i + 1)); continue; fi
        if [[ "${s:i+1:1}" == ">" ]]; then
          _jbs_endword; i=$((i + 2)); [[ "${s:i:1}" == ">" ]] && i=$((i + 1)); redir=1; continue
        fi
        _jbs_endseg; i=$((i + 1)); [[ "${s:i:1}" == "&" ]] && i=$((i + 1)) ;;
      '|')
        if (( dbr )); then word+="|"; inword=1; i=$((i + 1)); continue; fi
        _jbs_endseg; i=$((i + 1))
        if [[ "${s:i:1}" == "|" || "${s:i:1}" == "&" ]]; then i=$((i + 1)); fi ;;
      '<'|'>')
        if (( dbr )); then word+="$c"; inword=1; i=$((i + 1)); continue; fi
        if [[ "${s:i+1:1}" == "(" ]]; then
          # process substitution: an argument whose producer runs
          word+='$'; inword=1
          _jbs_parse "$s" $((i + 2)) ")" $((depth + 1))
          [[ -n "$_JBS_FAIL" ]] && return
          i=$((_JBS_POS + 1)); continue
        fi
        # fd number glued to the operator (2>…, 0<…)
        if (( inword )) && [[ "$word" =~ ^[0-9]+$ ]]; then word=""; inword=0; fi
        _jbs_endword
        if [[ "$c" == "<" && "${s:i+1:2}" == "<<" ]]; then
          i=$((i + 3)); redir=1; continue            # here-string
        fi
        if [[ "$c" == "<" && "${s:i+1:1}" == "<" ]]; then
          i=$((i + 2)); hd_strip=0
          if [[ "${s:i:1}" == "-" ]]; then hd_strip=1; i=$((i + 1)); fi
          hd_expect=1; continue                      # heredoc: next word is the delimiter
        fi
        i=$((i + 1)); c2="${s:i:1}"
        if [[ "$c2" == ">" || "$c2" == "|" ]]; then i=$((i + 1)); c2="${s:i:1}"; fi
        if [[ "$c2" == "&" ]]; then
          i=$((i + 1))
          while [[ "${s:i:1}" =~ [0-9-] ]]; do i=$((i + 1)); done
          continue
        fi
        redir=1 ;;
      '(')
        if (( dbr )); then word+="("; inword=1; i=$((i + 1)); continue; fi
        if (( inword )) && [[ "$word" == *= ]]; then _jbs_skip_array; continue; fi
        _jbs_endword
        if (( ${#words[@]} == 1 )) && [[ "${s:i+1}" =~ ^[[:space:]]*\) ]]; then
          # name() — a function definition, not a command
          _JBS_FUNCS+="${words[0]} "
          words=(); rest="${s:i+1}"; pre="${rest%%)*}"; i=$((i + ${#pre} + 2)); continue
        fi
        if (( ${#words[@]} == 0 )) && [[ "${s:i+1:1}" == "(" ]]; then
          _jbs_skip_parens "$i"; continue          # (( arithmetic ))
        fi
        _jbs_endseg; pdepth=$((pdepth + 1)); i=$((i + 1)) ;;
      ')')
        if (( dbr )); then word+=")"; inword=1; i=$((i + 1)); continue; fi
        _jbs_endseg
        if (( pdepth == 0 )); then
          if [[ "$term" == ")" ]]; then _JBS_POS=$i; return; fi
          _JBS_FAIL="unbalanced ')'"; return
        fi
        pdepth=$((pdepth - 1)); i=$((i + 1)) ;;
      *) word+="$c"; inword=1; i=$((i + 1)) ;;
    esac
  done
  [[ -n "$_JBS_FAIL" ]] && return
  _jbs_endseg
  if [[ "$term" == ")" ]]; then _JBS_FAIL="unterminated \$( … ) or <( … )"; return; fi
  if (( pdepth > 0 )); then _JBS_FAIL="unbalanced '('"; return; fi
  _JBS_POS=$n
}

# Ends the current word (caller's locals).
_jbs_endword() {
  if (( inword )) || [[ -n "$word" ]]; then
    if (( redir )); then
      redir=0
    elif (( hd_expect )); then
      hd+=("$word"); hds+=("$hd_strip"); hd_expect=0
    else
      words+=("$word")
      if (( dbr == 0 )) && [[ "$word" == "[[" ]]; then dbr=1
      elif (( dbr )) && [[ "$word" == "]]" ]]; then dbr=0
      fi
      if [[ "$word" == "in" && ${#words[@]} -ge 3 && "${words[${#words[@]}-3]}" == "case" ]]; then
        words=(); casepat=1
      fi
    fi
  fi
  word=""; inword=0
}

# Ends the current simple command and lists its binary.
_jbs_endseg() {
  _jbs_endword
  if (( ${#words[@]} )); then _jbs_emit "${words[@]}"; fi
  words=()
}

# After a newline: skip the bodies of the heredocs opened on that line.
_jbs_heredoc_bodies() {
  local k line cmp
  for (( k = 0; k < ${#hd[@]}; k++ )); do
    while (( i < n )); do
      rest="${s:i}"; line="${rest%%$'\n'*}"
      i=$((i + ${#line} + 1))
      cmp="$line"
      if [[ "${hds[k]}" == 1 ]]; then while [[ "${cmp:0:1}" == $'\t' ]]; do cmp="${cmp:1}"; done; fi
      [[ "$cmp" == "${hd[k]}" ]] && break
    done
  done
  (( i > n )) && i=$n
  hd=(); hds=()
}

# Double-quoted string at s[i] (caller's locals).
_jbs_dq() {
  local d
  i=$((i + 1)); inword=1
  while (( i < n )); do
    d="${s:i:1}"
    case "$d" in
      '"') i=$((i + 1)); return ;;
      '\') word+="${s:i+1:1}"; i=$((i + 2)) ;;
      '`') _jbs_backtick ;;
      '$') _jbs_dollar ;;
      *) word+="$d"; i=$((i + 1)) ;;
    esac
    [[ -n "$_JBS_FAIL" ]] && return
  done
  _JBS_FAIL="unbalanced double quote"
}

# `$` at s[i]: $( … ) is parsed, $(( … )) and ${ … } are skipped (their own
# substitutions parsed). The word gets a `$` marker: it is computed.
_jbs_dollar() {
  local d="${s:i+1:1}"
  word+='$'; inword=1
  if [[ "$d" == "(" ]]; then
    if [[ "${s:i+2:1}" == "(" ]]; then _jbs_skip_parens $((i + 1)); return; fi
    _jbs_parse "$s" $((i + 2)) ")" $((depth + 1))
    [[ -n "$_JBS_FAIL" ]] && return
    i=$((_JBS_POS + 1)); return
  fi
  if [[ "$d" == "{" ]]; then
    local j=$((i + 2)) bd=1 e
    while (( j < n )); do
      e="${s:j:1}"
      case "$e" in
        '{') bd=$((bd + 1)); j=$((j + 1)) ;;
        '}') bd=$((bd - 1)); j=$((j + 1)); if (( bd == 0 )); then i=$j; return; fi ;;
        '\') j=$((j + 2)) ;;
        '$')
          if [[ "${s:j+1:1}" == "(" && "${s:j+2:1}" != "(" ]]; then
            _jbs_parse "$s" $((j + 2)) ")" $((depth + 1))
            [[ -n "$_JBS_FAIL" ]] && return
            j=$((_JBS_POS + 1))
          else
            j=$((j + 1))
          fi ;;
        *) j=$((j + 1)) ;;
      esac
    done
    _JBS_FAIL="unterminated \${ … }"; return
  fi
  i=$((i + 1))
}

# Backtick substitution at s[i]: parse its content as a separate string.
_jbs_backtick() {
  local j=$((i + 1)) inner=""
  while (( j < n )); do
    case "${s:j:1}" in
      '`') break ;;
      '\') inner+="${s:j+1:1}"; j=$((j + 2)); continue ;;
    esac
    inner+="${s:j:1}"; j=$((j + 1))
  done
  if (( j >= n )); then _JBS_FAIL="unterminated backtick"; return; fi
  word+='$'; inword=1
  _jbs_parse "$inner" 0 "" $((depth + 1))
  i=$((j + 1))
}

# Skip a balanced ( … ) starting at index $1 (arithmetic): sets i past it.
_jbs_skip_parens() {
  local j="$1" pd=0 e
  while (( j < n )); do
    e="${s:j:1}"
    case "$e" in
      '(') pd=$((pd + 1)) ;;
      ')') pd=$((pd - 1)); if (( pd == 0 )); then i=$((j + 1)); return; fi ;;
    esac
    j=$((j + 1))
  done
  _JBS_FAIL="unterminated (( … ))"
}

# VAR=( … ) array literal at s[i]='(' — data; substitutions inside parsed.
_jbs_skip_array() {
  i=$((i + 1)); word+="()"
  while (( i < n )); do
    case "${s:i:1}" in
      ')') i=$((i + 1)); return ;;
      "'")
        rest="${s:i+1}"; pre="${rest%%\'*}"
        if [[ "$pre" == "$rest" ]]; then _JBS_FAIL="unbalanced single quote"; return; fi
        i=$((i + ${#pre} + 2)) ;;
      '"') _jbs_dq ;;
      '$') _jbs_dollar ;;
      '`') _jbs_backtick ;;
      '\') i=$((i + 2)) ;;
      *) i=$((i + 1)) ;;
    esac
    [[ -n "$_JBS_FAIL" ]] && return
  done
  _JBS_FAIL="unterminated array assignment"
}

# _jbs_argv_line <name> <args…>
_jbs_argv_line() {
  local IFS=$'\037' out
  out="$*"
  printf 'A\037%s\n' "${out//$'\n'/ }"
}

# _jbs_emit <words…> — list the binary of one simple command.
_jbs_emit() {
  local -a w=("$@")
  local k=0 m=$# x b j code sc
  while (( k < m )); do
    x="${w[k]}"
    if [[ "$x" =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?= ]]; then k=$((k + 1)); continue; fi
    case "$x" in
      if|then|else|elif|fi|do|done|while|until|'!'|'{'|'}'|'esac') k=$((k + 1)); continue ;;
      function) [[ -n "${w[k+1]:-}" ]] && _JBS_FUNCS+="${w[k+1]%%(*} "; return ;;
      for|select|case|in|'[['|']]') return ;;
    esac
    break
  done
  # Wrappers.
  while (( k < m )); do
    x="${w[k]##*/}"
    case "$x" in
      command|builtin)
        if [[ "${w[k+1]:-}" == "-v" || "${w[k+1]:-}" == "-V" ]]; then printf 'B %s\n' "$x"; return; fi
        k=$((k + 1)); [[ "${w[k]:-}" == "-p" ]] && k=$((k + 1)); continue ;;
      exec|time)
        k=$((k + 1))
        while [[ "${w[k]:-}" == -* ]]; do [[ "${w[k]}" == "-a" ]] && k=$((k + 1)); k=$((k + 1)); done
        continue ;;
      nohup) printf 'B %s\n' "$x"; k=$((k + 1)); continue ;;
      nice)
        printf 'B %s\n' "$x"; k=$((k + 1))
        while [[ "${w[k]:-}" == -* ]]; do [[ "${w[k]}" == "-n" ]] && k=$((k + 1)); k=$((k + 1)); done
        continue ;;
      timeout)
        printf 'B %s\n' "$x"; k=$((k + 1))
        while [[ "${w[k]:-}" == -* ]]; do [[ "${w[k]}" == "-s" || "${w[k]}" == "-k" ]] && k=$((k + 1)); k=$((k + 1)); done
        k=$((k + 1)); continue ;;
      env)
        printf 'B %s\n' "$x"; k=$((k + 1))
        while (( k < m )); do
          case "${w[k]}" in
            -S*|--split-string*) _JBS_FAIL="env -S (a split command string) cannot be checked"; return ;;
            -u|-C|--unset|--chdir) k=$((k + 2)) ;;
            -*|*=*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done
        continue ;;
      xargs)
        printf 'B %s\n' "$x"; k=$((k + 1))
        while (( k < m )); do
          case "${w[k]}" in
            -I|-n|-P|-L|-d|-E|-s|-a|--max-args|--max-procs|--delimiter|--arg-file|--replace|--max-lines|--eof) k=$((k + 2)) ;;
            -*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done
        (( k >= m )) && return
        continue ;;
      sudo|doas) printf 'B %s\n' "$x"; return ;;
    esac
    break
  done
  (( k < m )) || return
  b="${w[k]}"
  if [[ "$b" == *'$'* ]]; then _JBS_FAIL="command name computed at run time ('$b')"; return; fi
  b="${b##*/}"
  [[ -n "$b" ]] || return
  # a function defined earlier on the same line: its body is checked already
  [[ "$_JBS_FUNCS" == *" $b "* ]] && return
  printf 'B %s\n' "$b"
  if (( _JBS_ARGV )); then _jbs_argv_line "$b" "${w[@]:k+1}"; fi
  case "$b" in
    bash|sh|zsh|dash|ksh)
      sc=0; code=""; j=$((k + 1))
      while (( j < m )); do
        x="${w[j]}"
        if (( sc )); then code="$x"; break; fi
        case "$x" in
          -o|+o|-O|+O) j=$((j + 2)); continue ;;
          --*) ;;
          -*c*) sc=1 ;;
          -*|+*) ;;
          *) break ;;
        esac
        j=$((j + 1))
      done
      if (( sc )); then _jbs_parse "$code" 0 "" $((depth + 1)); fi ;;
    eval)
      _jbs_parse "${w[*]:k+1}" 0 "" $((depth + 1)) ;;
    find)
      for (( j = k + 1; j < m; j++ )); do
        case "${w[j]}" in
          -exec|-execdir|-ok|-okdir)
            local -a fx=()
            local f
            for (( f = j + 1; f < m; f++ )); do
              [[ "${w[f]}" == ";" || "${w[f]}" == "+" ]] && break
              fx+=("${w[f]}")
            done
            if (( ${#fx[@]} )); then _jbs_emit "${fx[@]}"; fi
            [[ -n "$_JBS_FAIL" ]] && return
            j=$f ;;
        esac
      done ;;
  esac
}
