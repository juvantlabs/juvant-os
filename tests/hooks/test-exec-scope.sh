#!/usr/bin/env bash
# tests/hooks/test-exec-scope.sh
# BUG-103 — a role with no interpreter can't use an allowed binary to run one it
# doesn't have. Direct library checks plus cases through the real hook.
#
# SC2016: the cases are literal shell text, meant not to expand.
# shellcheck disable=SC2016,SC2015

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POLICY="$REPO/hooks/bash-policy.json"
for dep in jq sqlite3; do command -v "$dep" >/dev/null || { echo "SKIP: $dep not installed"; exit 0; }; done

# shellcheck source=hooks/lib/bash-segments.sh
. "$REPO/hooks/lib/bash-segments.sh"
# shellcheck source=hooks/lib/exec-scope.sh
. "$REPO/hooks/lib/exec-scope.sh"

T=$(mktemp -d /tmp/juvant-exec-scope-XXXXXX)
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
R="$T/instance"; O="$T/outside"
mkdir -p "$R/scripts/sub" "$R/helpers" "$R/hooks/lib" "$R/tests" "$O/scripts"
for f in scripts/ok.sh scripts/sub/deep.sh helpers/h.sh hooks/lib/l.sh tests/t.sh x.sh; do
  printf '#!/bin/sh\necho hi\n' > "$R/$f"
done
cp "$R/x.sh" "$O/scripts/ok.sh"
ln -s "$O/scripts/ok.sh" "$R/scripts/link.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
no(){ echo "    FAIL: $1"; FAIL=$((FAIL+1)); }

chk() { # <expected rc> <command> [cwd]
  local rc
  juvant_exec_scope_check "$POLICY" "$2" "$R" "${3:-$R}" >/dev/null; rc=$?
  if [[ "$rc" == "$1" ]]; then ok; else no "rc=$rc, expected $1: $2"; fi
}
deny(){ local c; for c in "$@"; do chk 1 "$c"; done; }
pass(){ local c; for c in "$@"; do chk 0 "$c"; done; }

echo "=== scripts outside the framework ==="
deny 'bash x.sh' 'sh x.sh' 'bash ./x.sh' 'bash tests/t.sh' 'bash scripts/sub/deep.sh' \
     'bash scripts/link.sh' 'bash scripts/missing.sh' "bash $O/scripts/ok.sh" \
     'bash ../outside/scripts/ok.sh' 'bash scripts/../x.sh' 'bash -x x.sh' 'bash -- x.sh'

echo "=== a shell on stdin ==="
deny 'bash' 'bash < x.sh' 'cat x.sh | bash' 'cat x.sh | sh -s' 'bash -s < x.sh' \
     'bash /dev/stdin < x.sh' 'bash <(cat x.sh)' 'bash -i' 'bash --rcfile x.sh' \
     'bash --init-file x.sh scripts/ok.sh'
chk 1 $'bash <<EOF\nsqlite3 a.db\nEOF'

echo "=== computed paths and working directory ==="
deny 'bash "$F"' 'bash $F' 'cd /tmp && bash scripts/ok.sh' "cd $O && bash scripts/ok.sh" \
     "false && cd $R; bash scripts/ok.sh" "(cd $R); bash scripts/ok.sh" \
     "cd $R | bash scripts/ok.sh" "echo \$(cd $R); bash scripts/ok.sh" \
     "cd $R; cd $O; bash scripts/ok.sh"
chk 1 'bash scripts/ok.sh' "$O"

echo "=== environment and config ==="
deny 'BASH_ENV=x.sh bash scripts/ok.sh' 'export BASH_ENV=x.sh; bash scripts/ok.sh' \
     'ENV=x.sh sh scripts/ok.sh' 'PATH=.:$PATH bash scripts/ok.sh' \
     'GIT_SSH_COMMAND=x git fetch' 'GIT_PAGER=x git log' 'PAGER=x git log' 'GH_PAGER=x gh pr list' \
     'echo x >> ~/.gitconfig' 'echo x > ~/.zshenv' 'printf x > ~/.config/gh/config.yml'

