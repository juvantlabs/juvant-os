#!/usr/bin/env bash
# migrate.sh — Apply schema.sql, OR run version-pair migration on a Juvant OS state database.
#
# Modes:
#
# 1) Schema apply (default; backward-compat with pre-v0.8 callers):
#    ./scripts/migrate.sh                       # company DB
#    ./scripts/migrate.sh --project=<slug>      # per-project DB (F-24, v0.7.1+)
#
#    Reads provider + endpoint from .juvant/config.json:
#      --scope company (default): .db.{provider,url,auth_token}
#      --project=<slug>:          .projects.<slug>.db.{provider,url,auth_token}
#    Cloud providers (turso/azure/aws/gcp) also accept TURSO_URL + TURSO_TOKEN env overrides.
#    Run once per DB: company-<name> and project-<name>.
#
# 2) Version-pair migration (v0.8.0+; ADR 0014 §7):
#    ./scripts/migrate.sh --from=v0.7 --to=v0.8
#    ./scripts/migrate.sh --from=v0.7 --to=v0.8 --dry-run
#
#    Migrates an adopter's v0.7.x fork to v0.8.0 baseline:
#      a. Pre-flight: verify state.db.bootstrap_completed_at IS NOT NULL
#         (only post-bootstrap forks need migration; new forks start clean
#         at v0.8.0). Refuse to run if state suggests a different version.
#      b. Rename agent files in place via `git mv` (preserves compiled
#         per-company content + git history).
#      c. Create role_aliases table if not present; insert old→new
#         identifier rows for audit-time joins.
#      d. Update active agents.agent column rows to new identifiers.
#      e. Supersede old agent_tool_matrix rows; insert new rows from
#         scripts/templates/v0-agent-tool-matrix.json.
#      f. Update .juvant/config.json agent_names keys (ca→cto company;
#         per-project cto/cpo/cdo/coo/vpe → pca/product-lead/design-lead/
#         eng-lead/<removed>).
#      g. Update hooks/bash-policy.json keys (idempotent — checks for
#         old keys before renaming).
#      h. Leave manifests/decisions/agent_actions_log/inbound_queue/
#         security_audit_log rows untouched (audit-time joins via
#         role_aliases view).
#      i. Print remediation summary; instruct adopter to re-run
#         compile-templates.sh manually (re-running is config-coupled
#         and needs adopter judgment on stale tunables).
#      j. Do NOT re-run bootstrap.
#
# Exit codes:
#   0   success (or dry-run completed)
#   1   pre-flight failed / config missing / unsupported provider
#   2   version-pair not supported (only v0.7→v0.8 in v0.8.0)
#   3   adopter state suggests already migrated (refuse to re-run)

set -euo pipefail

# ─────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────

PROJECT_SLUG=""
FROM_VERSION=""
TO_VERSION=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_SLUG="$2"; shift 2 ;;
    --project=*) PROJECT_SLUG="${1#--project=}"; shift ;;
    --from) FROM_VERSION="$2"; shift 2 ;;
    --from=*) FROM_VERSION="${1#--from=}"; shift ;;
    --to) TO_VERSION="$2"; shift 2 ;;
    --to=*) TO_VERSION="${1#--to=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '/^# Modes:/,/^# Exit codes:/p' "$0" | sed 's/^# *//' | sed '$d'
      exit 0
      ;;
    *) echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMA="$SCRIPT_DIR/schema.sql"
CONFIG="$ROOT/.juvant/config.json"
# decisions#305 B1b: DB tokens come from .juvant/secrets.json.
# (A failed `.` aborts bash outright — `|| fallback` never runs — so test first.)
if [[ -f "$ROOT/hooks/lib/secrets.sh" ]]; then
  # shellcheck disable=SC1091
  . "$ROOT/hooks/lib/secrets.sh"
else
  juvant_secret_get() { jq -r "(${1}) // empty" "${2:-$CONFIG}" 2>/dev/null || true; }
fi

# ─────────────────────────────────────────────
# Mode selection
# ─────────────────────────────────────────────

if [[ -n "$FROM_VERSION" || -n "$TO_VERSION" ]]; then
  if [[ -z "$FROM_VERSION" || -z "$TO_VERSION" ]]; then
    echo "ERROR: both --from and --to required for version-pair migration." >&2
    exit 1
  fi
  if [[ "$FROM_VERSION" != "v0.7" || "$TO_VERSION" != "v0.8" ]]; then
    echo "ERROR: only --from=v0.7 --to=v0.8 supported in v0.8.0." >&2
    echo "Other version pairs ship with their respective releases." >&2
    exit 2
  fi
  MODE="version-pair"
else
  MODE="schema-apply"
fi

# ─────────────────────────────────────────────
# Mode 1: Schema apply (legacy)
# ─────────────────────────────────────────────

