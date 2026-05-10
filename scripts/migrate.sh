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
      PROVIDER=$(jq -r --arg s "$PROJECT_SLUG" '.projects[$s].db.provider // ""' "$CONFIG")
      DB_URL=$(jq -r --arg s "$PROJECT_SLUG" '.projects[$s].db.url // ""' "$CONFIG")
      DB_TOKEN=$(jq -r --arg s "$PROJECT_SLUG" '.projects[$s].db.auth_token // ""' "$CONFIG")
    else
      PROVIDER=$(jq -r '.db.provider // ""' "$CONFIG")
      DB_URL=$(jq -r '.db.url // ""' "$CONFIG")
      DB_TOKEN=$(jq -r '.db.auth_token // ""' "$CONFIG")
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
# Format: old_role:new_role:scope-context
RENAME_PAIRS=(
  "ca:cto:company"
  "cto:pca:project"
  "coo:eng-lead:project"
  "cdo:design-lead:project"
  "cpo:product-lead:project"
  "vpe:vpe:cross-scope"   # SAME identifier, scope changed project→company-optional
)

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
  if sqlite3 "$DB_PATH" "SELECT 1 FROM agent_tool_matrix WHERE role='cto' AND scope='company' AND superseded_by IS NULL;" 2>/dev/null | grep -q 1; then
    if ! sqlite3 "$DB_PATH" "SELECT 1 FROM agent_tool_matrix WHERE role='ca' AND scope='company' AND superseded_by IS NULL;" 2>/dev/null | grep -q 1; then
      echo "FAIL: state appears already migrated to v0.8 (active 'cto' company-scope row, no active 'ca'). Refusing to re-run."
      exit 3
    fi
  fi
  echo "  v0.7 baseline: confirmed (active 'ca' company-scope row present in agent_tool_matrix)"

  # ────────────────────
  # Backup
  # ────────────────────
  log_step "Backup state.db"
  local BACKUP_PATH="${DB_PATH}.pre-v0.8.$(date -u +%Y%m%dT%H%M%SZ)"
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
  # Update active state: agents.agent column
  # ────────────────────
  log_step "Update active agents.agent rows to new identifiers (active manifestos only)"
  local sql_agents
  sql_agents=$(cat <<SQL
UPDATE agents SET agent='cto'          WHERE agent='ca';
UPDATE agents SET agent='pca'          WHERE agent='cto' AND scope != 'company';
UPDATE agents SET agent='eng-lead'     WHERE agent='coo';
UPDATE agents SET agent='design-lead'  WHERE agent='cdo';
UPDATE agents SET agent='product-lead' WHERE agent='cpo';
-- Project-VPE: row absorbed by eng-lead; if a project-vpe row still
-- exists with status='active', mark it offboarded (ADR 0014 §2 absorption).
-- Leave it in place for audit trail; downstream loaders should ignore
-- agents.status='offboarded'.
UPDATE agents SET status='offboarded',
                  offboarded_at=datetime('now'),
                  offboarded_reason='absorbed-by-eng-lead-per-adr-0014-section-2'
  WHERE agent='vpe' AND scope != 'company' AND status != 'offboarded';
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
