#!/usr/bin/env bash
# scripts/governance-backfill.sh
# FEAT-040 Layer 0 — Retroactive governance remediation (bonifica)
#
# Phases:
#   0a  Category normalization — auto-map non-canonical, promote to KB, flag for review
#   0b  Lifecycle reconciliation — mark executed via GH API where source_ref is set
#   0d  input_summary stamp — [REDACTED] on pre-FEAT-040 denied/failure rows
#
# Usage:
#   bash scripts/governance-backfill.sh [options]
#
# Options:
#   --dry-run          Report only, no writes (default for monthly scheduled runs)
#   --apply            Commit writes after report (required for initial one-time run)
#   --project=<slug>   Run against a specific project DB only
#   --all              Run against company DB + all project DBs (monthly default)
#   --phase=<0a|0b|0d|all>  Run a specific phase only (default: all)
#   --db-url=<url>     Override DB URL (for testing)
#
# Requires: turso CLI, gh CLI (for phase 0b), jq
#
# Output: .juvant/logs/governance-backfill-<date>.md (human-readable report)

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$ROOT/.juvant/config.json"
LOG_DIR="$ROOT/.juvant/logs"
DATE=$(date -u +"%Y-%m-%d")
REPORT_FILE="$LOG_DIR/governance-backfill-${DATE}.md"

# ─── Arg parsing ─────────────────────────────────────────────────────────────
DRY_RUN=1
APPLY=0
PROJECT_SLUG=""
RUN_ALL=0
PHASE="all"
DB_URL_OVERRIDE=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=1 ;;
    --apply)      DRY_RUN=0; APPLY=1 ;;
    --all)        RUN_ALL=1 ;;
    --project=*)  PROJECT_SLUG="${arg#--project=}" ;;
    --phase=*)    PHASE="${arg#--phase=}" ;;
    --db-url=*)   DB_URL_OVERRIDE="${arg#--db-url=}" ;;
  esac
done

mkdir -p "$LOG_DIR"

# ─── Logging ─────────────────────────────────────────────────────────────────
_report_lines=()
report() { echo "[backfill] $*"; _report_lines+=("$*"); }
report_raw() { _report_lines+=("$*"); }

# ─── DB helpers ──────────────────────────────────────────────────────────────
_current_db_url=""

set_db() { _current_db_url="$1"; }

run_sql() {
  local sql="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  turso db shell "$_current_db_url" "$sql" 2>/dev/null || true
}

query_sql() {
  local sql="$1"
  turso db shell "$_current_db_url" "$sql" 2>/dev/null || true
}

count_sql() {
  local sql="$1"
  turso db shell "$_current_db_url" "$sql" 2>/dev/null \
    | grep -E '^[0-9]+$' | tail -1 | tr -d ' ' || echo "0"
}

# ─── Category mapping tables ──────────────────────────────────────────────────
# AUTO_MAP: non-canonical → canonical (high-confidence semantic equivalence)
declare -A AUTO_MAP
AUTO_MAP=(
  ["gh-execution-confirmed"]="gh-issue-spec"
  ["gh-issue-spec-execution-confirmed"]="gh-issue-spec"
  ["infra-spec"]="eng-platform-spec"
  ["infra"]="eng-platform-spec"
  ["infra-config"]="eng-platform-spec"
  ["deployment"]="deployment-spec"
  ["security-remediation"]="eng-platform-spec"
  ["gh-project-spec"]="gh-project-update-spec"
  ["review-scheduled"]="migration-watch"
  ["versioning"]="bootstrap-action"
  ["manifesto"]="bootstrap-action"
  ["manifesto-review"]="bootstrap-action"
  ["manifesto-update"]="bootstrap-action"
  ["direct-session"]="bootstrap-action"
  ["policy-promotion"]="bootstrap-action"
  ["tech-standard"]="tool-matrix-change"
  ["convention"]="tool-matrix-change"
  ["system-audit"]="bootstrap-action"
  ["security-consult"]="bootstrap-action"
  ["ethical-validation"]="bootstrap-action"
  ["spec-rejected"]="bootstrap-action"
  ["milestone"]="bootstrap-action"
  ["architecture"]="arch-decision"
)

# PROMOTE_TO_KB: content is knowledge, not a spec action → move to knowledge_base
PROMOTE_TO_KB=(
  "product-decision"
  "product"
  "legal"
  "legal-decision"
  "business"
  "plan-validation"
  "plan-approval"
  "prd-published"
  "context-update"
  "design-sign-off"
)