run_schema_apply() {
  if [[ ! -f "$SCHEMA" ]]; then
    echo "ERROR: schema.sql not found at $SCHEMA"
    exit 1
  fi

  local PROVIDER="" DB_URL="" DB_TOKEN="" SCOPE_LABEL="company"

  if [[ -f "$CONFIG" ]]; then
    if [[ -n "$PROJECT_SLUG" ]]; then
      SCOPE_LABEL="project=$PROJECT_SLUG"
      if ! jq -e --arg s "$PROJECT_SLUG" '.projects[$s]' "$CONFIG" >/dev/null 2>&1; then
        echo "ERROR: project '$PROJECT_SLUG' not found in $CONFIG (.projects.$PROJECT_SLUG missing)." >&2
        exit 1
      fi
      # Support both nested (.db.provider) and flat (.provider) config shapes.
      PROVIDER=$(jq -r --arg s "$PROJECT_SLUG" '.projects[$s].db.provider // .projects[$s].provider // ""' "$CONFIG")
      DB_URL=$(jq -r --arg s "$PROJECT_SLUG" '.projects[$s].db.url // .projects[$s].url // ""' "$CONFIG")
      DB_TOKEN=$(juvant_secret_get ".projects[\"$PROJECT_SLUG\"].db.auth_token // .projects[\"$PROJECT_SLUG\"].auth_token" "$CONFIG")
    else
      PROVIDER=$(jq -r '.db.provider // ""' "$CONFIG")
      DB_URL=$(jq -r '.db.url // ""' "$CONFIG")
      DB_TOKEN=$(juvant_secret_get '.db.auth_token' "$CONFIG")
    fi
  fi

  if [[ -n "${TURSO_URL:-}" ]]; then DB_URL="$TURSO_URL"; fi
  if [[ -n "${TURSO_TOKEN:-}" ]]; then DB_TOKEN="$TURSO_TOKEN"; fi
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
      DB_URL="${DB_URL#file:}"
      if [[ -z "$DB_URL" ]]; then
        echo "ERROR: db.url empty for provider=local. Expected a filesystem path."
        exit 1
      fi
      if ! command -v sqlite3 &>/dev/null; then
        echo "ERROR: sqlite3 not found. Install with: brew install sqlite3"
        exit 1
      fi
      local DB_PATH
      if [[ "$DB_URL" != /* ]]; then
        DB_PATH="$ROOT/$DB_URL"
      else
        DB_PATH="$DB_URL"
      fi
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "$(dry) would apply $SCHEMA to local SQLite ($SCOPE_LABEL): $DB_PATH"
        echo "$(dry) would then apply idempotent schema patches (ALTER TABLE ADD COLUMN + trigger DROP/CREATE) — NO write performed"
        return 0
      fi
      mkdir -p "$(dirname "$DB_PATH")"
      echo "Applying schema to local SQLite ($SCOPE_LABEL): $DB_PATH"
      PATCH_PROVIDER=local; PATCH_TARGET="$DB_PATH"
      apply_column_prepatches "$PROJECT_SLUG"
      sqlite3 "$DB_PATH" < "$SCHEMA"
      apply_schema_patches "$PROJECT_SLUG"
      verify_schema "$PROJECT_SLUG" || exit 1
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
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "$(dry) would apply $SCHEMA to ($SCOPE_LABEL): $DB_URL"
        echo "$(dry) would then apply idempotent schema patches (ALTER TABLE ADD COLUMN + trigger DROP/CREATE) — NO write performed"
        return 0
      fi
      echo "Applying schema to ($SCOPE_LABEL): $DB_URL"
      PATCH_PROVIDER=turso; PATCH_TARGET="$DB_URL"
      apply_column_prepatches "$PROJECT_SLUG"
      turso db shell "$DB_URL" < "$SCHEMA"
      apply_schema_patches "$PROJECT_SLUG"
      verify_schema "$PROJECT_SLUG" || exit 1
      echo "Schema applied successfully."
      ;;
    *)
      echo "ERROR: unknown db.provider='$PROVIDER'. Expected one of: local, turso, azure, aws, gcp."
      exit 1
      ;;
  esac
}

# Idempotent schema patches. Turso/libSQL has no ALTER TABLE ADD COLUMN
# IF NOT EXISTS, so each statement runs separately. Failures are classified
# rather than blanket-suppressed (BUG-040): a benign "duplicate column" /
# "already exists" on an idempotent re-run is ignored, any OTHER failure is
# surfaced as a counted warning. One copy of every patch list serves both the
# local and the turso branch (PATCH_PROVIDER / PATCH_TARGET), so they cannot
# drift.
#
# Order (BUG-080 #1): the ADD COLUMN patches run BEFORE schema.sql as well as
# after it. schema.sql creates triggers that name columns an old DB may lack
# (e.g. security_audit_log.session_id); SQLite does not validate a trigger body
# at CREATE time, so until the column exists every write to that table fails
# with "no such column" — and if the run aborted in between, the gap stayed.
# Then verify_schema (BUG-080 #2) reads back every object the run should have
# produced, because the turso CLI can exit 0 without having done anything
# (expired auth).

MIGRATE_PATCH_WARNINGS=0
PATCH_PROVIDER=""
PATCH_TARGET=""

_is_benign_patch_err() {
  case "$1" in
    *"duplicate column name"*|*"already exists"*) return 0 ;;
    *) return 1 ;;
  esac
}

# </dev/null: callers loop over `_patch_list` on stdin — the CLI must not eat it.
_patch_sql() {
  if [[ "$PATCH_PROVIDER" == "local" ]]; then sqlite3 "$PATCH_TARGET" "$1" </dev/null
  else turso db shell "$PATCH_TARGET" "$1" </dev/null; fi
}

# Run one idempotent patch; suppress only benign idempotent-re-run errors,
# surface everything else as a counted warning (BUG-040). $2 = 1 also treats
# "no such table" as benign (the pre-schema pass, where a fresh DB has no
# tables yet — schema.sql creates them with every column).
_run_patch() {
  local sql="$1" pre="${2:-0}" err
  err=$(_patch_sql "$sql" 2>&1) && return 0
  _is_benign_patch_err "$err" && return 0
  [[ "$pre" == "1" && "$err" == *"no such table"* ]] && return 0
  printf 'WARN [migrate]: non-benign schema patch failure: %s\n  SQL: %.140s\n' "$err" "$sql" >&2
  MIGRATE_PATCH_WARNINGS=$((MIGRATE_PATCH_WARNINGS + 1))
}

# R5b/R5c audit immutability (decisions#303/#308) — shared by the local AND the
# turso branch (one copy, so the two cannot drift). schema.sql's
# `CREATE … IF NOT EXISTS` installs these objects on a DB that never had them,
# but never REPLACES a changed definition on an existing DB — hence DROP+CREATE
# here, like the decisions category triggers. tests/schema/validate.py asserts
# every CREATE below is identical (whitespace-normalized) to schema.sql's.
#
# The leading ADD COLUMN patches make sure every column the triggers reference
# exists on old DBs: SQLite does not validate trigger bodies at CREATE time, so
# a trigger naming a missing column would make EVERY later UPDATE on the table
# fail ("no such column") — silently bricking the audit writers. (decisions.scope
# is listed for the same reason: the pre-existing enforce_global_scope_master_only_upd
# trigger reads NEW.scope on every decisions UPDATE, but its ADD COLUMN was
# company-only, so an old-shape PROJECT DB could not approve/execute decisions.)
R5_AUDIT_PATCHES=(
  "ALTER TABLE security_audit_log ADD COLUMN session_id         TEXT;"
  "ALTER TABLE security_audit_log ADD COLUMN layer              TEXT;"
  "ALTER TABLE security_audit_log ADD COLUMN finding            TEXT;"
  "ALTER TABLE security_audit_log ADD COLUMN severity           TEXT;"
  "ALTER TABLE security_audit_log ADD COLUMN category           TEXT;"
  "ALTER TABLE security_audit_log ADD COLUMN status             TEXT DEFAULT 'open';"
  "ALTER TABLE security_audit_log ADD COLUMN bootstrap_baseline INTEGER DEFAULT 0;"
  "ALTER TABLE security_audit_log ADD COLUMN resolved_at        DATETIME;"
  "ALTER TABLE agent_actions_log ADD COLUMN session_id          TEXT;"
  "ALTER TABLE agent_actions_log ADD COLUMN result_hash         TEXT;"
  "ALTER TABLE agent_actions_log ADD COLUMN deny_reason         TEXT;"
  "ALTER TABLE agent_actions_log ADD COLUMN ended_at            DATETIME;"
  "ALTER TABLE decisions ADD COLUMN rationale                   TEXT;"
  "ALTER TABLE decisions ADD COLUMN category                    TEXT;"
  "ALTER TABLE decisions ADD COLUMN approved_by                 TEXT;"
  "ALTER TABLE decisions ADD COLUMN approved_at                 DATETIME;"
  "ALTER TABLE decisions ADD COLUMN executed_by                 TEXT;"
  "ALTER TABLE decisions ADD COLUMN executed_at                 DATETIME;"
  "ALTER TABLE decisions ADD COLUMN scope                       TEXT DEFAULT 'company';"
  "DROP TRIGGER IF EXISTS security_audit_log_no_delete;"
  "CREATE TRIGGER security_audit_log_no_delete BEFORE DELETE ON security_audit_log BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): DELETE on security_audit_log is forbidden — record a test_artifact or closure row in audit_events instead'); END;"
  "DROP TRIGGER IF EXISTS security_audit_log_no_replace;"
  "CREATE TRIGGER security_audit_log_no_replace BEFORE INSERT ON security_audit_log WHEN NEW.id IS NOT NULL BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): security_audit_log id already exists — rows are never replaced') WHERE EXISTS (SELECT 1 FROM security_audit_log WHERE id = NEW.id); END;"
  "DROP TRIGGER IF EXISTS security_audit_log_immutable_fields;"
  "CREATE TRIGGER security_audit_log_immutable_fields BEFORE UPDATE ON security_audit_log WHEN NEW.id IS NOT OLD.id OR NEW.auditor IS NOT OLD.auditor OR NEW.session_id IS NOT OLD.session_id OR NEW.scope IS NOT OLD.scope OR NEW.audit_type IS NOT OLD.audit_type OR NEW.layer IS NOT OLD.layer OR NEW.finding IS NOT OLD.finding OR NEW.severity IS NOT OLD.severity OR NEW.category IS NOT OLD.category OR NEW.bootstrap_baseline IS NOT OLD.bootstrap_baseline OR NEW.created_at IS NOT OLD.created_at BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): security_audit_log evidentiary columns are immutable — record a severity_change / timestamp_correction / note row in audit_events instead'); END;"
  "DROP TRIGGER IF EXISTS security_audit_log_created_at_db_clock;"
  "CREATE TRIGGER security_audit_log_created_at_db_clock BEFORE INSERT ON security_audit_log BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): security_audit_log.created_at must be the DB clock — omit it or use CURRENT_TIMESTAMP (tolerance 120s)') WHERE julianday(NEW.created_at) IS NULL OR abs(julianday(NEW.created_at) - julianday('now')) * 86400.0 > 120; END;"
  "DROP TRIGGER IF EXISTS security_audit_log_verdict_severity;"
  "CREATE TRIGGER security_audit_log_verdict_severity BEFORE INSERT ON security_audit_log WHEN NEW.category = 'audit-verdict' AND NEW.session_id IS NOT NULL BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#308): a CSO verdict row must carry the severity of the highest finding of the same audit (session_id) — write findings first, then the verdict') WHERE COALESCE(CASE lower(trim(NEW.severity)) WHEN 'p0' THEN 4 WHEN 'critical' THEN 4 WHEN 'p1' THEN 3 WHEN 'high' THEN 3 WHEN 'p2' THEN 2 WHEN 'medium' THEN 2 WHEN 'low' THEN 1 WHEN 'info' THEN 0 END, -1) < (SELECT max(CASE lower(trim(f.severity)) WHEN 'p0' THEN 4 WHEN 'critical' THEN 4 WHEN 'p1' THEN 3 WHEN 'high' THEN 3 WHEN 'p2' THEN 2 WHEN 'medium' THEN 2 WHEN 'low' THEN 1 WHEN 'info' THEN 0 END) FROM security_audit_log f WHERE f.session_id = NEW.session_id AND f.auditor = NEW.auditor AND f.category IS NOT 'audit-verdict'); END;"
  "DROP TRIGGER IF EXISTS agent_actions_log_no_delete;"
  "CREATE TRIGGER agent_actions_log_no_delete BEFORE DELETE ON agent_actions_log BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): DELETE on agent_actions_log is forbidden — record a test_artifact or note row in audit_events instead'); END;"
  "DROP TRIGGER IF EXISTS agent_actions_log_no_replace;"
  "CREATE TRIGGER agent_actions_log_no_replace BEFORE INSERT ON agent_actions_log WHEN NEW.id IS NOT NULL BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): agent_actions_log id already exists — rows are never replaced') WHERE EXISTS (SELECT 1 FROM agent_actions_log WHERE id = NEW.id); END;"
  "DROP TRIGGER IF EXISTS agent_actions_log_immutable_fields;"
  "CREATE TRIGGER agent_actions_log_immutable_fields BEFORE UPDATE ON agent_actions_log WHEN NEW.id IS NOT OLD.id OR NEW.session_id IS NOT OLD.session_id OR NEW.agent IS NOT OLD.agent OR NEW.tool_name IS NOT OLD.tool_name OR NEW.args_hash IS NOT OLD.args_hash OR NEW.spec_id IS NOT OLD.spec_id OR NEW.started_at IS NOT OLD.started_at OR (OLD.input_summary IS NOT NULL AND NEW.input_summary IS NOT OLD.input_summary) BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): agent_actions_log fingerprint columns are immutable (input_summary is set-once)'); END;"
  "DROP TRIGGER IF EXISTS agent_actions_log_final_row_frozen;"
  "CREATE TRIGGER agent_actions_log_final_row_frozen BEFORE UPDATE ON agent_actions_log WHEN OLD.status IS NOT 'pending' AND (NEW.status IS NOT OLD.status OR NEW.ended_at IS NOT OLD.ended_at OR NEW.result_hash IS NOT OLD.result_hash OR NEW.deny_reason IS NOT OLD.deny_reason) BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): agent_actions_log row is final — only the pending → final transition may set status/ended_at/result_hash'); END;"
  "DROP TRIGGER IF EXISTS decisions_no_delete;"
  "CREATE TRIGGER decisions_no_delete BEFORE DELETE ON decisions BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): DELETE on decisions is forbidden — set status (rejected/superseded) or record a test_artifact row in audit_events instead'); END;"
  "DROP TRIGGER IF EXISTS decisions_no_replace;"
  "CREATE TRIGGER decisions_no_replace BEFORE INSERT ON decisions WHEN NEW.id IS NOT NULL BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): decisions id already exists — rows are never replaced') WHERE EXISTS (SELECT 1 FROM decisions WHERE id = NEW.id); END;"
  "DROP TRIGGER IF EXISTS decisions_immutable_fields;"
  "CREATE TRIGGER decisions_immutable_fields BEFORE UPDATE ON decisions WHEN NEW.id IS NOT OLD.id OR NEW.agent IS NOT OLD.agent OR NEW.title IS NOT OLD.title OR NEW.category IS NOT OLD.category OR NEW.rationale IS NOT OLD.rationale OR NEW.created_at IS NOT OLD.created_at OR (OLD.approved_by IS NOT NULL AND NEW.approved_by IS NOT OLD.approved_by) OR (OLD.approved_at IS NOT NULL AND NEW.approved_at IS NOT OLD.approved_at) BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): decisions title/rationale/agent/category/created_at are immutable and approved_by/approved_at are set-once — record a note or status_change row in audit_events instead'); END;"
  "DROP TRIGGER IF EXISTS decisions_created_at_db_clock;"
  "CREATE TRIGGER decisions_created_at_db_clock BEFORE INSERT ON decisions BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): decisions.created_at must be the DB clock — omit it or use CURRENT_TIMESTAMP (tolerance 120s)') WHERE julianday(NEW.created_at) IS NULL OR abs(julianday(NEW.created_at) - julianday('now')) * 86400.0 > 120; END;"
  "DROP TRIGGER IF EXISTS audit_events_no_update;"
  "CREATE TRIGGER audit_events_no_update BEFORE UPDATE ON audit_events BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): audit_events is INSERT-only — append a new event instead'); END;"
  "DROP TRIGGER IF EXISTS audit_events_no_delete;"
  "CREATE TRIGGER audit_events_no_delete BEFORE DELETE ON audit_events BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): audit_events is INSERT-only — DELETE is forbidden'); END;"
  "DROP TRIGGER IF EXISTS audit_events_no_replace;"
  "CREATE TRIGGER audit_events_no_replace BEFORE INSERT ON audit_events WHEN NEW.id IS NOT NULL BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): audit_events id already exists — rows are never replaced') WHERE EXISTS (SELECT 1 FROM audit_events WHERE id = NEW.id); END;"
  "DROP TRIGGER IF EXISTS audit_events_created_at_db_clock;"
  "CREATE TRIGGER audit_events_created_at_db_clock BEFORE INSERT ON audit_events BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): audit_events.created_at must be the DB clock — omit it or use CURRENT_TIMESTAMP (tolerance 120s)') WHERE julianday(NEW.created_at) IS NULL OR abs(julianday(NEW.created_at) - julianday('now')) * 86400.0 > 120; END;"
  "DROP TRIGGER IF EXISTS audit_events_target_exists;"
  "CREATE TRIGGER audit_events_target_exists BEFORE INSERT ON audit_events BEGIN SELECT RAISE(ABORT, 'audit_events: target_id does not reference an existing row of target_table (R5c)') WHERE (NEW.target_table = 'security_audit_log' AND NOT EXISTS (SELECT 1 FROM security_audit_log WHERE id = NEW.target_id)) OR (NEW.target_table = 'agent_actions_log' AND NOT EXISTS (SELECT 1 FROM agent_actions_log WHERE id = NEW.target_id)) OR (NEW.target_table = 'decisions' AND NOT EXISTS (SELECT 1 FROM decisions WHERE id = NEW.target_id)); END;"
  "DROP TRIGGER IF EXISTS audit_events_shape;"
  "CREATE TRIGGER audit_events_shape BEFORE INSERT ON audit_events BEGIN SELECT RAISE(ABORT, 'audit_events: severity_change applies to security_audit_log only (R5c)') WHERE NEW.event_type = 'severity_change' AND NEW.target_table <> 'security_audit_log'; SELECT RAISE(ABORT, 'audit_events: status_change / severity_change / closure / timestamp_correction require to_value (R5c)') WHERE NEW.event_type IN ('status_change','severity_change','closure','timestamp_correction') AND (NEW.to_value IS NULL OR trim(NEW.to_value) = ''); SELECT RAISE(ABORT, 'audit_events: authority_ref does not reference an existing decisions row (R5c)') WHERE NEW.authority_ref IS NOT NULL AND NOT EXISTS (SELECT 1 FROM decisions WHERE id = NEW.authority_ref); SELECT RAISE(ABORT, 'audit_events: timestamp_correction to_value must be a parseable datetime (R5c)') WHERE NEW.event_type = 'timestamp_correction' AND julianday(NEW.to_value) IS NULL; SELECT RAISE(ABORT, 'audit_events: severity_change from_value must equal the current severity of the target row (R5c)') WHERE NEW.event_type = 'severity_change' AND NEW.from_value IS NOT COALESCE( (SELECT e.to_value FROM audit_events e WHERE e.target_table = 'security_audit_log' AND e.target_id = NEW.target_id AND e.event_type = 'severity_change' ORDER BY e.id DESC LIMIT 1), (SELECT s.severity FROM security_audit_log s WHERE s.id = NEW.target_id)); END;"
  "DROP TRIGGER IF EXISTS audit_events_cso_authority;"
  "CREATE TRIGGER audit_events_cso_authority BEFORE INSERT ON audit_events WHEN NEW.event_type IN ('severity_change','timestamp_correction','closure','test_artifact') OR (NEW.event_type = 'status_change' AND NEW.target_table = 'security_audit_log' AND lower(trim(NEW.to_value)) IN ('resolved','accepted','closed')) BEGIN SELECT RAISE(ABORT, 'audit immutability (decisions#308): this audit_events row requires authority_ref → a decisions row authored by the CSO (agent=cso) with a rationale — a CoS message alone is not sufficient') WHERE NEW.authority_ref IS NULL OR NOT EXISTS (SELECT 1 FROM decisions d WHERE d.id = NEW.authority_ref AND d.agent = 'cso' AND d.rationale IS NOT NULL AND trim(d.rationale) <> ''); END;"
  "DROP VIEW IF EXISTS security_audit_log_current;"
  "CREATE VIEW security_audit_log_current AS SELECT s.*, COALESCE((SELECT e.to_value FROM audit_events e WHERE e.target_table = 'security_audit_log' AND e.target_id = s.id AND e.event_type = 'severity_change' ORDER BY e.id DESC LIMIT 1), s.severity) AS current_severity, COALESCE((SELECT e.to_value FROM audit_events e WHERE e.target_table = 'security_audit_log' AND e.target_id = s.id AND e.event_type IN ('status_change','closure') ORDER BY e.id DESC LIMIT 1), s.status) AS current_status, COALESCE((SELECT e.to_value FROM audit_events e WHERE e.target_table = 'security_audit_log' AND e.target_id = s.id AND e.event_type = 'timestamp_correction' ORDER BY e.id DESC LIMIT 1), s.created_at) AS current_created_at, COALESCE((SELECT e.created_at FROM audit_events e WHERE e.target_table = 'security_audit_log' AND e.target_id = s.id AND e.event_type = 'closure' ORDER BY e.id DESC LIMIT 1), s.resolved_at) AS current_resolved_at, EXISTS (SELECT 1 FROM audit_events e WHERE e.target_table = 'security_audit_log' AND e.target_id = s.id AND e.event_type = 'test_artifact') AS is_test_artifact, (SELECT count(*) FROM audit_events e WHERE e.target_table = 'security_audit_log' AND e.target_id = s.id) AS event_count FROM security_audit_log s;"
  "DROP VIEW IF EXISTS decisions_current;"
  "CREATE VIEW decisions_current AS SELECT d.*, COALESCE((SELECT e.to_value FROM audit_events e WHERE e.target_table = 'decisions' AND e.target_id = d.id AND e.event_type IN ('status_change','closure') ORDER BY e.id DESC LIMIT 1), d.status) AS current_status, COALESCE((SELECT e.to_value FROM audit_events e WHERE e.target_table = 'decisions' AND e.target_id = d.id AND e.event_type = 'timestamp_correction' ORDER BY e.id DESC LIMIT 1), d.created_at) AS current_created_at, EXISTS (SELECT 1 FROM audit_events e WHERE e.target_table = 'decisions' AND e.target_id = d.id AND e.event_type = 'test_artifact') AS is_test_artifact, (SELECT count(*) FROM audit_events e WHERE e.target_table = 'decisions' AND e.target_id = d.id) AS event_count FROM decisions d;"
  "DROP VIEW IF EXISTS security_audit_verdict_severity_violations;"
  "CREATE VIEW security_audit_verdict_severity_violations AS SELECT v.id AS verdict_id, v.session_id, v.current_severity AS verdict_severity, f.id AS finding_id, f.current_severity AS finding_severity, 'finding more severe than verdict' AS violation FROM security_audit_log_current v JOIN security_audit_log_current f ON f.session_id = v.session_id AND f.auditor = v.auditor AND f.id <> v.id AND f.category IS NOT 'audit-verdict' AND f.is_test_artifact = 0 WHERE v.category = 'audit-verdict' AND v.is_test_artifact = 0 AND v.id = (SELECT max(x.id) FROM security_audit_log x WHERE x.category = 'audit-verdict' AND x.session_id = v.session_id AND x.auditor = v.auditor) AND CASE lower(trim(f.current_severity)) WHEN 'p0' THEN 4 WHEN 'critical' THEN 4 WHEN 'p1' THEN 3 WHEN 'high' THEN 3 WHEN 'p2' THEN 2 WHEN 'medium' THEN 2 WHEN 'low' THEN 1 WHEN 'info' THEN 0 END > COALESCE(CASE lower(trim(v.current_severity)) WHEN 'p0' THEN 4 WHEN 'critical' THEN 4 WHEN 'p1' THEN 3 WHEN 'high' THEN 3 WHEN 'p2' THEN 2 WHEN 'medium' THEN 2 WHEN 'low' THEN 1 WHEN 'info' THEN 0 END, -1) UNION ALL SELECT v.id, NULL, v.current_severity, NULL, NULL, 'verdict without session_id (unlinkable)' FROM security_audit_log_current v WHERE v.category = 'audit-verdict' AND v.session_id IS NULL AND v.is_test_artifact = 0;"
)

# Patches that apply to ALL DBs (company + project)
COMMON_PATCHES=(
  "ALTER TABLE disclosure_policies ADD COLUMN status          TEXT DEFAULT 'draft';"
  "ALTER TABLE disclosure_policies ADD COLUMN validated_by    TEXT;"
  "ALTER TABLE disclosure_policies ADD COLUMN validated_at    DATETIME;"
  "ALTER TABLE disclosure_policies ADD COLUMN retired_at      DATETIME;"
  "ALTER TABLE disclosure_policies ADD COLUMN ceo_approved_at DATETIME;"
  "ALTER TABLE decisions ADD COLUMN source_ref               TEXT;"
  "ALTER TABLE agent_actions_log ADD COLUMN input_summary    TEXT;"
  "ALTER TABLE agent_actions_log ADD COLUMN spec_id          INTEGER;"
  "CREATE TRIGGER IF NOT EXISTS action_log_denied_requires_summary BEFORE INSERT ON agent_actions_log WHEN NEW.status = 'denied' BEGIN SELECT RAISE(ABORT,'agent_actions_log denied rows require input_summary — set it in pre-tool-use.sh') WHERE NEW.input_summary IS NULL OR trim(NEW.input_summary) = ''; END;"
  "DROP TRIGGER IF EXISTS decisions_category_check_ins;"
  "CREATE TRIGGER decisions_category_check_ins BEFORE INSERT ON decisions WHEN NEW.category IS NOT NULL BEGIN SELECT RAISE(ABORT,'decisions.category value not in canonical list — see JUVANT_OS.md schema reference') WHERE NEW.category NOT IN ('model-override','tool-matrix-change','pr-spec','gh-issue-spec','gh-project-update-spec','gh-milestone-spec','install-spec','branch-protection-spec','release-spec','deployment-spec','secret-rotation-spec','eng-output-held','disclosure-unavailable','bootstrap-action','cascade-escalation','cascade-postmortem','skill-gap','migration-watch','upstream-sync-proposal','eng-platform-spec','arch-decision','operational-violation','kb-orphan-review','legal','product','business','system-audit','incident-response','security-remediation','accessibility-audit','aggregate-health-flag','analyst-briefing','backlog-transition','bank-unavailable','binding-confirmation','brand-advisory','brand-mode-ratification-routed','brand-spec','competitor-move','content-performance','content-published','cross-project-dependency','cross-project-release-coordination','cross-project-tech-debt','cso-audit-request','data-deletion-proposal','demo-conducted','deployment','design-debt','design-system-drift','direct-session','disclosure-audit','drift-audit','drift-finding','eng-finding','eng-work-completed','ethical-concern','ethical-opinion','ethical-validation','eval-run','gh-pr-review-spec','kb-promotion-candidate','knowledge-base-retraction','manifesto','mcp-install-confirmed','monthly-ranking','offboarding','offboarding-action','pipeline-outcome','pipeline-stage','prd-published','prd-retro','press-interaction','proposal-sent','release-published','research-output','research-published','roadmap-transition','spec-paused-cascade','spec-rejected','tech-exception','tech-standard','ux-research-published','versioning','weekly-engineering-report'); END;"
  "DROP TRIGGER IF EXISTS decisions_category_check_upd;"
  "CREATE TRIGGER decisions_category_check_upd BEFORE UPDATE ON decisions WHEN NEW.category IS NOT NULL AND NEW.category != OLD.category BEGIN SELECT RAISE(ABORT,'decisions.category value not in canonical list — see JUVANT_OS.md schema reference') WHERE NEW.category NOT IN ('model-override','tool-matrix-change','pr-spec','gh-issue-spec','gh-project-update-spec','gh-milestone-spec','install-spec','branch-protection-spec','release-spec','deployment-spec','secret-rotation-spec','eng-output-held','disclosure-unavailable','bootstrap-action','cascade-escalation','cascade-postmortem','skill-gap','migration-watch','upstream-sync-proposal','eng-platform-spec','arch-decision','operational-violation','kb-orphan-review','legal','product','business','system-audit','incident-response','security-remediation','accessibility-audit','aggregate-health-flag','analyst-briefing','backlog-transition','bank-unavailable','binding-confirmation','brand-advisory','brand-mode-ratification-routed','brand-spec','competitor-move','content-performance','content-published','cross-project-dependency','cross-project-release-coordination','cross-project-tech-debt','cso-audit-request','data-deletion-proposal','demo-conducted','deployment','design-debt','design-system-drift','direct-session','disclosure-audit','drift-audit','drift-finding','eng-finding','eng-work-completed','ethical-concern','ethical-opinion','ethical-validation','eval-run','gh-pr-review-spec','kb-promotion-candidate','knowledge-base-retraction','manifesto','mcp-install-confirmed','monthly-ranking','offboarding','offboarding-action','pipeline-outcome','pipeline-stage','prd-published','prd-retro','press-interaction','proposal-sent','release-published','research-output','research-published','roadmap-transition','spec-paused-cascade','spec-rejected','tech-exception','tech-standard','ux-research-published','versioning','weekly-engineering-report'); END;"
  "CREATE TRIGGER IF NOT EXISTS decisions_approved_requires_approver_ins BEFORE INSERT ON decisions WHEN NEW.status = 'approved' BEGIN SELECT RAISE(ABORT,'decisions status=approved requires approved_by and approved_at') WHERE NEW.approved_by IS NULL OR NEW.approved_at IS NULL; END;"
  "CREATE TRIGGER IF NOT EXISTS decisions_approved_requires_approver_upd BEFORE UPDATE ON decisions WHEN NEW.status = 'approved' AND OLD.status != 'approved' BEGIN SELECT RAISE(ABORT,'decisions status=approved requires approved_by and approved_at') WHERE NEW.approved_by IS NULL OR NEW.approved_at IS NULL; END;"
  "CREATE TRIGGER IF NOT EXISTS decisions_executed_requires_executor_ins BEFORE INSERT ON decisions WHEN NEW.status = 'executed' AND NEW.category IN ('pr-spec','gh-issue-spec','deployment-spec','install-spec','eng-platform-spec','branch-protection-spec','release-spec','secret-rotation-spec') BEGIN SELECT RAISE(ABORT,'decisions status=executed requires executed_by, executed_at, and source_ref for spec categories') WHERE NEW.executed_by IS NULL OR NEW.executed_at IS NULL OR NEW.source_ref IS NULL; END;"
  "CREATE TRIGGER IF NOT EXISTS decisions_executed_requires_executor_upd BEFORE UPDATE ON decisions WHEN NEW.status = 'executed' AND OLD.status != 'executed' AND NEW.category IN ('pr-spec','gh-issue-spec','deployment-spec','install-spec','eng-platform-spec','branch-protection-spec','release-spec','secret-rotation-spec') BEGIN SELECT RAISE(ABORT,'decisions status=executed requires executed_by, executed_at, and source_ref for spec categories') WHERE NEW.executed_by IS NULL OR NEW.executed_at IS NULL OR NEW.source_ref IS NULL; END;"
)
# Patches that apply to the COMPANY DB only (not project DBs)
COMPANY_PATCHES=(
  "ALTER TABLE projects ADD COLUMN maturity_status            TEXT DEFAULT 'incubation';"
  "ALTER TABLE decisions ADD COLUMN scope                     TEXT DEFAULT 'company';"
  "ALTER TABLE decisions ADD COLUMN upstream_candidate        INTEGER DEFAULT 0;"
  "CREATE TRIGGER IF NOT EXISTS enforce_global_scope_master_only BEFORE INSERT ON decisions WHEN NEW.scope = 'global' BEGIN SELECT RAISE(ABORT, 'scope=global requires company_type=master in master_context') WHERE (SELECT value FROM master_context WHERE key='company_type') != 'master'; END;"
  "CREATE TRIGGER IF NOT EXISTS enforce_global_scope_master_only_upd BEFORE UPDATE ON decisions WHEN NEW.scope = 'global' AND OLD.scope != 'global' BEGIN SELECT RAISE(ABORT, 'scope=global requires company_type=master in master_context') WHERE (SELECT value FROM master_context WHERE key='company_type') != 'master'; END;"
  "ALTER TABLE knowledge_base ADD COLUMN scope TEXT DEFAULT 'company';"
  "CREATE TRIGGER IF NOT EXISTS enforce_global_kb_scope_master_only BEFORE INSERT ON knowledge_base WHEN NEW.scope = 'global' BEGIN SELECT RAISE(ABORT, 'scope=global requires company_type=master in master_context') WHERE (SELECT value FROM master_context WHERE key='company_type') != 'master'; END;"
  "CREATE TRIGGER IF NOT EXISTS enforce_global_kb_scope_master_only_upd BEFORE UPDATE ON knowledge_base WHEN NEW.scope = 'global' AND OLD.scope != 'global' BEGIN SELECT RAISE(ABORT, 'scope=global requires company_type=master in master_context') WHERE (SELECT value FROM master_context WHERE key='company_type') != 'master'; END;"
)

# _patch_list <project_slug> — every patch for this DB, in apply order.
_patch_list() {
  printf '%s\n' "${COMMON_PATCHES[@]}" "${R5_AUDIT_PATCHES[@]}"
  [[ -n "${1:-}" ]] || printf '%s\n' "${COMPANY_PATCHES[@]}"
}

# Pre-schema pass: only the ADD COLUMN patches.
apply_column_prepatches() {
  local sql
  while IFS= read -r sql; do
    [[ "$sql" == "ALTER TABLE "*" ADD COLUMN "* ]] && _run_patch "$sql" 1
  done < <(_patch_list "${1:-}")
  return 0
}

apply_schema_patches() {
  local sql
  while IFS= read -r sql; do _run_patch "$sql"; done < <(_patch_list "${1:-}")
  if [[ "$MIGRATE_PATCH_WARNINGS" -gt 0 ]]; then
    printf 'WARN [migrate]: %d non-benign schema patch(es) failed (see above) — schema may be inconsistent (e.g. a trigger created without its prerequisite column). Inspect before use. (BUG-040)\n' "$MIGRATE_PATCH_WARNINGS" >&2
  fi
}

# verify_schema <project_slug> — read back every table, trigger and view that
# schema.sql + the patches create and every column the ADD COLUMN patches add.
# Fails (non-zero) on anything missing: a CLI that exited 0 without applying
# (expired turso auth) must not end in "Schema applied successfully".
verify_schema() {
  local expected=() actual sql missing=() e re_obj re_col
  re_obj='^CREATE (TABLE|TRIGGER|VIEW) (IF NOT EXISTS )?([A-Za-z0-9_]+)'
  re_col='^ALTER TABLE ([A-Za-z0-9_]+) ADD COLUMN +([A-Za-z0-9_]+)'
  while IFS= read -r sql; do
    if [[ "$sql" =~ $re_obj ]]; then
      expected+=("$(tr '[:upper:]' '[:lower:]' <<<"${BASH_REMATCH[1]}"):${BASH_REMATCH[3]}")
    fi
  done < <(grep -E '^CREATE (TABLE|TRIGGER|VIEW) IF NOT EXISTS ' "$SCHEMA")
  while IFS= read -r sql; do
    if [[ "$sql" =~ $re_obj ]]; then
      expected+=("$(tr '[:upper:]' '[:lower:]' <<<"${BASH_REMATCH[1]}"):${BASH_REMATCH[3]}")
    elif [[ "$sql" =~ $re_col ]]; then
      expected+=("column:${BASH_REMATCH[1]}.${BASH_REMATCH[2]}")
    fi
  done < <(_patch_list "${1:-}")
  actual=$(_patch_sql "SELECT type || ':' || name FROM sqlite_master WHERE type IN ('table','trigger','view') UNION ALL SELECT 'column:' || m.name || '.' || p.name FROM sqlite_master m, pragma_table_info(m.name) p WHERE m.type = 'table';" 2>&1 | tr -d ' \r\t') || true
  for e in "${expected[@]}"; do
    grep -qxF -- "$e" <<<"$actual" || missing+=("$e")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'ERROR [migrate]: schema verification failed — %d of %d expected objects are missing after the apply:\n' "${#missing[@]}" "${#expected[@]}" >&2
    printf '  %s\n' "${missing[@]:0:15}" >&2
    [[ ${#missing[@]} -gt 15 ]] && printf '  … and %d more\n' $(( ${#missing[@]} - 15 )) >&2
    if [[ "$PATCH_PROVIDER" != "local" ]]; then
      echo "  The turso CLI can exit 0 without applying anything — check 'turso auth whoami' (re-login with 'turso auth login') and re-run." >&2
    fi
    return 1
  fi
  echo "Verified: ${#expected[@]} tables, triggers, views and patched columns present."
}

# ─────────────────────────────────────────────
# Mode 2: v0.7 → v0.8 version-pair migration
# ─────────────────────────────────────────────

# Old → new identifier table (ADR 0014 §1/§2). The migration writes these
# pairs into the role_aliases table, then applies the rename to active
# state. Historical rows in manifests/decisions/agent_actions_log/
# inbound_queue/security_audit_log are NOT modified — joins go through
# role_aliases at audit time.
#
# Format: old_role:new_role:scope-context (documentation only — the actual
# inserts are inline in the SQL heredoc below; this list is the human
# reference for what the migration does).
#   ca   → cto          (company)
#   cto  → pca          (project)
#   coo  → eng-lead     (project)
#   cdo  → design-lead  (project)
#   cpo  → product-lead (project)
#   vpe  → vpe          (cross-scope: project → company-optional)

# Old → new file basename (no scope qualifier in the filename so the move
# pattern is direct). Parallel arrays — bash 3.2 (macOS default) lacks
# associative arrays.
FILE_RENAMES_OLD=(
  "agents/company/ca.md"
  "agents/projects/cto.md"
  "agents/projects/coo.md"
  "agents/projects/cdo.md"
  "agents/projects/cpo.md"
  "agents/projects/vpe.md"
)
FILE_RENAMES_NEW=(
  "agents/company/cto.md"
  "agents/projects/pca.md"
  "agents/projects/eng-lead.md"
  "agents/projects/design-lead.md"
  "agents/projects/product-lead.md"
  "agents/company/vpe.md"
)

dry() { [[ "$DRY_RUN" == "1" ]] && echo "[dry-run]" || echo "[apply]"; }

log_step() {
  printf "\n%s %s\n" "$(dry)" "$1"
  printf '%.0s─' $(seq 1 ${#1}); echo ""
}

run_version_pair_migration() {
  log_step "v0.7 → v0.8 migration (ADR 0014 §7)"

  # ────────────────────
  # Pre-flight
  # ────────────────────
  log_step "Pre-flight checks"

  if [[ ! -f "$CONFIG" ]]; then
    echo "FAIL: $CONFIG missing. Migration requires a bootstrapped fork."
    exit 1
  fi
  echo "  config: present at $CONFIG"

  # Resolve DB. Reuse hooks/lib/db.sh helpers for path resolution.
  local DB_PATH=""
  if [[ -f "$ROOT/hooks/lib/db.sh" ]]; then
    # shellcheck disable=SC1091
    . "$ROOT/hooks/lib/db.sh"
    juvant_db_resolve 2>/dev/null || true
    DB_PATH="${JUVANT_DB_PATH:-}"
  fi
  if [[ -z "$DB_PATH" || ! -f "$DB_PATH" ]]; then
    # Fall back: read .db.url directly for local provider.
    local provider db_url
    provider=$(jq -r '.db.provider // ""' "$CONFIG")
    db_url=$(jq -r '.db.url // ""' "$CONFIG")
    db_url="${db_url#file:}"
    if [[ "$provider" == "local" && -f "$db_url" ]]; then
      DB_PATH="$db_url"
    elif [[ "$provider" == "local" && -f "$ROOT/$db_url" ]]; then
      DB_PATH="$ROOT/$db_url"
    fi
  fi
  if [[ -z "$DB_PATH" ]]; then
    echo "FAIL: state.db not resolvable. Migration requires a local-provider fork; cloud-provider migration ships separately."
    exit 1
  fi
  echo "  state.db: $DB_PATH"

  if ! command -v sqlite3 &>/dev/null; then
    echo "FAIL: sqlite3 required for migration."
    exit 1
  fi

  local bootstrap_completed
  bootstrap_completed=$(sqlite3 "$DB_PATH" \
    "SELECT value FROM master_context WHERE key='bootstrap_completed_at';" 2>/dev/null || echo "")
  if [[ -z "$bootstrap_completed" ]]; then
    echo "FAIL: bootstrap_completed_at not set in master_context. Only post-bootstrap forks need migration."
    echo "      New v0.8.0 forks start clean (no migration needed)."
    exit 1
  fi
  echo "  bootstrap_completed_at: $bootstrap_completed"

  # Idempotency: refuse if already migrated.
  # NOTE: the `agent_tool_matrix` table is scope-less by design (see the
  # comment at "Update active state: agent_tool_matrix" further down, and
  # schema.sql lines 199-221). Per F-24 each scope has its own DB, so a
  # `WHERE role='cto'` query against the company DB unambiguously matches
  # the company-scope row (and only that row). Earlier versions of this
  # check included an erroneous `AND scope='company'` predicate that
  # silently failed (no such column) → grep -q -1 → idempotency check
  # always falsy → migration would happily re-run on an already-migrated
  # DB. Dropping the predicate restores the intended idempotency.
  if sqlite3 "$DB_PATH" "SELECT 1 FROM agent_tool_matrix WHERE role='cto' AND superseded_by IS NULL;" 2>/dev/null | grep -q 1; then
    if ! sqlite3 "$DB_PATH" "SELECT 1 FROM agent_tool_matrix WHERE role='ca' AND superseded_by IS NULL;" 2>/dev/null | grep -q 1; then
      echo "FAIL: state appears already migrated to v0.8 (active 'cto' company-scope row, no active 'ca'). Refusing to re-run."
      exit 3
    fi
  fi
  echo "  v0.7 baseline: confirmed (active 'ca' row present in agent_tool_matrix)"

  # ────────────────────
  # Backup
  # ────────────────────
  log_step "Backup state.db"
  local BACKUP_PATH BACKUP_TS
  BACKUP_TS=$(date -u +%Y%m%dT%H%M%SZ)
  BACKUP_PATH="${DB_PATH}.pre-v0.8.${BACKUP_TS}"
  if [[ "$DRY_RUN" == "0" ]]; then
    cp "$DB_PATH" "$BACKUP_PATH"
    echo "  backup: $BACKUP_PATH"
  else
    echo "  would copy: $DB_PATH → $BACKUP_PATH"
  fi

  # ────────────────────
  # File renames
  # ────────────────────
  log_step "Rename agent files via git mv (preserves compiled content + history)"
  local i
  for i in "${!FILE_RENAMES_OLD[@]}"; do
    local old_path="${FILE_RENAMES_OLD[$i]}"
    local new_path="${FILE_RENAMES_NEW[$i]}"
    if [[ -f "$ROOT/$old_path" ]]; then
      if [[ -f "$ROOT/$new_path" ]]; then
        echo "  WARN: both $old_path and $new_path exist — partial migration? Skipping rename."
        continue
      fi
      if [[ "$DRY_RUN" == "0" ]]; then
        (cd "$ROOT" && git mv "$old_path" "$new_path") || mv "$ROOT/$old_path" "$ROOT/$new_path"
      fi
      echo "  $old_path → $new_path"
    elif [[ -f "$ROOT/$new_path" ]]; then
      echo "  skip (already migrated): $new_path"
    else
      echo "  skip (not present): $old_path"
    fi
  done

  # ────────────────────
  # Schema additions: role_aliases table
  # ────────────────────
  log_step "Create role_aliases table + populate v0.8 aliases"
  local sql_role_aliases
  sql_role_aliases=$(cat <<SQL
CREATE TABLE IF NOT EXISTS role_aliases (
  old_role TEXT NOT NULL,
  new_role TEXT NOT NULL,
  scope TEXT,
  introduced_in_version TEXT,
  notes TEXT,
  PRIMARY KEY (old_role, new_role, scope)
);
INSERT OR IGNORE INTO role_aliases (old_role, new_role, scope, introduced_in_version, notes) VALUES
  ('ca',  'cto',          'company',     'v0.8.0', 'Chief Architect renamed Chief Technology Officer per ADR 0014 §1.'),
  ('cto', 'pca',          'project',     'v0.8.0', 'Project-CTO renamed PCA (Project Chief Architect) per ADR 0014 §1.'),
  ('coo', 'eng-lead',     'project',     'v0.8.0', 'Project-COO renamed Engineering Lead per ADR 0014 §1; absorbs project-VPE function per §2.'),
  ('cdo', 'design-lead',  'project',     'v0.8.0', 'CDO renamed Design Lead per ADR 0014 §1.'),
  ('cpo', 'product-lead', 'project',     'v0.8.0', 'CPO renamed Product Lead per ADR 0014 §1.'),
  ('vpe', 'vpe',          'cross-scope', 'v0.8.0', 'VPE moved project→company-optional per ADR 0014 §2; identifier unchanged.');
SQL
)
  if [[ "$DRY_RUN" == "0" ]]; then
    echo "$sql_role_aliases" | sqlite3 "$DB_PATH"
    echo "  role_aliases: 6 rows inserted"
  else
    echo "  would create role_aliases table + insert 6 rows"
  fi

  # ────────────────────
  # Update active state: agents.role column
  # ────────────────────
  log_step "Update active agents.role rows to new identifiers (active manifestos only)"
  local sql_agents
  # NOTE (two fixes, BUG-from-main-review):
  #   1. The column is `role`, not `agent` (schema.sql: agents.role TEXT
  #      UNIQUE NOT NULL). The pre-fix statements referenced a nonexistent
  #      `agent` column and aborted the whole migration after the irreversible
  #      file renames had already run.
  #   2. `role` is GLOBALLY UNIQUE, so the project-scope CTO must be renamed to
  #      `pca` BEFORE the company-scope CA takes the `cto` name — otherwise
  #      `ca`→`cto` collides with the still-present project `cto`. Order matters.
  # The delimiter is QUOTED (<<'SQL') so the body is fully literal — no
  # parameter/command expansion, and (critically) an apostrophe in a comment
  # cannot leave an unbalanced single quote that derails the bash
  # command-substitution parser inside $(cat <<...). The body needs no shell
  # expansion; keep it that way.
  sql_agents=$(cat <<'SQL'
UPDATE agents SET role='pca'          WHERE role='cto' AND scope != 'company';
UPDATE agents SET role='cto'          WHERE role='ca';
UPDATE agents SET role='eng-lead'     WHERE role='coo';
UPDATE agents SET role='design-lead'  WHERE role='cdo';
UPDATE agents SET role='product-lead' WHERE role='cpo';
-- Project-VPE: row absorbed by eng-lead; if a project-vpe row still exists
-- with status='active', mark it offboarded (ADR 0014 section 2 absorption).
-- Left for the audit trail; downstream loaders ignore status='offboarded'.
-- (No offboarded_at/offboarded_reason columns exist; the offboard reason is
-- recorded in this migration log + the remediation summary.)
UPDATE agents SET status='offboarded'
  WHERE role='vpe' AND scope != 'company' AND status != 'offboarded';
SQL
)
  if [[ "$DRY_RUN" == "0" ]]; then
    echo "$sql_agents" | sqlite3 "$DB_PATH"
    echo "  agents: active rows updated; project-vpe marked offboarded"
  else
    echo "  would run agents UPDATE statements"
  fi

  # ────────────────────
  # Update active state: agent_tool_matrix
  # ────────────────────
  log_step "Supersede old agent_tool_matrix rows; insert new from template"
  # The agent_tool_matrix table is scope-less in the schema (per schema.sql:
  # "One DB per scope: company-<name>, project-<name>"). Each scope's DB
  # holds only its own rows. This migration runs against the company DB
  # by default; project DBs need a separate `--from=v0.7 --to=v0.8
  # --project=<slug>` invocation (out-of-scope for v0.8.0; documented as
  # follow-up in the remediation summary).
  local matrix_template="$ROOT/scripts/templates/v0-agent-tool-matrix.json"
  if [[ ! -f "$matrix_template" ]]; then
    echo "  WARN: $matrix_template missing; skipping matrix update. Adopter must apply manually."
  else
    if [[ "$DRY_RUN" == "0" ]]; then
      # Supersede legacy company-scope rows. The 'ca' row is unambiguous
      # (only existed at company scope). The 'vpe' row is also handled here
      # since v0.8 promotes vpe to company-scope; legacy project-vpe lives
      # in project DBs and needs the per-project migration to handle it.
      sqlite3 "$DB_PATH" <<SQL
UPDATE agent_tool_matrix
   SET superseded_by=-1
 WHERE role IN ('ca')
   AND superseded_by IS NULL;
SQL
      echo "  superseded: company-scope 'ca' row marked superseded_by=-1"
      # Insert new company-scope rows from template (only company-scope
      # entries — project rows belong in project DBs which this run does
      # not touch).
      python3 - "$matrix_template" "$DB_PATH" <<'PYEOF'
import json, sqlite3, sys
template_path, db_path = sys.argv[1], sys.argv[2]
with open(template_path) as f:
    template = json.load(f)
conn = sqlite3.connect(db_path)
cur = conn.cursor()
inserted = 0
for row in template["rows"]:
    if row.get("scope") != "company":
        continue  # project rows live in project DBs; out of scope here
    role = row["role"]
    cur.execute(
        "SELECT 1 FROM agent_tool_matrix WHERE role=? AND superseded_by IS NULL LIMIT 1",
        (role,),
    )
    if cur.fetchone():
        continue
    cur.execute(
        """INSERT INTO agent_tool_matrix
                  (role, mcp_servers, skills, channels, approved_by, version, superseded_by, created_at)
           VALUES (?, ?, ?, ?, 'ceo', 'v0.8.0', NULL, datetime('now'))""",
        (
            role,
            json.dumps(row.get("mcp_servers", [])),
            json.dumps(row.get("skills", [])),
            json.dumps(row.get("channels", [])),
        ),
    )
    inserted += 1
conn.commit()
print(f"  agent_tool_matrix: {inserted} new company-scope active rows inserted from v0.8 template")
PYEOF
    else
      echo "  would supersede legacy 'ca' company row + insert new company-scope rows (project rows out of scope for company-DB run)"
    fi
  fi

  # ────────────────────
  # Update .juvant/config.json keys
  # ────────────────────
  log_step "Migrate .juvant/config.json agent_names keys"
  if [[ "$DRY_RUN" == "0" ]]; then
    local tmp_cfg="${CONFIG}.v0.8-migration.tmp"
    jq '
      # Company-scope: agent_names.ca → agent_names.cto.
      if .agent_names.ca and (.agent_names.cto | not)
      then .agent_names.cto = .agent_names.ca
      else . end
      | del(.agent_names.ca)
      # Per-project agent_names: rename keys; remove vpe entirely.
      | if .projects then
          .projects = (
            .projects | with_entries(
              .value.agent_names = (
                (.value.agent_names // {})
                | (if .cto then .pca = .cto else . end)
                | (if .cpo then ."product-lead" = .cpo else . end)
                | (if .cdo then ."design-lead" = .cdo else . end)
                | (if .coo then ."eng-lead" = .coo else . end)
                | del(.cto, .cpo, .cdo, .coo, .vpe)
              )
            )
          )
        else . end
      # Default feature_toggles for v0.8.0 if not set (preserves any
      # adopter-set overrides).
      | .feature_toggles = (
          (.feature_toggles // {})
          | (.eng_platform_enabled //= true)
          | (.cro_enabled          //= false)
          | (.vpe_enabled          //= false)
        )
    ' "$CONFIG" > "$tmp_cfg"
    mv "$tmp_cfg" "$CONFIG"
    echo "  $CONFIG: agent_names keys migrated; feature_toggles defaults set"
  else
    echo "  would migrate $CONFIG: ca→cto company; cto/cpo/cdo/coo→pca/product-lead/design-lead/eng-lead per project; project-vpe removed; feature_toggles defaults set"
  fi

  # ────────────────────
  # Update hooks/bash-policy.json keys
  # ────────────────────
  log_step "Migrate hooks/bash-policy.json agent_allow keys"
  local policy_file="$ROOT/hooks/bash-policy.json"
  if [[ -f "$policy_file" ]]; then
    if [[ "$DRY_RUN" == "0" ]]; then
      local tmp_policy="${policy_file}.v0.8-migration.tmp"
      jq '
        .agent_allow = (
          .agent_allow
          | (if .ca  then .cto = .ca  else . end)
          | (if .coo then ."eng-lead" = .coo else . end)
          | (if .cdo then ."design-lead" = .cdo else . end)
          | (if .cpo then ."product-lead" = .cpo else . end)
          # Project-CTO collision with company-CTO in flat namespace:
          # the v0.7 cto key was project-scope; rename to pca only if
          # company-scope cto already came from ca above (avoiding overwrite).
          | (if (.cto and (.pca | not)) and (.cto != ."ca-original-tool-set")
             then .pca = .cto else . end)
          # Now drop legacy keys.
          | del(.ca, .coo, .cdo, .cpo)
        )
      ' "$policy_file" > "$tmp_policy"
      mv "$tmp_policy" "$policy_file"
      echo "  $policy_file: keys migrated"
    else
      echo "  would migrate $policy_file: ca→cto, coo→eng-lead, cdo→design-lead, cpo→product-lead, project-cto→pca"
    fi
  else
    echo "  skip (not present): $policy_file"
  fi

  # ────────────────────
  # Summary + adopter remediation
  # ────────────────────
  log_step "Migration complete — adopter remediation steps"
  cat <<EOF
  Migration to v0.8.0 baseline applied. State summary:
    - role_aliases table: 6 rows (audit-time joins for historical data)
    - agents: active rows renamed to v0.8 identifiers (project-vpe offboarded)
    - agent_tool_matrix: legacy rows superseded; v0.8 rows inserted active
    - .juvant/config.json: agent_names keys migrated; feature_toggles default-set
    - hooks/bash-policy.json: agent_allow keys migrated

  REMEDIATION REQUIRED (run manually after this script):

  1. Pull v0.8.0 framework upstream to get the renamed file templates:
       git fetch origin && git merge origin/main
     (or: git pull origin v0.8.0)
     Conflicts on agents/*.md content are expected — your compiled
     per-company body merges with upstream's peer-reference updates.

  2. Re-run compile-templates.sh to apply v0.8 placeholder substitutions
     (PCA_NAME, PRODUCT_LEAD_NAME, DESIGN_LEAD_NAME, ENG_LEAD_NAME)
     into the renamed agent files:
       bash scripts/compile-templates.sh --scope company
       bash scripts/compile-templates.sh --scope projects --project=<your-active-project-slug>

  3. Run the bootstrap-baseline audit to confirm v0.8 expected-roles
     coherence (toggle-aware count, file-vs-matrix coherence):
       bash scripts/audit-bootstrap-baseline.sh --scope=company
       bash scripts/audit-bootstrap-baseline.sh --scope=<your-active-project-slug>

  4. If feature_toggles.vpe_enabled was previously OFF and you want the
     cross-project VPE aggregator (only sensible for ≥2 active projects):
     edit .juvant/config.json, set feature_toggles.vpe_enabled=true, then
     run the JUVANT_OS.md wizard's manifesto Tier 1 flow for the new
     company-scope vpe agent (CHRO + CTO joint approval + CSO precondition).

  Bootstrap is NOT re-run. Existing manifestos remain valid; the role
  identifier in their body is metadata, the structural commitments
  carry forward.

  Backup of pre-migration state.db: $BACKUP_PATH

EOF
}

# ─────────────────────────────────────────────
# Drive
# ─────────────────────────────────────────────

case "$MODE" in
  schema-apply)    run_schema_apply ;;
  version-pair)    run_version_pair_migration ;;
  *)               echo "ERROR: unknown mode '$MODE'" >&2; exit 1 ;;
esac
