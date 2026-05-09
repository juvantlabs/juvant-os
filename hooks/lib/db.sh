#!/usr/bin/env bash
# hooks/lib/db.sh
# Shared database-write helper for Juvant OS hooks.
#
# Routes SQL execution to either `turso db shell` (cloud providers:
# turso/azure/aws/gcp) or `sqlite3 <file>` (provider=local) depending
# on .juvant/config.json `db.provider`. Without this routing, hooks
# that only use `turso db shell` silently no-op on Local SQLite
# adopters — the turso CLI cannot read filesystem paths, so the
# INSERTs swallow their errors via `2>/dev/null` and Track 3 of
# handbook ADR 0004 (audit log) is silently non-functional.
#
# Surfaced by the Delta Corp testco run on 2026-05-08: 0 rows in
# agent_actions_log after a full bootstrap with hundreds of tool
# calls. v0.6.3 fix.
#
# Usage:
#   # Source this file from a hook (hooks/lib/db.sh expects to be
#   # sourced relative to the hook's SCRIPT_DIR/../lib/db.sh).
#   . "$SCRIPT_DIR/lib/db.sh"
#
#   # Execute SQL via the right backend:
#   juvant_db_exec "INSERT INTO agent_actions_log (...) VALUES (...);"
#
#   # Or pipe SQL via stdin (heredoc-friendly):
#   juvant_db_exec_stdin <<'SQL'
#     INSERT INTO ...;
#     UPDATE ...;
#   SQL
#
# Both functions return non-zero on failure and never leak stderr
# unless JUVANT_DB_DEBUG=1. Hooks treat failure as fail-soft (the
# tool decision still gets emitted) per the latency-budget rule.

