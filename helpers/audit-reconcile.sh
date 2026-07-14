#!/usr/bin/env bash
# helpers/audit-reconcile.sh
# Weekly reconciliation of agent_actions_log (hook-written, ground
# truth) vs decisions (agent-written, possibly tampered).
#
# Per handbook ADR 0004 Track 3: cover-up via fabricated decisions
# rows is detectable by reconciling against the hook log. The hook
# log row exists BEFORE the agent has a chance to write anywhere
# else, so a decisions row with no matching antecedent action is an
# anomaly worth surfacing.
#
# Anomalies surfaced:
#   1. decisions row in time window with no preceding agent_actions_log
#      entry in the same session within ±5 minutes — possible
#      fabrication.
#   2. agent_actions_log session that abruptly stops with multiple
#      pending rows that never got finalized — possible session crash
#      OR hook failure (deserves investigation).
#
# Notification: Critical priority via hooks/notification.sh →
# Telegram + Teams `Approvals` channel if anomaly count > 0.
#
# Schedule: weekly, Saturday 03:00 (low contention).

set -euo pipefail

# launchd / cron provide a minimal PATH — APPEND Homebrew dirs so turso/
# sqlite3/jq are found, without shadowing a test-shimmed or deliberately-
# first CLI on PATH (mirrors helpers/drain-outbox.sh).
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"

# BUG-027: run-ID stamp + prune log to last 7 runs.
_LOG="$SCRIPT_DIR/../.juvant/logs/audit-reconcile.log"
if [[ -f "$_LOG" ]]; then
  _total=$(grep -c '^=== RUN ' "$_LOG" 2>/dev/null || true)
  if [[ "${_total:-0}" -gt 7 ]]; then
    _skip=$(( _total - 7 ))
    awk -v skip="$_skip" '/^=== RUN /{n++} n>skip{print}' \
      "$_LOG" > "${_LOG}.tmp" && mv "${_LOG}.tmp" "$_LOG"
  fi
fi
echo "=== RUN $(date -u +%Y%m%dT%H%M%SZ) ===" >> "$_LOG"

# Route DB access through hooks/lib/db.sh: provider-agnostic (turso/azure/
# aws/gcp cloud OR local sqlite), timeout-bounded (BUG-046), and reading the
# canonical `.db.url` config key with `.turso_url` fallback. The old
# `jq -r '.turso_url'` read FATAL-exited on v0.8 instances whose config
# moved the endpoint under `.db.*`, and silently no-op'd on local-sqlite
# adopters (the turso CLI cannot read a filesystem path) — either way this
# Track-3 reconcile died without a trace.
export JUVANT_CONFIG="$CONFIG"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../hooks/lib/db.sh"
juvant_db_resolve
if [[ -z "${JUVANT_DB_PROVIDER:-}" ]]; then
  echo "[audit-reconcile] FATAL: no DB provider configured — set .db.provider (or legacy .turso_url) in $CONFIG" >&2
  exit 1
fi
if ! juvant_db_cli_ok; then
  echo "[audit-reconcile] FATAL: the '$JUVANT_DB_PROVIDER' DB CLI ($(juvant_db_required_cli)) is not on PATH — re-run helpers/install-schedules.sh so the schedule's PATH includes it." >&2
  exit 1
fi

WINDOW_DAYS=7
SINCE=$(date -u -v-${WINDOW_DAYS}d +"%Y-%m-%d %H:%M:%S" 2>/dev/null \
        || date -u -d "${WINDOW_DAYS} days ago" +"%Y-%m-%d %H:%M:%S")

# Staleness threshold (shared by the Layer-2 auto-close pass below and the
# Anomaly-4 count further down). 3 days tolerates specs pending CEO approval
# over a weekend.
STALE_DAYS=3
STALE_SINCE=$(date -u -v-${STALE_DAYS}d +"%Y-%m-%d %H:%M:%S" 2>/dev/null \
              || date -u -d "${STALE_DAYS} days ago" +"%Y-%m-%d %H:%M:%S")

