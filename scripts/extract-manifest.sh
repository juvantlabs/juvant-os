#!/usr/bin/env bash
# scripts/extract-manifest.sh
# Extract a manifesto body from a compiled agent file (BUG-103).
#
# The manifesto of record is the compiled agent file without its YAML
# frontmatter, verbatim. Bootstrap (company Step 9, project Step 5) uses this
# script so no session has to rebuild the body by hand: a hand-written body is
# a summary nobody reviewed, and it would become the manifesto of record.
#
# Usage:
#   bash scripts/extract-manifest.sh <agent-file>
#       Print the body.
#   bash scripts/extract-manifest.sh --insert <agent> <agent-file> [<agent> <agent-file> ...]
#       Print one Step 9 INSERT statement per agent (status 'pending',
#       version '1.0'), with the body as a quoted SQL literal. Write it to a
#       file and redirect the file into the DB client, so the SQL gate can
#       read it (it denies SQL piped in from another command):
#         bash scripts/extract-manifest.sh --insert cfo agents/company/cfo.md \
#           > /tmp/manifests.sql
#         sqlite3 <db-path> < /tmp/manifests.sql
#   bash scripts/extract-manifest.sh --check <agent-file> <content-file>
#       Exit 0 if <content-file> holds exactly the body, 1 otherwise.
#
# Exit codes: 0 ok, 1 check mismatch, 2 usage or unreadable file, 3 the file
# has no frontmatter or an empty body.

set -euo pipefail

usage() {
  awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" >&2
  exit 2
}

# body_awk: everything after the second '---' line, trailing blank lines
# dropped, one final newline. With -v sql=1 the body is emitted with single
# quotes doubled, ready to sit inside a SQL string literal. All text work is in
# awk: bash 3.2 (macOS) pattern substitution is quadratic on a 40 KB body.
# shellcheck disable=SC2016  # awk program text, not shell expansions
BODY_AWK='
  f { buf[++k] = $0; next }
  /^---[[:space:]]*$/ { n++; if (n == 2) f = 1 }
  END {
    while (k > 0 && buf[k] ~ /^[[:space:]]*$/) k--
    for (i = 1; i <= k; i++) {
      line = buf[i]
      if (sql) gsub(/\047/, "\047\047", line)
      print line
    }
  }'

body() {
  local file="$1" sql="${2:-0}"
  [[ -r "$file" && -f "$file" ]] || { echo "extract-manifest: cannot read $file" >&2; exit 2; }
  if [[ "$(head -n 1 "$file")" != "---" ]]; then
    echo "extract-manifest: $file has no YAML frontmatter" >&2
    exit 3
  fi
  # No early-exit reader here: with pipefail, grep -q's SIGPIPE reads as empty.
  if [[ "$(awk "$BODY_AWK" "$file" | awk 'NF { c++ } END { print c + 0 }')" -eq 0 ]]; then
    echo "extract-manifest: $file has an empty body" >&2
    exit 3
  fi
  awk -v sql="$sql" "$BODY_AWK" "$file"
}

case "${1:-}" in
  --insert)
    shift
    [[ $# -ge 2 && $(( $# % 2 )) -eq 0 ]] || usage
    # Validate every pair before printing anything, so a bad pair leaves no
    # partial SQL file that could be loaded by mistake.
    args=("$@")
    i=0
    while [[ $i -lt ${#args[@]} ]]; do
      [[ "${args[$i]}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
        echo "extract-manifest: invalid agent name '${args[$i]}'" >&2; exit 2; }
      body "${args[$((i + 1))]}" >/dev/null
      i=$((i + 2))
    done
    while [[ $# -gt 0 ]]; do
      printf "INSERT INTO manifests (agent, content, version, status, tier, deadline, tier1_bootstrap, precondition_bypassed, created_at)\nVALUES ('%s', '" "$1"
      # The literal ends without the body's final newline, matching $(...).
      body "$2" 1 | awk 'NR > 1 { print prev } { prev = $0 } END { printf "%s", prev }'
      printf "', '1.0', 'pending', 1, NULL, 0, NULL, CURRENT_TIMESTAMP);\n"
      shift 2
    done
    ;;
  --check)
    [[ $# -eq 3 ]] || usage
    [[ -r "$3" ]] || { echo "extract-manifest: cannot read $3" >&2; exit 2; }
    tmp=$(mktemp "${TMPDIR:-/tmp}/extract-manifest-XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    body "$2" > "$tmp"
    # Compare ignoring trailing newlines on both sides (DB clients add one).
    if cmp -s <(awk "$BODY_AWK" f=1 "$tmp") <(awk "$BODY_AWK" f=1 "$3"); then exit 0; fi
    echo "extract-manifest: content of $3 differs from the body of $2 ($(wc -c < "$3" | tr -d ' ') vs $(wc -c < "$tmp" | tr -d ' ') bytes)" >&2
    exit 1
    ;;
  -h|--help|"")
    usage
    ;;
  -*)
    usage
    ;;
  *)
    [[ $# -eq 1 ]] || usage
    body "$1"
    ;;
esac
