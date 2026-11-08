#!/usr/bin/env bash
# Runs the Python unit tests (tests/unit/test_*.py).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
python3 -m unittest discover -s tests/unit -p 'test_*.py' "$@"
