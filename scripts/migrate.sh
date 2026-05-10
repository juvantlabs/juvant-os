#!/usr/bin/env bash
# migrate.sh — Apply schema.sql to a Juvant OS state database.
#
# Usage:
#   ./scripts/migrate.sh                       # company DB (default)
#   ./scripts/migrate.sh --project=<slug>      # per-project DB (F-24, v0.7.1+)
#
# Reads provider + endpoint from .juvant/config.json:
#   --scope company (default): .db.{provider,url,auth_token}
#   --project=<slug>:          .projects.<slug>.db.{provider,url,auth_token}
#
# Cloud providers (turso/azure/aws/gcp) also accept TURSO_URL + TURSO_TOKEN env overrides.
# Run once per DB: company-<name> and project-<name>.

set -euo pipefail

PROJECT_SLUG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_SLUG="$2"; shift 2 ;;
    --project=*) PROJECT_SLUG="${1#--project=}"; shift ;;
    -h|--help)
      sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *) echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$SCRIPT_DIR/schema.sql"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

if [[ ! -f "$SCHEMA" ]]; then
  echo "ERROR: schema.sql not found at $SCHEMA"
  exit 1
fi

# Resolve provider + endpoint. Env vars override config for cloud paths only;
# the local path always reads .juvant/config.json (no env override defined).
PROVIDER=""
DB_URL=""
DB_TOKEN=""
SCOPE_LABEL="company"

if [[ -f "$CONFIG" ]]; then
  if [[ -n "$PROJECT_SLUG" ]]; then
    # F-24: per-project DB. Read from .projects.<slug>.db.{provider,url,auth_token}.
    SCOPE_LABEL="project=$PROJECT_SLUG"
    if ! jq -e --arg s "$PROJECT_SLUG" '.projects[$s]' "$CONFIG" >/dev/null 2>&1; then
      echo "ERROR: project '$PROJECT_SLUG' not found in $CONFIG (.projects.$PROJECT_SLUG missing)." >&2
      exit 1
    fi
    PROVIDER=$(jq -r --arg s "$PROJECT_SLUG" '.projects[$s].db.provider // ""' "$CONFIG")
    DB_URL=$(jq -r --arg s "$PROJECT_SLUG" '.projects[$s].db.url // ""' "$CONFIG")
    DB_TOKEN=$(jq -r --arg s "$PROJECT_SLUG" '.projects[$s].db.auth_token // ""' "$CONFIG")
  else
    PROVIDER=$(jq -r '.db.provider // ""' "$CONFIG")
    DB_URL=$(jq -r '.db.url // ""' "$CONFIG")
    DB_TOKEN=$(jq -r '.db.auth_token // ""' "$CONFIG")
  fi
fi

# Env override for cloud paths.
if [[ -n "${TURSO_URL:-}" ]]; then DB_URL="$TURSO_URL"; fi
if [[ -n "${TURSO_TOKEN:-}" ]]; then DB_TOKEN="$TURSO_TOKEN"; fi

# Default provider for env-only invocations stays "turso".
if [[ -z "$PROVIDER" && ( -n "${TURSO_URL:-}" || -n "${TURSO_TOKEN:-}" ) ]]; then
  PROVIDER="turso"
fi

if [[ -z "$PROVIDER" ]]; then
  echo "ERROR: db.provider not set in .juvant/config.json (and no TURSO_URL/TURSO_TOKEN env)."
  echo "Run the JUVANT_OS.md wizard Step 2 first, or set provider manually."
  exit 1
fi

case "$PROVIDER" in
  local)
    # db.url is a filesystem path (relative paths resolve from the repo root).
    # Strip libsql `file:` prefix if the wizard wrote it (Foxtrot Corp
    # testco surfaced this in F-20).
    DB_URL="${DB_URL#file:}"
    if [[ -z "$DB_URL" ]]; then
      echo "ERROR: db.url empty for provider=local. Expected a filesystem path."
      exit 1
    fi
    if ! command -v sqlite3 &>/dev/null; then
      echo "ERROR: sqlite3 not found. Install with: brew install sqlite3"
      exit 1
    fi

    # Resolve relative paths from the repo root (parent of scripts/).
    if [[ "$DB_URL" != /* ]]; then
      DB_PATH="$SCRIPT_DIR/../$DB_URL"
    else
      DB_PATH="$DB_URL"
    fi

    mkdir -p "$(dirname "$DB_PATH")"
    echo "Applying schema to local SQLite ($SCOPE_LABEL): $DB_PATH"
    sqlite3 "$DB_PATH" < "$SCHEMA"
    echo "Schema applied successfully."
    ;;

  turso|azure|aws|gcp)
    if [[ -z "$DB_URL" || -z "$DB_TOKEN" ]]; then
      echo "ERROR: db.url and db.auth_token required for provider=$PROVIDER."
      echo "Set them in .juvant/config.json or via TURSO_URL/TURSO_TOKEN env."
      exit 1
    fi
    if ! command -v turso &>/dev/null; then
      echo "ERROR: turso CLI not found."
      echo "Install: brew install tursodatabase/tap/turso"
      exit 1
    fi

    echo "Applying schema to ($SCOPE_LABEL): $DB_URL"
    turso db shell "$DB_URL" < "$SCHEMA"
    echo "Schema applied successfully."
    ;;

  *)
    echo "ERROR: unknown db.provider='$PROVIDER'. Expected one of: local, turso, azure, aws, gcp."
    exit 1
    ;;
esac
