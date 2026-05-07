#!/usr/bin/env bash
# tests/hooks/fake-turso.sh
# Stand-in for the `turso` CLI that redirects `turso db shell` calls
# to a local SQLite file. Used by tests/hooks/run-tests.sh — drop on PATH
# in front of the real `turso` binary so hook scripts call this transparently.
#
# Required env: JUVANT_TEST_DB_FILE — path to the SQLite file.
#
# Supported invocations (only what the hooks actually use):
#   turso db shell <url> "<SQL>"
#   turso db shell <url> --output csv "<SQL>"
#   turso db shell <url> < heredoc
#   turso db shell <url> --output csv < heredoc
#
# Anything else exits 0 silently — production behavior is opaque to tests.

set -uo pipefail

if [[ -z "${JUVANT_TEST_DB_FILE:-}" ]]; then
  echo "fake-turso: JUVANT_TEST_DB_FILE not set" >&2
  exit 1
fi

if [[ "${1:-}" != "db" || "${2:-}" != "shell" ]]; then
  exit 0
fi

shift 2  # consume `db shell`
# Next arg is URL — irrelevant for tests, discard.
shift 1 || true

OUTPUT_FORMAT=""
if [[ "${1:-}" == "--output" ]]; then
  OUTPUT_FORMAT="${2:-}"
  shift 2 || true
fi

SQL="${1:-}"

if [[ "$OUTPUT_FORMAT" == "csv" ]]; then
  if [[ -z "$SQL" ]]; then
    sqlite3 -csv -header "$JUVANT_TEST_DB_FILE"
  else
    sqlite3 -csv -header "$JUVANT_TEST_DB_FILE" "$SQL"
  fi
else
  if [[ -z "$SQL" ]]; then
    sqlite3 "$JUVANT_TEST_DB_FILE"
  else
    sqlite3 "$JUVANT_TEST_DB_FILE" "$SQL"
  fi
fi