# ALREADY_CANONICAL (new, added by FEAT-040 — no action needed, just verify)
ALREADY_CANONICAL=(
  "arch-decision"
  "operational-violation"
  "kb-orphan-review"
)

# FLAG_FOR_REVIEW: ambiguous — surface to CEO, no auto-write
FLAG_FOR_REVIEW=(
  "brand-spec"
  "plan-approval"
  "prd-published"
)

# ─── Phase 0a: Category normalization ────────────────────────────────────────
phase_0a() {
  local db_label="$1"
  report ""
  report "=== Phase 0a: Category normalization ($db_label) ==="

  local total_non_canonical=0

  # Auto-map
  for src in "${!AUTO_MAP[@]}"; do
    local dst="${AUTO_MAP[$src]}"
    local n
    n=$(count_sql "SELECT COUNT(*) FROM decisions WHERE category='$src';")
    if [[ "${n:-0}" -gt 0 ]]; then
      report "  auto-map: '$src' → '$dst'  ($n rows)"
      report_raw "  - auto-map \`$src\` → \`$dst\` ($n rows)"
      run_sql "UPDATE decisions SET category='$dst',
                 rationale=coalesce(rationale,'')||' [backfill: category mapped from $src, FEAT-040]'
               WHERE category='$src';"
      total_non_canonical=$((total_non_canonical + n))
    fi
  done

  # Promote to KB
  local promote_in
  promote_in=$(printf "'%s'," "${PROMOTE_TO_KB[@]}")
  promote_in="${promote_in%,}"

  local n_promote
  n_promote=$(count_sql "SELECT COUNT(*) FROM decisions WHERE category IN ($promote_in) AND status != 'superseded';")
  if [[ "${n_promote:-0}" -gt 0 ]]; then
    report "  promote-kb: categories ($promote_in) → knowledge_base  ($n_promote rows)"
    report_raw "  - promote to KB: $n_promote decisions → \`knowledge_base\` (category=\`decision-archive\`)"
    run_sql "INSERT OR IGNORE INTO knowledge_base (category, title, content, source_ref, promoted_by, scope, created_at)
             SELECT 'decision-archive',
                    title,
                    'Original decision category: ' || category || char(10) || char(10) || coalesce(rationale,''),
                    'decisions#' || id,
                    'governance-backfill',
                    scope,
                    CURRENT_TIMESTAMP
             FROM decisions
             WHERE category IN ($promote_in) AND status != 'superseded';"
    run_sql "UPDATE decisions
             SET status='superseded',
                 rationale=coalesce(rationale,'')||' [backfill: promoted to knowledge_base, FEAT-040]'
             WHERE category IN ($promote_in) AND status != 'superseded';"
    total_non_canonical=$((total_non_canonical + n_promote))
  fi

  # Flag for manual review (report only, never auto-write)
  for cat in "${FLAG_FOR_REVIEW[@]}"; do
    local n_flag
    n_flag=$(count_sql "SELECT COUNT(*) FROM decisions WHERE category='$cat';")
    if [[ "${n_flag:-0}" -gt 0 ]]; then
      report "  flag-review: '$cat'  ($n_flag rows) — requires CEO input"
      report_raw "  - **MANUAL REVIEW NEEDED**: \`$cat\` ($n_flag rows)"
    fi
  done

  # Verify already-canonical new categories
  for cat in "${ALREADY_CANONICAL[@]}"; do
    local n_ok
    n_ok=$(count_sql "SELECT COUNT(*) FROM decisions WHERE category='$cat';")
    if [[ "${n_ok:-0}" -gt 0 ]]; then
      report "  canonical-ok: '$cat'  ($n_ok rows — now in canonical list)"
    fi
  done

  report "  total non-canonical processed: $total_non_canonical rows"
}

