#!/usr/bin/env bash
# hooks/lib/cloud-cli.sh — BUG-076 (juvantlabs/juvant-os-pm#163)
#
# juvant_cloud_cli_check <policy-file> <command>
#   R3 check for agent roles: az, aws, gcloud and terraform run read-only.
#   Works on the parsed argv of every simple command (hooks/lib/bash-segments.sh),
#   so quoted text and heredoc bodies are not commands, while wrappers, bash -c,
#   eval and find -exec are followed.
#
#   The subcommand must be on the `cloud_cli_read_only` allow-list of
#   hooks/bash-policy.json. Anything else fails closed:
#     - a leading flag that is not listed (guessing whether it takes a value
#       would let the verb be read from the wrong word);
#     - a computed word in the command path or as a leading flag's value
#       (an unquoted $x can expand to several words, so it could move the verb);
#     - no subcommand on the line (`xargs az`).
#
#   Returns:
#     0  nothing to deny
#     1  deny; the reason is on stdout
#     3  no argv verdict: the caller runs the raw agent_role_deny_patterns.
#        Used when the line runs a code reader (argv can't see inside
#        `python3 -c`, `echo … | bash`, `bash <<EOF`, awk system()), when the line
#        can't be parsed, or when the policy has no cloud_cli_read_only block.
#
# Requires hooks/lib/bash-segments.sh. Pure bash 3.2 (macOS /bin/bash).

_JCC_US=$'\037'

# Binaries that can run text the argv parser can't see.
_JCC_CODE_READERS=" python python2 python3 node deno bun perl ruby php lua sh bash zsh dash ksh fish awk gawk mawk sed "

juvant_cloud_cli_check() {
  local policy="$1" cmd="$2" line rest bin raw=0 reason rc
  local -a w
  while IFS= read -r line; do
    case "$line" in
      "P "*) raw=1 ;;
      "B "*)
        [[ "$_JCC_CODE_READERS" == *" ${line#B } "* ]] && raw=1 ;;
      "A$_JCC_US"*)
        rest="${line#A"$_JCC_US"}"
        IFS="$_JCC_US" read -r -a w <<<"$rest"
        bin="${w[0]:-}"
        case "$bin" in
          az|aws|gcloud|terraform)
            reason=$(_jcc_verdict "$policy" "${w[@]}"); rc=$?
            if (( rc == 1 )); then printf '%s' "$reason"; return 1; fi
            if (( rc == 3 )); then raw=1; fi ;;
          git)
            # `git -c alias.x='!…'` and friends run text from an argument.
            if [[ "$_JCC_US$rest$_JCC_US" == *"$_JCC_US-c$_JCC_US"* || "$rest" == *"--config-env"* ]]; then raw=1; fi ;;
        esac ;;
    esac
  done < <(juvant_bash_argv "$cmd")
  if (( raw )); then return 3; fi
  return 0
}

_jcc_has() { [[ " $1 " == *" $2 "* ]]; }

# _jcc_verdict <policy> <bin> <args…>
_jcc_verdict() {
  local policy="$1" bin="$2"; shift 2
  local -a a=("$@") path=()
  local n=$# i=0 t name info=0 cfg shape value bool info_flags prefix read write p ok=0 v sub
  cfg=$(jq -r --arg b "$bin" '.cloud_cli_read_only[$b] // empty | [
      .shape, ((.value_flags // []) | join(" ")), ((.bool_flags // []) | join(" ")),
      ((.info_flags // []) | join(" ")), ((.prefix_flags // []) | join(" ")),
      (.read // ""), (.write // "")] | join("\u001f")' "$policy" 2>/dev/null)
  [[ -n "$cfg" ]] || return 3
  IFS="$_JCC_US" read -r shape value bool info_flags prefix read write <<<"$cfg"

  # Leading flags.
  while (( i < n )); do
    t="${a[i]}"
    [[ "$t" == -* ]] || break
    name="${t%%=*}"
    if _jcc_has "$info_flags" "$t"; then info=1; i=$((i + 1)); continue; fi
    if _jcc_has "$bool" "$name"; then i=$((i + 1)); continue; fi
    if _jcc_has "$value" "$name"; then
      if [[ "$t" == *=* ]]; then
        [[ "${t#*=}" != *'$'* ]] || { _jcc_deny "$bin" "computed value in '$name' before the subcommand: put the flag after it"; return 1; }
        i=$((i + 1))
      else
        [[ "${a[i+1]:-}" != *'$'* ]] || { _jcc_deny "$bin" "computed value in '$name' before the subcommand: put the flag after it"; return 1; }
        i=$((i + 2))
      fi
      continue
    fi
    for p in $prefix; do
      if [[ "$t" == "$p"* ]]; then ok=1; break; fi
    done
    if (( ok )); then ok=0; i=$((i + 1)); continue; fi
    _jcc_deny "$bin" "leading flag '$name' is not on its cloud_cli_read_only list"; return 1
  done

  # Command path: every word up to the first flag.
  while (( i < n )); do
    t="${a[i]}"
    [[ "$t" == -* ]] && break
    if [[ "$t" == *'$'* ]]; then _jcc_deny "$bin" "a computed word in the command path can't be checked"; return 1; fi
    path+=("$t"); i=$((i + 1))
  done

  if (( ${#path[@]} == 0 )); then
    (( info )) && return 0
    _jcc_deny "$bin" "no subcommand on the line, so it can't be checked"; return 1
  fi

  case "$shape" in
    first)
      v="${path[0]}"
      sub=$(jq -r --arg b "$bin" --arg v "$v" '.cloud_cli_read_only[$b].read_sub[$v] // empty' "$policy" 2>/dev/null)
      if [[ -n "$sub" ]]; then
        [[ "${path[1]:-}" =~ $sub ]] && return 0
        _jcc_deny "$bin" "'$v ${path[1]:-}' is not read-only"; return 1
      fi
      [[ "$v" =~ $read ]] && return 0
      _jcc_deny "$bin" "'$v' is not read-only"; return 1 ;;
    last)
      v="${path[${#path[@]}-1]}"
      [[ "$v" =~ $read ]] && return 0
      _jcc_deny "$bin" "'$v' is not read-only"; return 1 ;;
    second)
      v="${path[1]:-}"
      [[ -n "$v" && "$v" =~ $read ]] && return 0
      _jcc_deny "$bin" "'${path[0]} $v' is not read-only"; return 1 ;;
    any)
      # A positional name can follow the verb, so the last word proves nothing:
      # a read verb must be present and no word after the group may be a write.
      local k=0 start=1
      [[ "${path[0]}" == "alpha" || "${path[0]}" == "beta" ]] && start=2
      ok=0
      for t in "${path[@]}"; do
        [[ "$t" =~ $read ]] && ok=1
        if (( k >= start )) && [[ "$t" =~ $write ]]; then
          _jcc_deny "$bin" "'$t' is not read-only"; return 1
        fi
        k=$((k + 1))
      done
      (( ok )) && return 0
      _jcc_deny "$bin" "no read-only verb in '${path[*]}'"; return 1 ;;
  esac
  return 3
}

_jcc_deny() {
  printf "agent-role deny-list match (R3 cloud-write defense-in-depth): %s: %s. Agents run cloud CLIs read-only; cloud mutations flow via the terraform-apply GitHub workflow (deployment-spec / eng-platform-spec), never a local CLI. A read-only subcommand that is missing belongs in cloud_cli_read_only in bash-policy.json." "$1" "$2"
}
