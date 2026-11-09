#!/usr/bin/env bash
# tests/sync-example.sh [--check]
# Installs the framework into examples/morvento/.claude/ with the real update
# script (and .claude/settings.json from the template), the way setup does in
# a company repo. With --check, installs into a scratch copy and fails if the
# example has drifted from it. .claude/juvant-os.json (timestamped) is ignored.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FW="$ROOT/framework"
EX="$ROOT/examples/morvento"

install_into() { # <company-dir>
  JUVANT_OS_SETUP=1 bash "$FW/skills/update/update.sh" --from "$FW" --target "$1" --country it >/dev/null
  cp "$FW/templates/settings.json" "$1/.claude/settings.json"
}

if [[ "${1:-}" != "--check" ]]; then
  install_into "$EX"
  rm -f "$EX/.claude/juvant-os.json"
  exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/ex"
install_into "$T/ex"
rm -f "$T/ex/.claude/juvant-os.json"
if diff -r "$T/ex/.claude" "$EX/.claude" >"$T/diff" 2>&1; then
  echo "sync-example: OK"
else
  echo "sync-example: examples/morvento/.claude has drifted from the framework (run bash tests/sync-example.sh):"
  sed 's/^/  /' "$T/diff" | head -20
  exit 1
fi
