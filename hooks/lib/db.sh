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

# Hard time bound for every DB CLI invocation (BUG-046).
# `turso db shell` is a NETWORK call; without a bound a hung connection
# (latency / token refresh / dropped socket) on the tool gating path in
# pre-tool-use.sh never returns, the allow/deny decision is never emitted,
# the tool never starts, and Claude Code's 600s stream watchdog fires =
# "stall". The old `|| echo WARN` fail-soft only catches non-zero EXITS,
# not hangs — a hung process never reaches `||`. macOS ships neither
# `timeout` nor `gtimeout`, so fall back to a perl alarm (perl is present
# on macOS by default; the alarm timer survives exec and SIGALRM's default
# disposition terminates the exec'd command after the deadline).
# Override the deadline via JUVANT_DB_TIMEOUT (seconds; default 8).
# sqlite3 (local) is wrapped too — it can block on a locked DB file.
_juvant_db_run() {
  local secs="${JUVANT_DB_TIMEOUT:-8}"
  if command -v timeout &>/dev/null; then
    timeout "$secs" "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$secs" "$@"
  else
    perl -e 'my $s=shift; alarm $s; exec @ARGV or exit 127' "$secs" "$@"
  fi
}

# Resolve provider + endpoint. Reads .juvant/config.json; cloud
# paths accept TURSO_URL/TURSO_TOKEN override.
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
    # Legacy-config inference: a pre-v0.8 config carries top-level `.turso_url`
    # with no `.db.provider`. The URL read above already falls back to
    # `.turso_url`, but the provider would stay empty — so every query/exec
    # silently no-ops (and the scheduled helpers FATAL-exit). A top-level
    # `.turso_url` IS a turso config; infer it (mirrors the env inference below).
    if [[ -z "$JUVANT_DB_PROVIDER" ]] \
       && [[ -n "$(jq -r '.turso_url // ""' "$config" 2>/dev/null)" ]]; then
      JUVANT_DB_PROVIDER="turso"
    fi
  fi

  # Env override (cloud paths only).
  if [[ -n "${TURSO_URL:-}" ]]; then JUVANT_DB_URL="$TURSO_URL"; fi
  # shellcheck disable=SC2034  # JUVANT_DB_TOKEN read by juvant_db_exec in same file
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

# Returns the CLI binary the resolved provider needs (echoes name; empty if
# the provider is unknown). Call after juvant_db_resolve.
juvant_db_required_cli() {
  case "$JUVANT_DB_PROVIDER" in
    local)               printf 'sqlite3' ;;
    turso|azure|aws|gcp) printf 'turso' ;;
    *)                   printf '' ;;
  esac
}

# 0 if the provider's CLI is on PATH, 1 otherwise. Scheduled helpers use this
# to FAIL LOUD instead of silently emitting empty results when the CLI is
# missing from a launchd/cron PATH — the db.sh query/exec functions themselves
# `return 1` quietly (fail-soft, correct for the hook gating path, wrong for a
# helper that would otherwise ship an empty Teams card as "success").
juvant_db_cli_ok() {
  local cli; cli="$(juvant_db_required_cli)"
  [[ -n "$cli" ]] && command -v "$cli" &>/dev/null
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
        _juvant_db_run sqlite3 "$JUVANT_DB_PATH" "$sql"
      else
        _juvant_db_run sqlite3 "$JUVANT_DB_PATH" "$sql" >/dev/null 2>&1
      fi
      ;;
    turso|azure|aws|gcp)
      if [[ -z "$JUVANT_DB_URL" ]] || ! command -v turso &>/dev/null; then
        return 1
      fi
      if [[ "${JUVANT_DB_DEBUG:-0}" == "1" ]]; then
        _juvant_db_run turso db shell "$JUVANT_DB_URL" "$sql"
      else
        _juvant_db_run turso db shell "$JUVANT_DB_URL" "$sql" >/dev/null 2>&1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

