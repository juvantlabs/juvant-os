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
PROJECT_SLUG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY=1; shift ;;
    --force) FORCE=1; shift ;;
    --project=*) PROJECT_SLUG="${1#--project=}"; shift ;;
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

# When --project=<slug> is given, override DB routing to the project DB
# and filter template rows to project-scope roles only.
PROJECT_ROLES=(pca product-lead design-lead eng-lead eng-api eng-backend eng-frontend eng-ai)
if [[ -n "$PROJECT_SLUG" ]]; then
  DB_URL=$(jq -r --arg s "$PROJECT_SLUG" '.projects[$s].db.url // .projects[$s].url // ""' "$CONFIG")
  DB_TOKEN=$(jq -r --arg s "$PROJECT_SLUG" '.projects[$s].db.auth_token // .projects[$s].auth_token // ""' "$CONFIG")
  if [[ -z "$DB_URL" ]]; then
    echo "ERROR: project '$PROJECT_SLUG' not found in $CONFIG." >&2; exit 1
  fi
  export TURSO_URL="$DB_URL" TURSO_TOKEN="$DB_TOKEN"
  ROLE_FILTER=$(printf '%s\n' "${PROJECT_ROLES[@]}" | jq -R . | jq -sc .)
  EXPECTED=$(jq --argjson roles "$ROLE_FILTER" '[.rows[] | select(.role as $r | $roles | index($r) != null)] | length' "$TEMPLATE")
else
  ROLE_FILTER="null"
  EXPECTED=$(jq '.rows | length' "$TEMPLATE")
fi

# Resolve the abstract `cloud:write` MCP entry on eng-platform's row per
# `feature_toggles.cloud_provider` ∈ {azure, aws, gcp, none}. The canonical
# template's _doc field declares: "with cloud_provider=none the cloud:write
# entry is dropped from eng-platform's row." Pre-fix the script did not
# honor that contract — every adopter (including cloud_provider=none) seeded
# eng-platform with `cloud:write`, granting cloud-mutation authority to an
# agent on a single-Mac local-only setup that has no cloud control plane.
# Security incident class: framework bug enabling unauthorized agent cloud
# writes (e.g. `az ad app create`). Root-cause fix.
#
# Resolution rules (company scope only — project-scope rows have no
# cloud:write entry today, so the filter is a no-op for --project runs):
#   cloud_provider=none → drop the literal "cloud:write" entry
#   cloud_provider=azure|aws|gcp → keep "cloud:write" (downstream MCP
#     binding resolves the concrete server in .claude/settings.json)
#   cloud_provider missing → default to "none" (safe default, matches the
#     wizard's principle that absent toggles are treated as off)
CLOUD_PROVIDER=$(jq -r '.feature_toggles.cloud_provider // "none"' "$CONFIG")
case "$CLOUD_PROVIDER" in
  azure|aws|gcp) DROP_CLOUD_WRITE=0 ;;
  none|"")       DROP_CLOUD_WRITE=1 ;;
  *)
    echo "ERROR: feature_toggles.cloud_provider='$CLOUD_PROVIDER' not in {azure,aws,gcp,none}." >&2
    exit 1
    ;;
esac

# Refuse to overwrite a populated matrix unless --force.
existing=$(juvant_db_query "SELECT COUNT(*) FROM agent_tool_matrix;" 2>/dev/null | tail -1)
existing="${existing:-0}"
if [[ "$existing" -gt 0 && "$FORCE" != "1" ]]; then
  echo "ERROR: agent_tool_matrix already has $existing rows; pass --force to re-seed." >&2
  exit 2
fi

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

# When filtering to project roles, build a filtered array first.
if [[ -n "$PROJECT_SLUG" ]]; then
  ROWS_JSON=$(jq --argjson roles "$ROLE_FILTER" '[.rows[] | select(.role as $r | $roles | index($r) != null)]' "$TEMPLATE")
else
  ROWS_JSON=$(jq '.rows' "$TEMPLATE")
fi

# Apply cloud_provider=none drop to eng-platform's row (company scope only).
# Targets the literal string "cloud:write" inside mcp_servers; preserves
# every other entry. No-op for project-scope runs (eng-platform is company-
# scope and would not be in the filtered rows anyway).
if [[ "$DROP_CLOUD_WRITE" == "1" && -z "$PROJECT_SLUG" ]]; then
  ROWS_JSON=$(echo "$ROWS_JSON" | jq '
    map(
      if .role == "eng-platform" then
        .mcp_servers |= map(select(. != "cloud:write"))
      else . end
    )
  ')
fi
ROW_COUNT=$(echo "$ROWS_JSON" | jq 'length')

{
  echo "BEGIN;"
  if [[ "$FORCE" == "1" ]]; then
    echo "DELETE FROM agent_tool_matrix;"
  fi
  for i in $(seq 0 $((ROW_COUNT-1))); do
    role=$(echo "$ROWS_JSON" | jq -r ".[$i].role")
    mcps=$(echo "$ROWS_JSON" | jq -c ".[$i].mcp_servers")
    skills=$(echo "$ROWS_JSON" | jq -c ".[$i].skills")
    channels=$(echo "$ROWS_JSON" | jq -c ".[$i].channels")
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
if [[ "$ACTUAL" != "$ROW_COUNT" ]]; then
  echo "ERROR: post-INSERT row count mismatch: expected=$ROW_COUNT, db=$ACTUAL" >&2
  exit 3
fi

echo "OK: seeded $ACTUAL rows into agent_tool_matrix from $TEMPLATE."