echo "=== git and gh ==="
deny "git -c alias.x='!sqlite3 a.db' x" "git -c core.pager=x log"
deny 'git --config-env=core.pager=X log' 'git --git-dir=/tmp/x/.git log' \
     'git bisect run x' 'git filter-branch --tree-filter x' 'git difftool -x x' \
     'git submodule foreach x' 'git rebase -x x main' 'git rebase --exec x main' \
     'git grep -Ox foo' 'git grep --open-files-in-pager=x foo' 'git log --ext-diff' \
     'git fetch --upload-pack=x origin' 'git config alias.x !y' 'git config core.pager x' \
     'git apply p.patch' 'git am p.patch' 'git update-index --add x' 'git hash-object -w x' \
     'git read-tree x' 'git commit-tree x' 'git hook run x' 'git daemon --access-hook=x' \
     'git send-email --sendmail-cmd=x f' 'git archive --remote=x --exec=y main' \
     'gh alias set q --shell x' 'gh extension install o/r' 'gh config set pager x'

echo "=== sort, awk, sed ==="
deny 'sort --compress-program=x f' \
     "awk 'BEGIN{system(\"sqlite3 a.db\")}'" "awk 'BEGIN { system (\"x\") }'" \
     "awk 'BEGIN{\"x\" | getline}'" "awk 'BEGIN{print \"a\" | \"x\"}'" \
     "awk '{print | \"sh\"}' f" "awk -f prog.awk f" 'awk --load x' 'awk "$P" f' \
     "sed -n '1e x' f" "sed 's/a/b/e' f" "sed -e '1e x' f" "sed -f s.sed f" 'sed "$S" f'

echo "=== ordinary work still passes ==="
pass 'bash scripts/ok.sh' 'bash helpers/h.sh' 'bash hooks/lib/l.sh' "bash $R/scripts/ok.sh" \
     "cd $R && bash scripts/ok.sh" "cd $R; bash scripts/ok.sh" \
     'printf x | bash scripts/ok.sh' 'bash scripts/ok.sh < input.txt' 'bash -x scripts/ok.sh' \
     "bash -c 'echo hi'" 'bash helpers/h.sh 30 gh pr view 1' \
     'git status' 'git -C /tmp/x log --oneline' 'git log -p' 'git diff --stat' 'git grep foo' \
     'git config --get user.name' 'git config --list' 'git rebase main' \
     'gh pr list' 'gh config get pager' 'gh api repos/o/r' \
     'sort -u f' "awk '{print \$1}' f" "awk -F'|' '{print \$2}' f" "awk -F, -v n=1 '\$1 > n' f" \
     "awk '/foo|bar/ {n++} END {print n}' f" "awk '\$1 == \"a|b\" || \$2 {print}' f" \
     "awk 'BEGIN{print \"system(x) | y\"}'" "sed -n '1,5p' f" "sed 's/a/b/g' f" \
     "sed -E 's/one e two/x/' f" "sed -e 's/a/b/' -e 's/c/d/' f" \
     'echo "PATH=x is prose"' 'cat x.sh' "turso db shell db 'SELECT 1'" 'echo x > out.txt'

chk 0 "cd $R"$'\n'"bash scripts/ok.sh"
chk 1 "cd $O"$'\n'"bash scripts/ok.sh"

echo "=== roles ==="
for r in cos cfo clo cmo cco chro cetho cro cto vpe product-lead Explore; do
  if juvant_exec_scope_applies "$POLICY" "$r"; then ok; else no "$r should be in scope"; fi
done
for r in cso pca design-lead eng-platform eng-lead eng-api eng-backend eng-frontend eng-ai maintainer; do
  if juvant_exec_scope_applies "$POLICY" "$r"; then no "$r has an interpreter"; else ok; fi
done

echo "=== config files ==="
juvant_exec_scope_path_denied "$HOME/.gitconfig" && ok || no ".gitconfig"
juvant_exec_scope_path_denied "$HOME/.config/gh/config.yml" && ok || no "gh config"
juvant_exec_scope_path_denied "/repo/docs/x.md" && no "ordinary path" || ok