# FEAT-051: append an audit statement to the local spool instead of
# executing it inline. The allow/deny decision in pre-tool-use.sh never
# depends on the audit write, so the write must NOT sit on the tool
# gating path (where any DB latency is paid by — or, pre-BUG-046, hangs
# — every tool call). The spool is a plain local file; appending is a
# microsecond, network-free, hang-impossible operation. It is drained to
# the DB out-of-band by helpers/drain-audit-spool.sh (launched in the
# background from session-start.sh, so no cron is required).
#
# The statement is collapsed to a single physical line so concurrent
# O_APPEND writes from parallel subagents stay atomic (a single bounded
# write() to an O_APPEND fd is not interleaved; input_summary is already
# truncated upstream, keeping statements well under the atomic-write
# size). Newlines inside the SQL become spaces — harmless, since SQL is
# whitespace-insensitive outside string literals and the only literal
# that can carry a newline (input_summary) is a free-text audit summary.
#
# Fail-safe: if the spool directory is missing or the append fails, fall
# back to a synchronous (timeout-bounded) exec so an audit row is never
# silently dropped.
# Resolve the audit spool path (FEAT-051). Single source of truth shared
# by juvant_db_exec_async (writer) and helpers/drain-audit-spool.sh
# (reader). Honors JUVANT_SPOOL (test isolation / explicit override);
# otherwise the spool lives alongside the resolved config under .juvant/.
juvant_spool_path() {
  if [[ -n "${JUVANT_SPOOL:-}" ]]; then
    printf '%s' "$JUVANT_SPOOL"
    return 0
  fi
  local config="${JUVANT_CONFIG:-${SCRIPT_DIR}/../.juvant/config.json}"
  printf '%s' "$(dirname "$config")/audit-spool.sql"
}

juvant_db_exec_async() {
  local sql="$1"
  juvant_db_resolve
  [[ -z "$JUVANT_DB_PROVIDER" ]] && return 1

  local spool spool_dir
  spool="$(juvant_spool_path)"
  spool_dir="$(dirname "$spool")"
  if [[ ! -d "$spool_dir" ]]; then
    juvant_db_exec "$sql"
    return $?
  fi

  local oneline
  oneline=$(printf '%s' "$sql" | tr '\n' ' ')
  if ! printf '%s\n' "$oneline" >> "$spool" 2>/dev/null; then
    juvant_db_exec "$sql"
    return $?
  fi
  return 0
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
        _juvant_db_run sqlite3 "$JUVANT_DB_PATH"
      else
        _juvant_db_run sqlite3 "$JUVANT_DB_PATH" >/dev/null 2>&1
      fi
      ;;
    turso|azure|aws|gcp)
      if [[ -z "$JUVANT_DB_URL" ]] || ! command -v turso &>/dev/null; then
        return 1
      fi
      if [[ "${JUVANT_DB_DEBUG:-0}" == "1" ]]; then
        _juvant_db_run turso db shell "$JUVANT_DB_URL"
      else
        _juvant_db_run turso db shell "$JUVANT_DB_URL" >/dev/null 2>&1
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
      # No 2>/dev/null (BUG-065 audit): a sqlite3 error surfaces + returns non-zero.
      _juvant_db_run sqlite3 "$JUVANT_DB_PATH" "$sql"
      ;;
    turso|azure|aws|gcp)
      if [[ -z "$JUVANT_DB_URL" ]] || ! command -v turso &>/dev/null; then
        return 1
      fi
      # turso db shell pads scalar output with whitespace; strip it so
      # callers can compare COUNT(*) results with == without false mismatches.
      # No 2>/dev/null (BUG-065 audit): the CLI's error text reaches stderr
      # instead of being swallowed (stdout still flows through tr|grep).
      _juvant_db_run turso db shell "$JUVANT_DB_URL" "$sql" | tr -d ' \t' | grep -v '^$'
      ;;
    *)
      return 1
      ;;
  esac
}

