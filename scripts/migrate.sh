#!/usr/bin/env bash
# migrate.sh — Apply schema.sql to a Turso database
# Usage: ./scripts/migrate.sh
# Requires: TURSO_URL and TURSO_TOKEN environment variables (or .juvant/config.json)
# Run once per DB: company-<name> and project-<name>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$SCRIPT_DIR/schema.sql"

if [[ ! -f "$SCHEMA" ]]; then
  echo "ERROR: schema.sql not found at $SCHEMA"
  exit 1
fi

# Load credentials from env or .juvant/config.json
# Config schema: { db: { provider, url, auth_token, scope } } — see JUVANT_OS.md Wizard Step 2.
if [[ -z "${TURSO_URL:-}" || -z "${TURSO_TOKEN:-}" ]]; then
  CONFIG="$SCRIPT_DIR/../.juvant/config.json"
  if [[ -f "$CONFIG" ]]; then
    TURSO_URL=$(jq -r '.db.url // ""' "$CONFIG")
    TURSO_TOKEN=$(jq -r '.db.auth_token // ""' "$CONFIG")
  fi
fi

if [[ -z "${TURSO_URL:-}" || -z "${TURSO_TOKEN:-}" ]]; then
  echo "ERROR: TURSO_URL and TURSO_TOKEN required."
  echo "Set as environment variables or add to .juvant/config.json"
  exit 1
fi

# Check turso CLI
if ! command -v turso &>/dev/null; then
  echo "ERROR: turso CLI not found."
  echo "Install: brew install tursodatabase/tap/turso"
  exit 1
fi

echo "Applying schema to: $TURSO_URL"
turso db shell "$TURSO_URL" < "$SCHEMA"
echo "Schema applied successfully."