echo "=== the wrapper helper is followed ==="
BINS=$(juvant_bash_binaries 'bash helpers/with-timeout.sh 30 sqlite3 a.db "SELECT 1"')
[[ "$BINS" == *"B sqlite3"* ]] && ok || no "with-timeout: inner binary not listed"
BINS=$(juvant_bash_binaries 'bash helpers/with-timeout.sh 30 gh pr view 1')
[[ "$BINS" == *"B gh"* ]] && ok || no "with-timeout: gh not listed"
cp "$R/x.sh" "$R/helpers/with-timeout.sh"
chk 1 'bash helpers/with-timeout.sh 30 bash x.sh'
chk 0 'bash helpers/with-timeout.sh 30 gh pr view 1'

echo "=== through the real hook ==="
H="$T/hook"; mkdir -p "$H/bin" "$H/repo"
cp -R "$REPO/hooks" "$H/repo/hooks"
cp "$REPO/tests/hooks/fake-turso.sh" "$H/bin/turso"
cp "$REPO/tests/hooks/fake-libsql-curl.sh" "$H/bin/curl"
chmod +x "$H/bin/"*
printf '#!/bin/sh\necho hi\n' > "$H/repo/x.sh"
mkdir -p "$H/repo/scripts"; cp "$H/repo/x.sh" "$H/repo/scripts/ok.sh"
printf '{}' > "$H/config.json"
hook() { # <role> <tool> <input json>: prints the decision reason, then the spool
  rm -f "$H/spool.sql"
  jq -cn --arg t "$2" --arg d "$H/repo" --argjson i "$3" '{tool_name:$t,session_id:"s-es",cwd:$d,tool_input:$i}' \
    | PATH="$H/bin:$PATH" AGENT_ROLE="$1" JUVANT_CONFIG="$H/config.json" JUVANT_FRAMEWORK_DEV=0 \
      JUVANT_SPOOL="$H/spool.sql" TURSO_URL=libsql://fake.test TURSO_TOKEN=x JUVANT_TEST_DB_FILE="$H/none.db" \
      bash "$H/repo/hooks/pre-tool-use.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput | (.permissionDecision + " " + (.permissionDecisionReason // ""))'
}
bash_in() { jq -cn --arg c "$1" '{command:$c}'; }

OUT=$(hook cfo Bash "$(bash_in 'bash x.sh')")
[[ "$OUT" == "deny deny:exec-scope:bash"* ]] && ok || no "cfo: bash x.sh: $OUT"
OUT=$(hook cfo Bash "$(bash_in 'bash scripts/ok.sh')")
[[ "$OUT" == allow* ]] && ok || no "cfo: framework script: $OUT"
grep -q 'script sha256:[0-9a-f]\{12\}' "$H/spool.sql" 2>/dev/null && ok || no "hash not in the audit row"
OUT=$(hook eng-backend Bash "$(bash_in 'bash x.sh')")
[[ "$OUT" == allow* ]] && ok || no "eng-backend is exempt: $OUT"
grep -q 'script sha256:' "$H/spool.sql" 2>/dev/null && ok || no "hash missing for an exempt role"
OUT=$(hook cfo Write "$(jq -cn --arg p "$HOME/.gitconfig" '{file_path:$p,content:"x"}')")
[[ "$OUT" == "deny deny:exec-scope:config"* ]] && ok || no "cfo: Write to .gitconfig: $OUT"
OUT=$(hook cfo Bash "$(bash_in 'bash helpers/with-timeout.sh 5 sqlite3 a.db')")
[[ "$OUT" == "deny deny:allow-list:sqlite3"* ]] && ok || no "cfo: wrapper: $OUT"
OUT=$(hook cfo Monitor "$(bash_in 'bash x.sh')")
[[ "$OUT" == "deny deny:exec-scope:bash"* ]] && ok || no "cfo: Monitor: $OUT"

rm -f "$H/repo/hooks/lib/exec-scope.sh"
OUT=$(hook cfo Bash "$(bash_in 'git status')")
[[ "$OUT" == allow* ]] && ok || no "lib missing mid-sync must not block: $OUT"

echo
echo "RESULTS: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
