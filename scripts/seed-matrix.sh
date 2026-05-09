#!/usr/bin/env bash
# scripts/seed-matrix.sh
#
# Seed `agent_tool_matrix` v0 from the canonical JSON template.
# The wizard's Step 8 procedure runs this script.
#
# Pre-v0.6.6 the wizard improvised SQL helpers at five different paths
# across five testco runs (Acme: .juvant/_compile.py; Beta:
# /tmp/compile_templates.py; Gamma: /tmp/testco-bootstrap-manifestos.py;
# Delta: .juvant/seed-manifests.py; Echo: /tmp/seed_matrix.sql) and the
# Echo + Golf runs both surfaced errors in the canonical v0 matrix that
# different runs fixed differently — adopter drift. This script is the
# F-7 family fix (companion to F-6 compile-templates.sh and F-8
# audit-bootstrap-baseline.sh): one allowlistable invocation, one
# canonical source (scripts/templates/v0-agent-tool-matrix.json), one
# deterministic INSERT pattern.
#
# Usage:
#   bash scripts/seed-matrix.sh                  # default: all rows
#   bash scripts/seed-matrix.sh --check-only     # dry-run; print SQL, do not exec
#   bash scripts/seed-matrix.sh --force          # re-seed even if rows exist
#
# Exit codes:
#   0   success — 20 rows present in agent_tool_matrix
#   1   prerequisite missing (config / template / jq)
#   2   matrix already populated and --force not passed
#   3   row count mismatch after INSERT (template vs DB)
#
# The canonical template is `scripts/templates/v0-agent-tool-matrix.json`.
# Drift between this file and `agents/company/ca.md` § Default Agent Tool
# Matrix is detected by Step 8.5 cross-check against
# `docs/MCP_INVENTORY.md` (see CSO subagent Layer 5 §11 audit).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$ROOT/.juvant/config.json"
TEMPLATE="$SCRIPT_DIR/templates/v0-agent-tool-matrix.json"

CHECK_ONLY=0
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help)
      sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *) echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: $CONFIG missing — bootstrap not initialized." >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: canonical template $TEMPLATE missing — repo state corrupt." >&2
  exit 1
fi

if ! command -v jq >/dev/null; then
  echo "ERROR: jq required (read JSON template)." >&2
  exit 1
fi

# Source the shared db-routing helper (sqlite3 vs turso CLI by provider).
# shellcheck disable=SC1091
. "$ROOT/hooks/lib/db.sh"

# Refuse to overwrite a populated matrix unless --force. Reads go via
# juvant_db_query, not juvant_db_exec — the latter pipes stdout to
# /dev/null (write-fn semantics) and would always see an empty count.
existing=$(juvant_db_query "SELECT COUNT(*) FROM agent_tool_matrix;" 2>/dev/null | tail -1)
existing="${existing:-0}"
if [[ "$existing" -gt 0 && "$FORCE" != "1" ]]; then
  echo "ERROR: agent_tool_matrix already has $existing rows; pass --force to re-seed." >&2
  exit 2
fi

EXPECTED=$(jq '.rows | length' "$TEMPLATE")
if [[ "$EXPECTED" -eq 0 ]]; then
  echo "ERROR: template has 0 rows — refusing to seed empty matrix." >&2
  exit 1
fi

# Build a single SQL transaction. One INSERT per row; arrays serialized
# as JSON strings so downstream readers can `json_extract` the columns.
# SQLite literals are single-quoted; embedded single quotes escape via
# doubling (`''`). Bash 3.2 ${var//pat/repl} produces broken escapes
# on macOS for literal single-quote replacement (see pre-tool-use.sh
# FEAT-008 comment), so we use a sed-based helper.
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

SQL_BUFFER=$(mktemp)
trap 'rm -f "$SQL_BUFFER"' EXIT

{
  echo "BEGIN;"
  if [[ "$FORCE" == "1" ]]; then
    echo "DELETE FROM agent_tool_matrix;"
  fi
  for i in $(seq 0 $((EXPECTED-1))); do
    role=$(jq -r ".rows[$i].role" "$TEMPLATE")
    mcps=$(jq -c ".rows[$i].mcp_servers" "$TEMPLATE")
    skills=$(jq -c ".rows[$i].skills" "$TEMPLATE")
    channels=$(jq -c ".rows[$i].channels" "$TEMPLATE")
    role_e=$(sql_escape "$role")
    mcps_e=$(sql_escape "$mcps")
    skills_e=$(sql_escape "$skills")
    channels_e=$(sql_escape "$channels")
    printf "INSERT INTO agent_tool_matrix (role, mcp_servers, skills, channels, version, approved_by) VALUES ('%s', '%s', '%s', '%s', 'v0', 'ceo');\n" \
      "$role_e" "$mcps_e" "$skills_e" "$channels_e"
  done
  echo "COMMIT;"
} > "$SQL_BUFFER"

if [[ "$CHECK_ONLY" == "1" ]]; then
  cat "$SQL_BUFFER"
  echo "--- check-only: $EXPECTED rows would be inserted; no SQL executed."
  exit 0
fi

juvant_db_exec_stdin < "$SQL_BUFFER"

# Verify row count matches template. Use juvant_db_query for the read.
ACTUAL=$(juvant_db_query "SELECT COUNT(*) FROM agent_tool_matrix;" | tail -1)
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "ERROR: post-INSERT row count mismatch: template=$EXPECTED, db=$ACTUAL" >&2
  exit 3
fi

echo "OK: seeded $ACTUAL rows into agent_tool_matrix from $TEMPLATE."
