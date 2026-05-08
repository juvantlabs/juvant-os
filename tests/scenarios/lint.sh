#!/usr/bin/env bash
# tests/scenarios/lint.sh
# Validates eval scenario files at tests/scenarios/<role>/<name>.yaml
# against the v1.0 schema (tests/scenarios/SCHEMA.md).
#
# Run: bash tests/scenarios/lint.sh
# Exit: 0 on all-pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENTS_DIR="$ROOT_DIR/agents"

# Resolve a Python that has pyyaml available. CI installs system-wide;
# locally most macOS Pythons are PEP 668 protected, so the dev creates
# a project venv with `python3 -m venv .venv && .venv/bin/pip install pyyaml`.
PY=python3
if ! "$PY" -c "import yaml" 2>/dev/null; then
  if [[ -x "$ROOT_DIR/.venv/bin/python" ]] && "$ROOT_DIR/.venv/bin/python" -c "import yaml" 2>/dev/null; then
    PY="$ROOT_DIR/.venv/bin/python"
  else
    echo "tests/scenarios/lint.sh: pyyaml is required." >&2
    echo "Local install:" >&2
    echo "  python3 -m venv .venv && .venv/bin/pip install pyyaml" >&2
    exit 2
  fi
fi

# Build the set of valid roles from agents/{company,projects}/*.md filenames.
VALID_ROLES=$(
  find "$AGENTS_DIR" -maxdepth 2 -type f -name '*.md' \
    -not -name 'README.md' \
    -exec basename {} .md \; | sort -u
)

# Hardcoded allowlist of expected.* keys per SCHEMA.md.
ALLOWED_KEYS=(
  produces_draft
  reads_counterparty_history
  action_type
  no_autonomous_send
  no_confidential_leak
  surfaces_to_cos
  escalates_to_ceo
  audit_log_entry
  disclosure_check_invoked
  manifest_present
)

ACTION_TYPES=(consultation escalation autonomous)

PASS=0
FAIL=0
FILES=$(find "$SCRIPT_DIR" -mindepth 2 -maxdepth 2 -name '*.yaml' | sort)

if [[ -z "$FILES" ]]; then
  echo "tests/scenarios/lint.sh: no scenario files found"
  exit 0
fi

for f in $FILES; do
  rel=${f#"$ROOT_DIR/"}
  errors=()

  # Use python+yaml (already an OS-level dependency for the YAML CI lint).
  "$PY" - "$f" <<'PY' 2>&1 > /tmp/lint-out.$$
import sys, yaml
path = sys.argv[1]
try:
    with open(path) as fh:
        doc = yaml.safe_load(fh)
except yaml.YAMLError as e:
    print(f"YAML_PARSE:{e}")
    sys.exit(1)
if not isinstance(doc, dict):
    print("NOT_DICT:scenario file must be a YAML mapping")
    sys.exit(1)
for k in ("scenario", "role", "inputs", "expected"):
    if k not in doc:
        print(f"MISSING:{k}")
print(f"ROLE:{doc.get('role')}")
inputs = doc.get("inputs") or {}
if not isinstance(inputs, dict) or "prompt" not in inputs:
    print("INPUTS_NO_PROMPT")
expected = doc.get("expected") or {}
if not isinstance(expected, dict):
    print("EXPECTED_NOT_DICT")
else:
    for k, v in expected.items():
        print(f"EXPECTED_KEY:{k}={v}")
PY
  rc=$?
  out=$(cat /tmp/lint-out.$$)
  rm -f /tmp/lint-out.$$

  if [[ $rc -ne 0 || -z "$out" ]]; then
    errors+=("python lint failed: $out")
  fi

  while IFS= read -r line; do
    case "$line" in
      YAML_PARSE:*) errors+=("YAML parse error: ${line#YAML_PARSE:}") ;;
      NOT_DICT:*) errors+=("not a YAML mapping") ;;
      MISSING:*) errors+=("missing required key '${line#MISSING:}'") ;;
      INPUTS_NO_PROMPT) errors+=("inputs.prompt missing") ;;
      EXPECTED_NOT_DICT) errors+=("expected is not a mapping") ;;
      ROLE:*)
        role="${line#ROLE:}"
        if ! echo "$VALID_ROLES" | grep -qx "$role"; then
          errors+=("role '$role' not found in agents/")
        fi
        ;;
      EXPECTED_KEY:*)
        kv="${line#EXPECTED_KEY:}"
        k="${kv%%=*}"
        v="${kv#*=}"
        # Key is allowlisted?
        match=0
        for ok in "${ALLOWED_KEYS[@]}"; do
          [[ "$k" == "$ok" ]] && match=1 && break
        done
        if [[ $match -eq 0 ]]; then
          errors+=("expected key '$k' not in v1.0 allowlist (see SCHEMA.md)")
        fi
        # action_type enum check.
        if [[ "$k" == "action_type" ]]; then
          match=0
          for at in "${ACTION_TYPES[@]}"; do
            [[ "$v" == "$at" ]] && match=1 && break
          done
          if [[ $match -eq 0 ]]; then
            errors+=("action_type '$v' not in {consultation, escalation, autonomous}")
          fi
        fi
        ;;
    esac
  done <<<"$out"

  if [[ ${#errors[@]} -eq 0 ]]; then
    echo "  PASS: $rel"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $rel"
    for e in "${errors[@]}"; do
      echo "    - $e"
    done
    FAIL=$((FAIL+1))
  fi
done

echo
echo "Total: $((PASS+FAIL)) · Passed: $PASS · Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