# ─── Phase 0b: Lifecycle reconciliation ──────────────────────────────────────
phase_0b() {
  local db_label="$1"
  report ""
  report "=== Phase 0b: Lifecycle reconciliation ($db_label) ==="

  local gh_token
  gh_token=$(jq -r '.github_token // ""' "$CONFIG" 2>/dev/null || echo "")

  # Decisions with source_ref → check GH API
  local with_ref
  with_ref=$(query_sql "SELECT id, source_ref, category FROM decisions
    WHERE status IN ('approved','proposed') AND source_ref IS NOT NULL AND source_ref != '';")

  local n_checked=0 n_executed=0 n_open=0

  while IFS='|' read -r id src_ref _cat; do
    [[ -z "$id" || "$id" =~ ^[[:space:]]*$ || "$id" == "ID" ]] && continue
    id=$(echo "$id" | xargs)
    src_ref=$(echo "$src_ref" | xargs)
    [[ -z "$src_ref" ]] && continue

    # Parse org/repo#N  (source_ref format: '<org>/<repo>#<N>')
    local repo issue_num
    repo="${src_ref%%#*}"
    issue_num="${src_ref##*#}"
    [[ -z "$repo" || -z "$issue_num" ]] && continue

    n_checked=$((n_checked + 1))

    local gh_state closed_at
    if [[ -n "$gh_token" ]]; then
      local api_resp
      api_resp=$(curl -sf -H "Authorization: Bearer $gh_token" \
        "https://api.github.com/repos/${repo}/issues/${issue_num}" 2>/dev/null || echo "{}")
      gh_state=$(echo "$api_resp" | jq -r '.state // "unknown"' 2>/dev/null || echo "unknown")
      closed_at=$(echo "$api_resp" | jq -r '.closed_at // ""' 2>/dev/null || echo "")
    else
      gh_state=$(gh api "repos/${repo}/issues/${issue_num}" --jq '.state' 2>/dev/null || echo "unknown")
      closed_at=$(gh api "repos/${repo}/issues/${issue_num}" --jq '.closed_at' 2>/dev/null || echo "")
    fi

    if [[ "$gh_state" == "closed" ]]; then
      report "  executed: decisions#${id} → ${src_ref} (closed on GH)"
      run_sql "UPDATE decisions
               SET status='executed',
                   executed_by='governance-backfill',
                   executed_at=coalesce('$closed_at', CURRENT_TIMESTAMP)
               WHERE id=${id};"
      n_executed=$((n_executed + 1))
    else
      report "  pending:  decisions#${id} → ${src_ref} (GH state: ${gh_state})"
      n_open=$((n_open + 1))
    fi
  done <<< "$with_ref"

  report "  with source_ref: checked=$n_checked  executed=$n_executed  still-open=$n_open"

  # Decisions without source_ref, approved, older than 30 days → supersede
  local stale_count
  stale_count=$(count_sql "SELECT COUNT(*) FROM decisions
    WHERE status IN ('approved','proposed')
      AND (source_ref IS NULL OR source_ref = '')
      AND julianday('now') - julianday(created_at) > 30;")

  if [[ "${stale_count:-0}" -gt 0 ]]; then
    report "  auto-supersede: $stale_count decisions (approved/proposed, no source_ref, >30d)"
    report_raw "  - $stale_count stale decisions (>30d, no GH match) → \`superseded\`"
    run_sql "UPDATE decisions
             SET status='superseded',
                 rationale=coalesce(rationale,'')||' [backfill: no GH artifact found after 30+ days, FEAT-040]'
             WHERE status IN ('approved','proposed')
               AND (source_ref IS NULL OR source_ref = '')
               AND julianday('now') - julianday(created_at) > 30;"
  fi

  # Remaining approved without source_ref, <30 days → surface as genuinely pending
  local pending_count
  pending_count=$(count_sql "SELECT COUNT(*) FROM decisions
    WHERE status IN ('approved','proposed')
      AND (source_ref IS NULL OR source_ref = '')
      AND julianday('now') - julianday(created_at) <= 30;")

  if [[ "${pending_count:-0}" -gt 0 ]]; then
    report "  genuinely-pending: $pending_count decisions (<30d, no source_ref) — review manually"
    report_raw "  - **CEO REVIEW**: $pending_count decisions still open and recent (listed below)"
    query_sql "SELECT id, agent, category, created_at, substr(title,1,70) as title
               FROM decisions
               WHERE status IN ('approved','proposed')
                 AND (source_ref IS NULL OR source_ref = '')
                 AND julianday('now') - julianday(created_at) <= 30
               ORDER BY created_at ASC;" | while read -r line; do
      report_raw "    $line"
    done
  fi
}

# ─── Phase 0d: input_summary stamp ───────────────────────────────────────────
phase_0d() {
  local db_label="$1"
  report ""
  report "=== Phase 0d: input_summary stamp ($db_label) ==="

  # Check if input_summary column exists
  local col_check
  col_check=$(query_sql "SELECT COUNT(*) FROM pragma_table_info('agent_actions_log') WHERE name='input_summary';" 2>/dev/null | grep -E '^[0-9]+$' | tail -1 | tr -d ' ' || echo "0")

  if [[ "${col_check:-0}" -eq 0 ]]; then
    report "  SKIP: input_summary column not present in this DB"
    return 0
  fi

  local n_null
  n_null=$(count_sql "SELECT COUNT(*) FROM agent_actions_log
    WHERE status IN ('denied','failure')
      AND (input_summary IS NULL OR trim(input_summary)='');")

  if [[ "${n_null:-0}" -gt 0 ]]; then
    report "  [REDACTED] stamp: $n_null rows (pre-FEAT-040 audit gap)"
    report_raw "  - $n_null denied/failure rows stamped \`[REDACTED — pre-FEAT-040 audit gap]\`"
    run_sql "UPDATE agent_actions_log
             SET input_summary='[REDACTED — pre-FEAT-040 audit gap]'
             WHERE status IN ('denied','failure')
               AND (input_summary IS NULL OR trim(input_summary)='');"
  else
    report "  OK: no NULL input_summary rows"
  fi
}

# ─── Run against one DB ───────────────────────────────────────────────────────
run_against_db() {
  local db_url="$1" db_label="$2"

  set_db "$db_url"
  report ""
  report "━━━ DB: $db_label ($db_url) ━━━"

  [[ "$PHASE" == "all" || "$PHASE" == "0a" ]] && phase_0a "$db_label"
  [[ "$PHASE" == "all" || "$PHASE" == "0b" ]] && phase_0b "$db_label"
  [[ "$PHASE" == "all" || "$PHASE" == "0d" ]] && phase_0d "$db_label"
}

# ─── Collect DB targets ───────────────────────────────────────────────────────
declare -a DB_TARGETS_URLS DB_TARGETS_LABELS

if [[ -n "$DB_URL_OVERRIDE" ]]; then
  DB_TARGETS_URLS=("$DB_URL_OVERRIDE")
  DB_TARGETS_LABELS=("override")
elif [[ -n "$PROJECT_SLUG" ]]; then
  pdb=$(jq -r --arg s "$PROJECT_SLUG" '.projects[$s].db.url // .projects[$s].url // ""' "$CONFIG" 2>/dev/null)
  if [[ -z "$pdb" || "$pdb" == "null" ]]; then
    echo "[backfill] ERROR: project '$PROJECT_SLUG' not found in config" >&2
    exit 1
  fi
  DB_TARGETS_URLS=("$pdb")
  DB_TARGETS_LABELS=("project=$PROJECT_SLUG")
else
  # Company DB always first
  company_db=$(jq -r '.db.url // ""' "$CONFIG" 2>/dev/null)
  if [[ -n "$company_db" && "$company_db" != "null" ]]; then
    DB_TARGETS_URLS=("$company_db")
    DB_TARGETS_LABELS=("company")
  fi
  if [[ "$RUN_ALL" -eq 1 ]]; then
    while IFS= read -r slug; do
      [[ -z "$slug" || "$slug" == "null" ]] && continue
      pdb=$(jq -r --arg s "$slug" '.projects[$s].db.url // .projects[$s].url // ""' "$CONFIG" 2>/dev/null)
      [[ -z "$pdb" || "$pdb" == "null" ]] && continue
      DB_TARGETS_URLS+=("$pdb")
      DB_TARGETS_LABELS+=("project=$slug")
    done < <(jq -r '.projects // {} | keys[]' "$CONFIG" 2>/dev/null)
  fi
fi

if [[ ${#DB_TARGETS_URLS[@]} -eq 0 ]]; then
  echo "[backfill] ERROR: no DB targets found. Check .juvant/config.json" >&2
  exit 1
fi

# ─── Main ─────────────────────────────────────────────────────────────────────
mode_label="DRY RUN (report only)"
[[ "$APPLY" -eq 1 ]] && mode_label="APPLY (writes committed)"

report "governance-backfill — FEAT-040 Layer 0"
report "mode:    $mode_label"
report "phase:   $PHASE"
report "targets: ${DB_TARGETS_LABELS[*]}"
report "date:    $DATE"

for i in "${!DB_TARGETS_URLS[@]}"; do
  run_against_db "${DB_TARGETS_URLS[$i]}" "${DB_TARGETS_LABELS[$i]}"
done

report ""
report "━━━ Complete ━━━"
if [[ "$DRY_RUN" -eq 1 ]]; then
  report "Dry run finished. Re-run with --apply to commit writes."
else
  report "Writes committed. Run audit-reconcile.sh to verify."
fi

# ─── Write report file ────────────────────────────────────────────────────────
{
  echo "# Governance Backfill Report — $DATE"
  echo ""
  echo "**Mode**: $mode_label  "
  echo "**Phase**: $PHASE  "
  echo "**Targets**: ${DB_TARGETS_LABELS[*]}  "
  echo ""
  for line in "${_report_lines[@]}"; do
    echo "$line"
  done
} > "$REPORT_FILE"

echo "[backfill] Report saved: $REPORT_FILE"
exit 0
