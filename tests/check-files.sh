#!/usr/bin/env bash
# tests/check-files.sh [framework-dir]
# Fails if framework/FILES and the files under framework/ differ in either
# direction. FILES itself is not listed.
set -euo pipefail
dir="${1:-$(cd "$(dirname "$0")/.." && pwd)/framework}"
[[ -f "$dir/FILES" ]] || { echo "check-files: $dir/FILES missing" >&2; exit 1; }

listed=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$dir/FILES" | LC_ALL=C sort)
present=$(cd "$dir" && find . -type f ! -path ./FILES | sed 's#^\./##' | LC_ALL=C sort)

missing=$(LC_ALL=C comm -23 <(printf '%s\n' "$listed") <(printf '%s\n' "$present") | grep -v '^$' || true)
unlisted=$(LC_ALL=C comm -13 <(printf '%s\n' "$listed") <(printf '%s\n' "$present") | grep -v '^$' || true)
dupes=$(printf '%s\n' "$listed" | uniq -d)

rc=0
[[ -z "$missing" ]]  || { echo "check-files: listed in FILES but absent:"; printf '  %s\n' "$missing"; rc=1; }
[[ -z "$unlisted" ]] || { echo "check-files: present but not in FILES:"; printf '  %s\n' "$unlisted"; rc=1; }
[[ -z "$dupes" ]]    || { echo "check-files: listed twice:"; printf '  %s\n' "$dupes"; rc=1; }
[[ "$rc" == 0 ]] && echo "check-files: OK ($(printf '%s\n' "$listed" | grep -c .) paths)"
exit "$rc"
