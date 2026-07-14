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

  local hooks_dir cfg spool repo sums sum pr body id st sess_esc role_pred
  hooks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cfg="${JUVANT_CONFIG:-$hooks_dir/../.juvant/config.json}"
  [[ -f "$cfg" ]]                 || return 0
  command -v jq >/dev/null 2>&1   || return 0
  command -v gh >/dev/null 2>&1   || return 0
  gh auth status >/dev/null 2>&1  || return 0

  # BUG-058: the triggering merge is written to the FEAT-051 async audit spool, so
  # it may not be in agent_actions_log yet at stop time. Drain first so a merge
  # that just happened is guaranteed visible to the query below. Scoped tightly —
  # only when the spool actually holds a merge action — so a per-turn Stop hook
  # does not pay a drain on the common (no-merge) path. The drainer is idempotent
  # + crash-safe, so an occasional false-positive drain is harmless.
  spool="$(juvant_spool_path 2>/dev/null || echo "")"
  if [[ -n "$spool" && -s "$spool" ]] && grep -qi 'merge' "$spool" 2>/dev/null; then
    bash "$hooks_dir/../helpers/drain-audit-spool.sh" >/dev/null 2>&1 || true
  fi

  sess_esc="$(printf '%s' "$session_id" | sed "s/'/''/g")"
  role_pred=""
  if [[ -n "$role" && "$role" != "unknown" ]]; then
    role_pred="AND agent = '$(printf '%s' "$role" | sed "s/'/''/g")'"
  fi

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