# Read-only query with header-less CSV output, uniform across providers.
#
# local  → `sqlite3 -csv` (no -header): header-less, RFC-style quote-when-needed.
# cloud  → the libsql HTTP `/v2/pipeline` API (JSON), formatted to the SAME CSV.
#          BUG-065: the turso CLI has NO CSV output mode — `--output csv` never
#          existed (verified against `turso db shell --help`, v1.0.26). The old
#          code passed that nonexistent flag and `2>/dev/null`-swallowed the
#          `unknown flag` error, so EVERY cloud CSV read returned empty and
#          silently — disabling the anomaly detector and emitting false
#          all-clears. Errors are now surfaced (a guardrail that fails must say
#          so); an empty result is distinguishable from a failure (rc 0 vs 1).
juvant_db_query_csv() {
  local sql="$1"

  juvant_db_resolve

  case "$JUVANT_DB_PROVIDER" in
    local)
      if [[ -z "$JUVANT_DB_PATH" ]] || ! command -v sqlite3 &>/dev/null; then
        return 1
      fi
      # No 2>/dev/null: a sqlite3 error surfaces on stderr and returns non-zero.
      _juvant_db_run sqlite3 -csv "$JUVANT_DB_PATH" "$sql"
      ;;
    turso|azure|aws|gcp)
      if [[ -z "$JUVANT_DB_URL" ]]; then
        echo "[db.sh] juvant_db_query_csv: no DB URL resolved" >&2
        return 1
      fi
      local _dep _http _req _resp _err
      for _dep in curl jq; do
        command -v "$_dep" >/dev/null 2>&1 || {
          echo "[db.sh] juvant_db_query_csv: '$_dep' required for the libsql HTTP read, not found" >&2
          return 1
        }
      done
      _http="${JUVANT_DB_URL/#libsql:\/\//https://}"   # libsql:// → https://; http(s):// kept
      _req=$(jq -n --arg sql "$sql" \
        '{requests:[{type:"execute",stmt:{sql:$sql}},{type:"close"}]}')
      if [[ -n "$JUVANT_DB_TOKEN" ]]; then
        _resp=$(_juvant_db_run curl -sS -H "Authorization: Bearer $JUVANT_DB_TOKEN" \
          -H 'Content-Type: application/json' --data "$_req" "$_http/v2/pipeline" 2>&1) || {
          echo "[db.sh] juvant_db_query_csv: HTTP request to $_http/v2/pipeline failed: $_resp" >&2
          return 1; }
      else
        _resp=$(_juvant_db_run curl -sS \
          -H 'Content-Type: application/json' --data "$_req" "$_http/v2/pipeline" 2>&1) || {
          echo "[db.sh] juvant_db_query_csv: HTTP request to $_http/v2/pipeline failed: $_resp" >&2
          return 1; }
      fi
      if ! jq -e . >/dev/null 2>&1 <<<"$_resp"; then
        echo "[db.sh] juvant_db_query_csv: non-JSON response from $_http/v2/pipeline: $(printf '%.160s' "$_resp")" >&2
        return 1
      fi
      _err=$(jq -r 'first(.results[]? | select(.type=="error") | .error.message) // ""' <<<"$_resp")
      if [[ -n "$_err" ]]; then
        echo "[db.sh] juvant_db_query_csv: DB error: $_err" >&2
        return 1
      fi
      # Header-less CSV matching `sqlite3 -csv` (quote a field iff it holds
      # a comma, double-quote, CR or LF; NULL → empty field).
      jq -r '
        def csvf: if (type == "string" and test("[\",\r\n]"))
                  then "\"" + gsub("\"";"\"\"") + "\"" else tostring end;
        .results[0].response.result.rows[]? | map((.value // "") | csvf) | join(",")
      ' <<<"$_resp"
      ;;
    *)
      return 1
      ;;
  esac
}
