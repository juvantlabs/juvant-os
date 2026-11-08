#!/usr/bin/env bash
# tests/sync-example.sh [--check]
# Copies the framework into examples/morvento/.claude/ the way `setup` and
# `update` will in a company repo: agents, hooks, and settings.json from the
# template. With --check, changes nothing and fails if the copy has drifted.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FW="$ROOT/framework"
EX="$ROOT/examples/morvento/.claude"

pairs=(
  "agents/legal.md:agents/legal.md"
  "agents/finance.md:agents/finance.md"
  "agents/ethics.md:agents/ethics.md"
  "hooks/juvant_hooks.py:hooks/juvant_hooks.py"
  "hooks/limits.json:hooks/limits.json"
  "templates/settings.json:settings.json"
)

rc=0
for p in "${pairs[@]}"; do
  src="$FW/${p%%:*}"; dst="$EX/${p##*:}"
  if [[ "${1:-}" == "--check" ]]; then
    cmp -s "$src" "$dst" || { echo "sync-example: drift: examples/morvento/.claude/${p##*:} differs from framework/${p%%:*}"; rc=1; }
  else
    mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"
  fi
done
[[ "${1:-}" == "--check" && "$rc" == 0 ]] && echo "sync-example: OK"
exit "$rc"