# Resolve provider + endpoint. Reads .juvant/config.json; cloud
# paths accept TURSO_URL/TURSO_TOKEN env override.
# Sets globals JUVANT_DB_PROVIDER, JUVANT_DB_URL, JUVANT_DB_TOKEN,
# JUVANT_DB_PATH (the latter only for provider=local).
juvant_db_resolve() {
  local config="${JUVANT_CONFIG:-${SCRIPT_DIR}/../.juvant/config.json}"
  JUVANT_DB_PROVIDER=""
  JUVANT_DB_URL=""
  JUVANT_DB_TOKEN=""
  JUVANT_DB_PATH=""

  if [[ -f "$config" ]] && command -v jq &>/dev/null; then
    JUVANT_DB_PROVIDER=$(jq -r '.db.provider // ""' "$config" 2>/dev/null)
    JUVANT_DB_URL=$(jq -r '.db.url // .turso_url // ""' "$config" 2>/dev/null)
    JUVANT_DB_TOKEN=$(jq -r '.db.auth_token // .turso_token // ""' "$config" 2>/dev/null)
  fi

  # Env override (cloud paths only).
  if [[ -n "${TURSO_URL:-}" ]]; then JUVANT_DB_URL="$TURSO_URL"; fi
  if [[ -n "${TURSO_TOKEN:-}" ]]; then JUVANT_DB_TOKEN="$TURSO_TOKEN"; fi

  # Default provider for env-only invocations.
  if [[ -z "$JUVANT_DB_PROVIDER" && ( -n "${TURSO_URL:-}" || -n "${TURSO_TOKEN:-}" ) ]]; then
    JUVANT_DB_PROVIDER="turso"
  fi

  # Resolve filesystem path for local provider.
  # The wizard sometimes writes db.url with a `file:` prefix (libsql URI
  # form) for local provider — strip it so sqlite3 receives a plain path.
  # Surfaced by the Foxtrot Corp testco run on 2026-05-09 (F-20): silent
  # audit-log write failures because `file:.juvant/state.db` was passed
  # verbatim to sqlite3, producing the path `<repo>/file:.juvant/state.db`
  # which sqlite3 interpreted as a literal filename.
  if [[ "$JUVANT_DB_PROVIDER" == "local" && -n "$JUVANT_DB_URL" ]]; then
    local stripped="${JUVANT_DB_URL#file:}"
    if [[ "$stripped" != /* ]]; then
      JUVANT_DB_PATH="${SCRIPT_DIR}/../$stripped"
    else
      JUVANT_DB_PATH="$stripped"
    fi
  fi
}

# Execute SQL passed as the first argument.
# Returns 1 if no usable backend (no provider configured or missing
# CLI), 0 on success, non-zero on SQL error.
juvant_db_exec() {
  local sql="$1"

  juvant_db_resolve

  case "$JUVANT_DB_PROVIDER" in
    local)
      if [[ -z "$JUVANT_DB_PATH" ]] || ! command -v sqlite3 &>/dev/null; then
        return 1
      fi
      if [[ "${JUVANT_DB_DEBUG:-0}" == "1" ]]; then
        sqlite3 "$JUVANT_DB_PATH" "$sql"
      else
        sqlite3 "$JUVANT_DB_PATH" "$sql" >/dev/null 2>&1
      fi
      ;;
    turso|azure|aws|gcp)
      if [[ -z "$JUVANT_DB_URL" ]] || ! command -v turso &>/dev/null; then
        return 1
      fi
      if [[ "${JUVANT_DB_DEBUG:-0}" == "1" ]]; then
        turso db shell "$JUVANT_DB_URL" "$sql"
      else
        turso db shell "$JUVANT_DB_URL" "$sql" >/dev/null 2>&1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

# Execute SQL piped via stdin (heredoc-friendly).
juvant_db_exec_stdin() {
  juvant_db_resolve

  case "$JUVANT_DB_PROVIDER" in
    local)
      if [[ -z "$JUVANT_DB_PATH" ]] || ! command -v sqlite3 &>/dev/null; then
        return 1
      fi
      if [[ "${JUVANT_DB_DEBUG:-0}" == "1" ]]; then
        sqlite3 "$JUVANT_DB_PATH"
      else
        sqlite3 "$JUVANT_DB_PATH" >/dev/null 2>&1
      fi
      ;;
    turso|azure|aws|gcp)
      if [[ -z "$JUVANT_DB_URL" ]] || ! command -v turso &>/dev/null; then
        return 1
      fi
      if [[ "${JUVANT_DB_DEBUG:-0}" == "1" ]]; then
        turso db shell "$JUVANT_DB_URL"
      else
        turso db shell "$JUVANT_DB_URL" >/dev/null 2>&1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

# Read-only query that captures stdout (default text output).
juvant_db_query() {
  local sql="$1"

  juvant_db_resolve

  case "$JUVANT_DB_PROVIDER" in
    local)
      if [[ -z "$JUVANT_DB_PATH" ]] || ! command -v sqlite3 &>/dev/null; then
        return 1
      fi
      sqlite3 "$JUVANT_DB_PATH" "$sql" 2>/dev/null
      ;;
    turso|azure|aws|gcp)
      if [[ -z "$JUVANT_DB_URL" ]] || ! command -v turso &>/dev/null; then
        return 1
      fi
      turso db shell "$JUVANT_DB_URL" "$sql" 2>/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

# Read-only query with CSV output (the two CLIs have different flags
# for CSV — sqlite3 uses `-csv`, turso uses `--output csv`).
juvant_db_query_csv() {
  local sql="$1"

  juvant_db_resolve

  case "$JUVANT_DB_PROVIDER" in
    local)
      if [[ -z "$JUVANT_DB_PATH" ]] || ! command -v sqlite3 &>/dev/null; then
        return 1
      fi
      sqlite3 -csv "$JUVANT_DB_PATH" "$sql" 2>/dev/null
      ;;
    turso|azure|aws|gcp)
      if [[ -z "$JUVANT_DB_URL" ]] || ! command -v turso &>/dev/null; then
        return 1
      fi
      turso db shell --output csv "$JUVANT_DB_URL" "$sql" 2>/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}
