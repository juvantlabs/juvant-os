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
#   turso db shell <url> < heredoc
#
# BUG-065: the real `turso db shell` has NO `--output` flag (it errors with
# `unknown flag: --output`, exit 1). This shim MUST mirror that — an earlier
# version accepted `--output csv` and mapped it to `sqlite3 -csv`, which
# validated a hallucinated flag and let the defect pass CI. CSV reads now go
# through the libsql HTTP API (see tests/hooks/fake-libsql-curl.sh), not here.
#
# BUG-071 — KNOWN DIVERGENCE, do not rely on this shim for output SHAPE.
# `sqlite3 <db> "<SQL>"` below prints header-less, '|'-joined rows with
# whitespace intact. The real `turso db shell` prints a COLUMN HEADER above
# space-padded columns. That gap is why the BUG-071 defects in
# juvant_db_query (header returned as data; empty result set indistinguishable
# from a row; intra-value spaces destroyed) were invisible to every test using
# this shim. Cloud reads now go through the libsql HTTP API, so nothing
# asserts on CLI output shape any more — but if a future test needs to, make
# the shim faithful first rather than trusting it.
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

# Mirror the real CLI: `--output` is not a valid flag.
if [[ "${1:-}" == "--output" ]]; then
  echo "Error: unknown flag: --output" >&2
  exit 1
fi

SQL="${1:-}"

if [[ -z "$SQL" ]]; then
  sqlite3 "$JUVANT_TEST_DB_FILE"
else
  sqlite3 "$JUVANT_TEST_DB_FILE" "$SQL"
fi
