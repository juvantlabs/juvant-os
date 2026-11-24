#!/usr/bin/env bash
# tests/lint.sh — shellcheck + bash -n on every script, JSON parse, and YAML
# frontmatter on agents and skills. Needs shellcheck, jq, python3 with PyYAML
# (set PYTHON to pick another interpreter).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0

while IFS= read -r f; do
  shellcheck "$f" || fail=1
  bash -n "$f" || { echo "bash -n failed: $f"; fail=1; }
done < <(git ls-files -co --exclude-standard '*.sh')

while IFS= read -r f; do
  jq empty "$f" 2>/dev/null || { echo "invalid JSON: $f"; fail=1; }
done < <(git ls-files -co --exclude-standard '*.json')

while IFS= read -r f; do
  python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' "$f" || { echo "python syntax error: $f"; fail=1; }
done < <(git ls-files -co --exclude-standard '*.py')

"${PYTHON:-python3}" - <<'PY' || fail=1
import pathlib, re, sys, yaml
bad = []
paths = list(pathlib.Path("framework/agents").glob("*.md")) + list(pathlib.Path("framework/skills").glob("*/SKILL.md"))
for p in paths:
    m = re.match(r"^---\n(.*?)\n---\n", p.read_text(), re.S)
    if not m:
        bad.append(f"{p}: no frontmatter"); continue
    try:
        fm = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError as e:
        bad.append(f"{p}: {e}"); continue
    for key in ("name", "description"):
        if not fm.get(key):
            bad.append(f"{p}: frontmatter lacks {key}")
for b in bad:
    print(b)
print(f"frontmatter: {len(paths)} files, {len(bad)} problems")
sys.exit(1 if bad else 0)
PY

[[ "$fail" == 0 ]] && echo "lint: OK"
exit "$fail"
