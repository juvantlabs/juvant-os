#!/usr/bin/env bash
# hooks/lib/spec-marking-gate.sh
# ARCH-017 Layer 1 (ADR 0028) — capture-at-execution gate, SHARED by the Stop
# (main-thread) and SubagentStop hooks. Keeping the logic in one place is
# deliberate: the Track-2b-vs-2c/2d config-resolution drift that became BUG-056 is
# exactly the failure a single source prevents.
#
# Contract: the caller must have already sourced hooks/lib/db.sh and run
# juvant_db_resolve. Then:
#
#   reason="$(spec_marking_gate <session_id> <role_or_empty>)"
#   [[ -n "$reason" ]] && { emit block JSON + reason on stderr; exit 2; }
#
# Prints a self-remediating block reason to stdout when a PR merged THIS session
# references an approved, still-unmarked pr-spec (decisions#<id> in the PR body);
# prints nothing (fail-open) on any ambiguity, missing tool, or error.

# juvant_spool_path is provided by hooks/lib/db.sh (sourced by the caller).

spec_marking_gate() {
  local session_id="$1" role="${2:-}"
  [[ -n "$session_id" ]] || return 0

  local hooks_dir cfg spool repo sums sum pr body id st sess_esc role_pred sid
  hooks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cfg="${JUVANT_CONFIG:-$hooks_dir/../.juvant/config.json}"
  [[ -f "$cfg" ]]               || return 0
  command -v jq >/dev/null 2>&1 || return 0

  # BUG-058: a just-happened landing signal is written to the FEAT-051 async
  # audit spool and may not be in agent_actions_log yet at stop time. Drain first
  # so it is visible to the queries below — for BOTH signals: a `gh pr merge`
  # (ADR 0028) and a `JUVANT_EXECUTING_SPEC=<id>`-stamped command (ADR 0029).
  # Scoped to spools that actually hold such a signal, so a per-turn Stop hook
  # pays nothing on the common path. The drainer is idempotent + crash-safe.
  spool="$(juvant_spool_path 2>/dev/null || echo "")"
  if [[ -n "$spool" && -s "$spool" ]] && grep -qiE 'merge|JUVANT_EXECUTING_SPEC' "$spool" 2>/dev/null; then
    bash "$hooks_dir/../helpers/drain-audit-spool.sh" >/dev/null 2>&1 || true
  fi

  sess_esc="$(printf '%s' "$session_id" | sed "s/'/''/g")"
  role_pred=""
  if [[ -n "$role" && "$role" != "unknown" ]]; then
    role_pred="AND agent = '$(printf '%s' "$role" | sed "s/'/''/g")'"
  fi

  # ── Path 1 (ADR 0029): artifact-less executions via a stamped spec_id ────────
  # A Bash landing command prefixed `JUVANT_EXECUTING_SPEC=<id>` stamped that id
  # onto its audit row. If any such spec is still 'approved', the execution left
  # it unmarked → block. Pure-DB: needs NO gh/repo, so it runs even when those
  # are unavailable. A missing spec_id column (un-migrated DB) makes the query
  # error → empty → fail-open. Satisfiable: the agent knows the id it stamped.
  while IFS= read -r sid; do
    [[ "$sid" =~ ^[0-9]+$ ]] || continue
    st="$(juvant_db_query "SELECT status FROM decisions WHERE id=$sid;" \
      2>/dev/null | { grep -E '^[a-z]+$' || true; } | tail -1)"
    if [[ "$st" == "approved" ]]; then
      printf '%s' "decisions#${sid} was executed this session (JUVANT_EXECUTING_SPEC=${sid}) but its row is still 'approved'. Per ARCH-013, close it before you finish: UPDATE decisions SET status='executed', executed_by='${role:-cos}', executed_at=CURRENT_TIMESTAMP WHERE id=${sid} AND status='approved' — and set source_ref too if the category requires it (deployment/install/release/branch-protection/secret-rotation/eng-platform-spec; the schema trigger enforces this). If it was NOT actually executed, surface it to CoS instead."
      return 0
    fi
  done < <(juvant_db_query "
    SELECT DISTINCT spec_id FROM agent_actions_log
    WHERE session_id = '$sess_esc' $role_pred AND spec_id IS NOT NULL;
  " 2>/dev/null || true)

  # ── Path 2 (ADR 0028): PR-body recovery for pr-spec (needs gh + repo) ────────
  command -v gh >/dev/null 2>&1  || return 0
  gh auth status >/dev/null 2>&1 || return 0

  # Candidate PR-merge actions in this session (input_summary carries the raw
  # Bash command; role filter scopes a subagent, absent for the main thread).
  sums="$(juvant_db_query "
    SELECT input_summary FROM agent_actions_log
    WHERE session_id = '$sess_esc' $role_pred
      AND status = 'success' AND input_summary LIKE '%pr%merge%';
  " 2>/dev/null || true)"
  [[ -n "$sums" ]] || return 0   # no merge this session → nothing to gate

  # Resolve the company repo. BUG-057: if there IS a merge but the repo is
  # unresolved, WARN (never stay silent) then fail open — Layer 2 is the net.
  repo="$(jq -r '
    (.github_repos[0])
    // (if .github_repo then (.github_repo.org + "/" + .github_repo.repo_name) else "" end)
    // ""' "$cfg" 2>/dev/null || echo "")"
  if [[ -z "$repo" ]]; then
    echo "[spec-marking-gate] WARN: a PR-merge action was seen this session but .github_repos is unresolved in $cfg — ARCH-017 Layer 1 cannot gate (fail-open). Populate github_repos (ARCH-017 BUG-057, juvantlabs/juvant-os-pm#144)." >&2
    return 0
  fi

  while IFS= read -r sum; do
    [[ -n "$sum" ]] || continue
    [[ "$sum" =~ merge[^0-9]*([0-9]+) ]] || continue
    pr="${BASH_REMATCH[1]}"
    body="$(gh pr view "$pr" --repo "$repo" --json body -q '.body' 2>/dev/null || echo "")"
    while [[ "$body" =~ decisions#([0-9]+) ]]; do
      id="${BASH_REMATCH[1]}"
      body="${body//decisions#$id/ }"
      st="$(juvant_db_query \
        "SELECT status FROM decisions WHERE id=$id AND category='pr-spec';" \
        2>/dev/null | { grep -E '^[a-z]+$' || true; } | tail -1)"
      if [[ "$st" == "approved" ]]; then
        printf '%s' "decisions#${id} (pr-spec) is still 'approved' but its PR ${repo}#${pr} is merged. Per ARCH-013, close it before you finish: UPDATE decisions SET status='executed', executed_by='${role:-cos}', executed_at=<the PR merge time>, source_ref='${repo}#${pr}' WHERE id=${id} AND status='approved'. If this PR did NOT execute that spec, surface it to CoS instead — do not leave it 'approved'."
        return 0
      fi
    done
  done <<< "$sums"
  return 0
}
