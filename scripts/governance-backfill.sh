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
# Compatible: bash 3.2+ (macOS default)
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
_report_lines=""
report() {
  echo "[backfill] $*"
  _report_lines="${_report_lines}
$*"
}

# ─── DB helpers ──────────────────────────────────────────────────────────────
_current_db_url=""

set_db() { _current_db_url="$1"; }

run_sql() {
  local sql="$1"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  turso db shell "$_current_db_url" "$sql" 2>/dev/null || true
}

query_sql() {
  turso db shell "$_current_db_url" "$1" 2>/dev/null || true
}

count_sql() {
  turso db shell "$_current_db_url" "$1" 2>/dev/null \
    | grep -E '^[0-9]+$' | tail -1 | tr -d ' ' || echo "0"
}

# ─── Category mapping (bash 3.2 compatible — case instead of declare -A) ─────
# Returns the canonical target for a non-canonical category, or empty string.
map_category() {
  case "$1" in
    gh-execution-confirmed|gh-issue-spec-execution-confirmed)
      echo "gh-issue-spec" ;;
    infra-spec|infra|infra-config|security-remediation)
      echo "eng-platform-spec" ;;
    deployment)
      echo "deployment-spec" ;;
    gh-project-spec)
      echo "gh-project-update-spec" ;;
    review-scheduled)
      echo "migration-watch" ;;
    versioning|manifesto|manifesto-review|manifesto-update|\
    direct-session|policy-promotion|system-audit|\
    security-consult|ethical-validation|spec-rejected|milestone)
      echo "bootstrap-action" ;;
    tech-standard|convention)
      echo "tool-matrix-change" ;;
    architecture)
      echo "arch-decision" ;;
    *)
      echo "" ;;
  esac
}

# Categories whose rows should move to knowledge_base (content is durable
# knowledge, not a spec action).
is_promote_to_kb() {
  case "$1" in
    product-decision|product|legal|legal-decision|business|\
    plan-validation|plan-approval|prd-published|context-update|design-sign-off)
      return 0 ;;
    *) return 1 ;;
  esac
}

# Categories that need manual CEO review before any action.
is_flag_for_review() {
  case "$1" in
    brand-spec) return 0 ;;
    *) return 1 ;;
  esac
}

# The full canonical list (for the NOT IN query).
CANONICAL_LIST="'model-override','tool-matrix-change','pr-spec','gh-issue-spec',
'gh-project-update-spec','gh-milestone-spec','install-spec',
'branch-protection-spec','release-spec','deployment-spec',
'secret-rotation-spec','eng-output-held','disclosure-unavailable',
'bootstrap-action','cascade-escalation','cascade-postmortem',
'skill-gap','migration-watch','upstream-sync-proposal','eng-platform-spec',
'arch-decision','operational-violation','kb-orphan-review'"