# ── Layer 2 auto-close (ADR 0028 / ARCH-017) ────────────────────────────────
# Recover and close the VERIFIABLE subset of stale specs, so already-done work
# stops surfacing as Anomaly 4 (stale) / Anomaly 1 (orphan). Runs BEFORE the
# anomaly counts so a row closed this run drops out of THIS run's counts.
#
# STRICT bounds (§4c maintenance-writer carve-out — this helper is not an agent
# and bypasses Track 2b, so the bound lives here + in the schema trigger):
#   • pr-spec only, company scope (this DB), status approved → executed only;
#   • close ONLY when EXACTLY ONE merged PR in the company repo references
#     `decisions#<id>` in its body (deterministic link per ADR-0028 D2);
#   • write ONLY the close-set (status, executed_at,
#     executed_by='audit-reconcile', source_ref); NEVER INSERT, never any other
#     field;
#   • anything ambiguous (0 or >1 match, gh absent/unauth, repo unresolved,
#     non-pr-spec) is left untouched → still surfaced by the Anomaly-4 alert.
# The schema trigger decisions_executed_requires_executor_upd is the storage
# -layer backstop: it ABORTs any executed transition lacking source_ref.
AUTO_CLOSED=0
_AC_REPO=$(jq -r '
  (.github_repos[0])
  // (if .github_repo then (.github_repo.org + "/" + .github_repo.repo_name) else "" end)
  // ""' "$CONFIG" 2>/dev/null || echo "")
if [[ -n "$_AC_REPO" ]] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  while IFS= read -r _AC_ID; do
    [[ "$_AC_ID" =~ ^[0-9]+$ ]] || continue
    _AC_HITS=$(gh pr list --repo "$_AC_REPO" --state merged \
      --search "decisions#${_AC_ID} in:body" \
      --json number,mergedAt 2>/dev/null || echo "[]")
    [[ "$(echo "$_AC_HITS" | jq 'length' 2>/dev/null || echo 0)" == "1" ]] || continue
    _AC_NUM=$(echo "$_AC_HITS" | jq -r '.[0].number' 2>/dev/null || echo "")
    _AC_MERGED=$(echo "$_AC_HITS" | jq -r '.[0].mergedAt' 2>/dev/null || echo "")
    [[ "$_AC_NUM" =~ ^[0-9]+$ && -n "$_AC_MERGED" ]] || continue
    if juvant_db_exec "UPDATE decisions SET status='executed', executed_by='audit-reconcile', executed_at='${_AC_MERGED}', source_ref='${_AC_REPO}#${_AC_NUM}' WHERE id=${_AC_ID} AND status='approved' AND category='pr-spec';" >/dev/null 2>&1; then
      AUTO_CLOSED=$((AUTO_CLOSED + 1))
      echo "[audit-reconcile] auto-closed decisions#${_AC_ID} → ${_AC_REPO}#${_AC_NUM} (merged ${_AC_MERGED})" | tee -a "$_LOG" >&2
    fi
  done < <(juvant_db_query "
    SELECT id FROM decisions
    WHERE category = 'pr-spec' AND status = 'approved'
      AND created_at < '$STALE_SINCE';
  " 2>/dev/null | { grep -E '^[0-9]+$' || true; })
elif [[ -z "$_AC_REPO" ]]; then
  # BUG-057 (juvantlabs/juvant-os-pm#144): never fail-open silently. If the company repo is unresolved but
  # there ARE stale approved pr-specs that Layer 2 could have closed, WARN so
  # the config gap (github_repos not populated by company-init) is visible.
  _AC_STALE_PR=$(juvant_db_query "
    SELECT COUNT(*) FROM decisions
    WHERE category = 'pr-spec' AND status = 'approved'
      AND created_at < '$STALE_SINCE';
  " 2>/dev/null | { grep -E '^[0-9]+$' || true; } | tail -1)
  if [[ "${_AC_STALE_PR:-0}" -gt 0 ]]; then
    echo "[audit-reconcile] WARN: ${_AC_STALE_PR} stale approved pr-spec(s) but .github_repos is unresolved in $CONFIG — Layer 2 auto-close cannot run (ARCH-017 BUG-057). Populate github_repos." | tee -a "$_LOG" >&2
  fi
fi

# Anomaly 1: decisions rows with no matching agent_actions_log in same
# session within ±5 minutes. Tolerance accounts for hook-write delay.
# BUG-026 fix: main-thread CoS writes are logged as agent='unknown'
# (no agent_type in operator context). Accept 'unknown' as a valid
# antecedent for decisions.agent='cos' so legitimate CoS decisions do
# not trigger false-positive fabrication alerts.
# ADR-0028 D3: a Layer-2 auto-close is an UPDATE (never INSERT), so it does not
# change created_at and cannot manufacture an orphan; the executed_by tag is
# nonetheless excluded here as belt-and-suspenders against a future regression.
ORPHAN_DECISIONS=$(juvant_db_query "
  SELECT COUNT(*) FROM decisions d
  WHERE d.created_at > '$SINCE'
    AND (d.executed_by IS NULL OR d.executed_by <> 'audit-reconcile')
    AND NOT EXISTS (
      SELECT 1 FROM agent_actions_log a
      WHERE (a.agent = d.agent OR (d.agent = 'cos' AND a.agent = 'unknown'))
        AND ABS(julianday(a.started_at) - julianday(d.created_at)) * 1440 <= 5
    );
" 2>/dev/null | { grep -E '^[0-9]+$' || true; } | tail -1 | tr -d ' ')

# Anomaly 2: pending rows older than 1 hour that belong to sessions
# with mixed status (at least one completed row). This distinguishes
# crash pattern (some success/failure + some stuck pending) from
# background subagent pattern (ALL rows pending — post-tool-use hook
# never reaches background subagent process context, BUG-025).
STUCK_PENDING=$(juvant_db_query "
  SELECT COUNT(*) FROM agent_actions_log
  WHERE status = 'pending'
    AND started_at > '$SINCE'
    AND julianday(CURRENT_TIMESTAMP) - julianday(started_at) > (1.0/24)
    AND session_id IN (
      SELECT DISTINCT session_id FROM agent_actions_log
      WHERE status IN ('success', 'failure', 'denied')
        AND started_at > '$SINCE'
    );
" 2>/dev/null | { grep -E '^[0-9]+$' || true; } | tail -1 | tr -d ' ')

# Anomaly 3: §4c violations — project-scope agent wrote to company DB
# (FEAT-042 / SYSTEM_INVARIANTS §4c, 2026-05-18)
_PROJECT_AGENTS="'pca','product-lead','design-lead','eng-lead','eng-api','eng-backend','eng-frontend','eng-ai'"
SCOPE_VIOLATIONS=$(juvant_db_query "
  SELECT COUNT(*) FROM decisions
  WHERE created_at > '$SINCE'
    AND agent IN ($_PROJECT_AGENTS);
" 2>/dev/null | { grep -E '^[0-9]+$' || true; } | tail -1 | tr -d ' ')

# Anomaly 4 (FEAT-039): stale gh-issue-spec / pr-spec decisions — approved or
# proposed but never executed after STALE_DAYS days. Surfaces the write-path gap
# where Eng Lead created the GH artifact but skipped the source_ref / status
# UPDATE. (STALE_DAYS / STALE_SINCE defined above, shared with the Layer-2
# auto-close pass — verifiable pr-specs are already closed by the time this
# count runs, so it reflects only the genuinely-unrecoverable remainder.)
STALE_SPECS=$(juvant_db_query "
  SELECT COUNT(*) FROM decisions
  WHERE category IN ('gh-issue-spec', 'pr-spec')
    AND status IN ('proposed', 'approved')
    AND created_at < '$STALE_SINCE';
" 2>/dev/null | { grep -E '^[0-9]+$' || true; } | tail -1 | tr -d ' ')

ORPHAN_DECISIONS=${ORPHAN_DECISIONS:-0}
STUCK_PENDING=${STUCK_PENDING:-0}
SCOPE_VIOLATIONS=${SCOPE_VIOLATIONS:-0}
STALE_SPECS=${STALE_SPECS:-0}
TOTAL_ANOMALIES=$((ORPHAN_DECISIONS + STUCK_PENDING + SCOPE_VIOLATIONS + STALE_SPECS))

echo "[audit-reconcile] window: last ${WINDOW_DAYS} days"
echo "[audit-reconcile] auto-closed stale pr-specs (Layer 2, ADR 0028): $AUTO_CLOSED"
echo "[audit-reconcile] orphan decisions (possible fabrication):  $ORPHAN_DECISIONS"
echo "[audit-reconcile] stuck pending (possible hook failure):     $STUCK_PENDING"
echo "[audit-reconcile] scope-boundary violations §4c (proj→co):  $SCOPE_VIOLATIONS"
echo "[audit-reconcile] stale gh-issue/pr specs (>3d unexecuted): $STALE_SPECS"

if [[ "$TOTAL_ANOMALIES" -gt 0 ]]; then
  MSG="Audit reconcile: ${ORPHAN_DECISIONS} orphan + ${STUCK_PENDING} stuck-pending + ${SCOPE_VIOLATIONS} scope-violations + ${STALE_SPECS} stale-specs in last ${WINDOW_DAYS}d"
  echo "[audit-reconcile] ALERT: $MSG" >&2
  # Use existing notification.sh infrastructure
  JUVANT_NOTIFY_CHANNEL=system \
    bash "$SCRIPT_DIR/../hooks/notification.sh" <<< "{\"message\":\"$MSG\"}" \
    || echo "[audit-reconcile] WARN: failed to send notification" >&2
  exit 1
fi

echo "[audit-reconcile] OK — no anomalies in last ${WINDOW_DAYS}d"
exit 0