# ─── Phase 0a: Category normalization ────────────────────────────────────────
phase_0a() {
  local db_label="$1"
  report ""
  report "=== Phase 0a: Category normalization ($db_label) ==="

  local total=0

  # Get all distinct non-canonical categories present in this DB
  local non_canonical_raw
  non_canonical_raw=$(query_sql "SELECT DISTINCT category FROM decisions
    WHERE category NOT IN ($CANONICAL_LIST)
      AND category IS NOT NULL
    ORDER BY category;")

  while IFS= read -r cat; do
    # Skip header row and blank lines from turso output
    cat=$(echo "$cat" | tr -d '[:space:]')
    [[ -z "$cat" || "$cat" == "CATEGORY" || "$cat" == "category" ]] && continue

    local dst
    dst=$(map_category "$cat")

    if [[ -n "$dst" ]]; then
      local n
      n=$(count_sql "SELECT COUNT(*) FROM decisions WHERE category='$cat';")
      n=${n:-0}
      report "  auto-map: '$cat' → '$dst'  ($n rows)"
      run_sql "UPDATE decisions
               SET category='$dst',
                   rationale=coalesce(rationale,'')||' [backfill: mapped from $cat, FEAT-040]'
               WHERE category='$cat';"
      total=$((total + n))

    elif is_promote_to_kb "$cat"; then
      local n
      n=$(count_sql "SELECT COUNT(*) FROM decisions WHERE category='$cat' AND status!='superseded';")
      n=${n:-0}
      report "  promote-kb: '$cat' → knowledge_base  ($n rows)"
      run_sql "INSERT OR IGNORE INTO knowledge_base
                 (category, title, content, source_ref, promoted_by, scope, created_at)
               SELECT 'decision-archive', title,
                      'Original category: '||category||char(10)||char(10)||coalesce(rationale,''),
                      'decisions#'||id, 'governance-backfill', scope, CURRENT_TIMESTAMP
               FROM decisions
               WHERE category='$cat' AND status!='superseded';"
      run_sql "UPDATE decisions
               SET status='superseded',
                   rationale=coalesce(rationale,'')||' [backfill: promoted to KB, FEAT-040]'
               WHERE category='$cat' AND status!='superseded';"
      total=$((total + n))

    elif is_flag_for_review "$cat"; then
      local n
      n=$(count_sql "SELECT COUNT(*) FROM decisions WHERE category='$cat';")
      n=${n:-0}
      report "  flag-review: '$cat'  ($n rows) — requires CEO input"

    else
      local n
      n=$(count_sql "SELECT COUNT(*) FROM decisions WHERE category='$cat';")
      n=${n:-0}
      report "  unknown: '$cat'  ($n rows) — no mapping defined, flagged for review"
    fi

  done <<< "$non_canonical_raw"

  report "  total rows processed in 0a: $total"
}

# ─── Phase 0b: Lifecycle reconciliation ──────────────────────────────────────
phase_0b() {
  local db_label="$1"
  report ""
  report "=== Phase 0b: Lifecycle reconciliation ($db_label) ==="

  local gh_token=""
  gh_token=$(jq -r '.github_token // ""' "$CONFIG" 2>/dev/null || true)

  local n_checked=0 n_executed=0 n_open=0

  local rows
  rows=$(query_sql "SELECT id||'|'||source_ref FROM decisions
    WHERE status IN ('approved','proposed')
      AND source_ref IS NOT NULL AND source_ref != ''
    ORDER BY id;")

  while IFS= read -r row; do
    row=$(echo "$row" | tr -d '[:space:]')
    [[ -z "$row" || "$row" =~ ^id\| ]] && continue

    local id src_ref repo issue_num
    id="${row%%|*}"
    src_ref="${row#*|}"
    [[ -z "$id" || -z "$src_ref" ]] && continue

    repo="${src_ref%%#*}"
    issue_num="${src_ref##*#}"
    [[ -z "$repo" || -z "$issue_num" || "$repo" == "$src_ref" ]] && continue

    n_checked=$((n_checked + 1))

    local gh_state="" closed_at=""
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
      local exec_at="${closed_at:-CURRENT_TIMESTAMP}"
      run_sql "UPDATE decisions
               SET status='executed', executed_by='governance-backfill',
                   executed_at='$exec_at'
               WHERE id=${id};"
      n_executed=$((n_executed + 1))
    else
      report "  pending:  decisions#${id} → ${src_ref} (GH: ${gh_state})"
      n_open=$((n_open + 1))
    fi
  done <<< "$rows"

  report "  with source_ref: checked=$n_checked  executed=$n_executed  open=$n_open"

  # Auto-supersede: approved/proposed, no source_ref, older than 30 days
  local stale_count
  stale_count=$(count_sql "SELECT COUNT(*) FROM decisions
    WHERE status IN ('approved','proposed')
      AND (source_ref IS NULL OR source_ref='')
      AND julianday('now') - julianday(created_at) > 30;")
  stale_count=${stale_count:-0}

  if [[ "$stale_count" -gt 0 ]]; then
    report "  auto-supersede: $stale_count decisions (>30d, no source_ref)"
    run_sql "UPDATE decisions
             SET status='superseded',
                 rationale=coalesce(rationale,'')||' [backfill: no GH artifact after 30+ days, FEAT-040]'
             WHERE status IN ('approved','proposed')
               AND (source_ref IS NULL OR source_ref='')
               AND julianday('now') - julianday(created_at) > 30;"
  fi

  # Surface genuinely pending (recent, no source_ref)
  local pending_count
  pending_count=$(count_sql "SELECT COUNT(*) FROM decisions
    WHERE status IN ('approved','proposed')
      AND (source_ref IS NULL OR source_ref='')
      AND julianday('now') - julianday(created_at) <= 30;")
  pending_count=${pending_count:-0}

  if [[ "$pending_count" -gt 0 ]]; then
    report "  genuinely-pending: $pending_count decisions (<30d) — review manually"
    local pending_rows
    pending_rows=$(query_sql "SELECT id, agent, category, created_at, substr(title,1,60) as title
      FROM decisions
      WHERE status IN ('approved','proposed')
        AND (source_ref IS NULL OR source_ref='')
        AND julianday('now') - julianday(created_at) <= 30
      ORDER BY created_at ASC;")
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      report "    $line"
    done <<< "$pending_rows"
  fi
}

# ─── Phase 0d: input_summary stamp ───────────────────────────────────────────
phase_0d() {
  local db_label="$1"
  report ""
  report "=== Phase 0d: input_summary stamp ($db_label) ==="

  local col_check
  col_check=$(query_sql "SELECT COUNT(*) FROM pragma_table_info('agent_actions_log')
    WHERE name='input_summary';" 2>/dev/null | grep -E '^[0-9]+$' | tail -1 | tr -d ' ' || echo "0")

  if [[ "${col_check:-0}" -eq 0 ]]; then
    report "  SKIP: input_summary column not present in this DB"
    return 0
  fi

  local n_null
  n_null=$(count_sql "SELECT COUNT(*) FROM agent_actions_log
    WHERE status IN ('denied','failure')
      AND (input_summary IS NULL OR trim(input_summary)='');")
  n_null=${n_null:-0}

  if [[ "$n_null" -gt 0 ]]; then
    report "  [REDACTED] stamp: $n_null rows (pre-FEAT-040 audit gap)"
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
DB_TARGETS_URLS=""
DB_TARGETS_LABELS=""

add_target() {
  if [[ -z "$DB_TARGETS_URLS" ]]; then
    DB_TARGETS_URLS="$1"
    DB_TARGETS_LABELS="$2"
  else
    DB_TARGETS_URLS="${DB_TARGETS_URLS}|$1"
    DB_TARGETS_LABELS="${DB_TARGETS_LABELS}|$2"
  fi
}

if [[ -n "$DB_URL_OVERRIDE" ]]; then
  add_target "$DB_URL_OVERRIDE" "override"
elif [[ -n "$PROJECT_SLUG" ]]; then
  pdb=$(jq -r --arg s "$PROJECT_SLUG" '.projects[$s].db.url // .projects[$s].url // ""' "$CONFIG" 2>/dev/null || true)
  if [[ -z "$pdb" || "$pdb" == "null" ]]; then
    echo "[backfill] ERROR: project '$PROJECT_SLUG' not found in config" >&2
    exit 1
  fi
  add_target "$pdb" "project=$PROJECT_SLUG"
else
  company_db=$(jq -r '.db.url // ""' "$CONFIG" 2>/dev/null || true)
  if [[ -n "$company_db" && "$company_db" != "null" ]]; then
    add_target "$company_db" "company"
  fi
  if [[ "$RUN_ALL" -eq 1 ]]; then
    while IFS= read -r slug; do
      [[ -z "$slug" || "$slug" == "null" ]] && continue
      pdb=$(jq -r --arg s "$slug" '.projects[$s].db.url // .projects[$s].url // ""' "$CONFIG" 2>/dev/null || true)
      [[ -z "$pdb" || "$pdb" == "null" ]] && continue
      add_target "$pdb" "project=$slug"
    done < <(jq -r '.projects // {} | keys[]' "$CONFIG" 2>/dev/null || true)
  fi
fi

if [[ -z "$DB_TARGETS_URLS" ]]; then
  echo "[backfill] ERROR: no DB targets found. Check .juvant/config.json" >&2
  exit 1
fi

# ─── Main ─────────────────────────────────────────────────────────────────────
mode_label="DRY RUN (report only)"
[[ "$APPLY" -eq 1 ]] && mode_label="APPLY (writes committed)"

report "governance-backfill — FEAT-040 Layer 0"
report "mode:    $mode_label"
report "phase:   $PHASE"
report "date:    $DATE"

IFS='|' read -ra _urls   <<< "$DB_TARGETS_URLS"
IFS='|' read -ra _labels <<< "$DB_TARGETS_LABELS"

for i in "${!_urls[@]}"; do
  run_against_db "${_urls[$i]}" "${_labels[$i]}"
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
  echo ""
  echo "$_report_lines"
} > "$REPORT_FILE"

echo "[backfill] Report saved: $REPORT_FILE"
exit 0
