#!/usr/bin/env bash
# hooks/subagent-stop.sh
# Claude Code hook: SubagentStop
# Called when a subagent (nested agent) stops within a session.
# Logs deactivation to the agents table AND inserts a token-usage row
# for the subagent invocation (FEAT-024).
#
# stdin: JSON event with subagent type, session_id, transcript_path.
# Format: {"agent_type":"...","session_id":"...","transcript_path":"..."}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read event from stdin
EVENT_JSON=""
# Claude Code delivers the event JSON on stdin as a REDIRECT, not necessarily
# a named pipe — the old `[ -p /dev/stdin ]` guard was false for a redirect,
# so the event was never read (session_id lost; the hook silently no-op'd).
# Read whenever stdin is not a terminal, bounded by a 2s read timeout so a
# non-EOF stdin can never hang the hook (no `timeout(1)` dep — absent on macOS).
if [ ! -t 0 ]; then
  IFS= read -r -d "" -t 2 EVENT_JSON 2>/dev/null || true
fi

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/db.sh"
juvant_db_resolve

if [[ -z "$JUVANT_DB_PROVIDER" ]]; then
  exit 0
fi

# Cloud-provider env propagation for track-tokens.sh.
if [[ -n "${JUVANT_DB_URL:-}" ]]; then
  export TURSO_URL="$JUVANT_DB_URL"
fi
if [[ -n "${JUVANT_DB_TOKEN:-}" ]]; then
  export TURSO_TOKEN="$JUVANT_DB_TOKEN"
fi

SUBAGENT_ROLE=""
PARENT_SESSION_ID=""
TRANSCRIPT=""
if [[ -n "$EVENT_JSON" ]] && command -v jq &>/dev/null; then
  SUBAGENT_ROLE=$(echo "$EVENT_JSON"     | jq -r '.agent_type // ""' 2>/dev/null || echo "")
  PARENT_SESSION_ID=$(echo "$EVENT_JSON" | jq -r '.session_id // ""' 2>/dev/null || echo "")
  TRANSCRIPT=$(echo "$EVENT_JSON"        | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
fi
SUBAGENT_ROLE="${SUBAGENT_ROLE:-${AGENT_ROLE:-unknown}}"

NOW=$(date -u +"%Y-%m-%d %H:%M:%S")
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
ROLE_ESC=$(sql_escape "$SUBAGENT_ROLE")

juvant_db_exec \
  "UPDATE agents SET status='inactive', updated_at='$NOW' WHERE role='$ROLE_ESC';" \
  || true

# FEAT-024 — record subagent invocation token usage.
if [[ -n "$TRANSCRIPT" && -n "$PARENT_SESSION_ID" && -f "$SCRIPT_DIR/lib/track-tokens.sh" ]]; then
  PRINCIPAL_ID="${JUVANT_PRINCIPAL:-}"
  PROJECT_SLUG="${JUVANT_ACTIVE_PROJECT:-}"
  STARTED_AT="${SUBAGENT_STARTED_AT:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
  ENDED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/lib/track-tokens.sh"
  track_subagent_invocation \
    "$TRANSCRIPT" "$PARENT_SESSION_ID" "$SUBAGENT_ROLE" \
    "$STARTED_AT" "$ENDED_AT" \
    "$PRINCIPAL_ID" "$PROJECT_SLUG" \
    || true
fi

# ── Layer 1 (ADR 0028 / ARCH-017): capture-at-execution gate ────────────────
# If this subagent merged a PR THIS session whose body references an approved,
# still-unmarked pr-spec (`decisions#<id>`, the D2 link), block the stop with a
# SATISFIABLE, self-remediating instruction to close the row before finishing.
# Fires ONLY on a concrete, recovered PR→spec link, so it can never deadlock;
# fail-open on missing gh / repo / link / any error → Layer 2 remains the net.
#
# NOTE (ARCH-017, honesty per the BUG-053 lesson): CC's *honoring* of a
# SubagentStop block is NOT verified from the framework repo. This ships the
# decision LOGIC (unit-tested); enforcement must be confirmed by a live probe
# in a real instance before it is trusted. Until then it is advisory and the
# Layer-2 reconciler is the guarantee.
_L1_CONFIG="${JUVANT_CONFIG:-$SCRIPT_DIR/../.juvant/config.json}"
_L1_BLOCK=""
if [[ -n "$PARENT_SESSION_ID" && "$SUBAGENT_ROLE" != "unknown" ]] \
   && [[ -f "$_L1_CONFIG" ]] \
   && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  _L1_REPO=$(jq -r '
    (.github_repos[0])
    // (if .github_repo then (.github_repo.org + "/" + .github_repo.repo_name) else "" end)
    // ""' "$_L1_CONFIG" 2>/dev/null || echo "")
  _L1_SESS_ESC=$(sql_escape "$PARENT_SESSION_ID")
  if [[ -n "$_L1_REPO" ]]; then
    while IFS= read -r _L1_SUM; do
      [[ -n "$_L1_SUM" ]] || continue
      # input_summary carries the raw Bash command (pre-tool-use, ≤200 chars).
      # Extract the first integer following `… merge` as the PR number.
      [[ "$_L1_SUM" =~ merge[^0-9]*([0-9]+) ]] || continue
      _L1_PR="${BASH_REMATCH[1]}"
      _L1_BODY=$(gh pr view "$_L1_PR" --repo "$_L1_REPO" --json body -q '.body' 2>/dev/null || echo "")
      # Consume each `decisions#<id>` reference in the PR body.
      while [[ "$_L1_BODY" =~ decisions#([0-9]+) ]]; do
        _L1_ID="${BASH_REMATCH[1]}"
        _L1_BODY="${_L1_BODY//decisions#$_L1_ID/ }"
        _L1_ST=$(juvant_db_query \
          "SELECT status FROM decisions WHERE id=$_L1_ID AND category='pr-spec';" \
          2>/dev/null | { grep -E '^[a-z]+$' || true; } | tail -1)
        if [[ "$_L1_ST" == "approved" ]]; then
          _L1_BLOCK="decisions#${_L1_ID} (pr-spec) is still 'approved' but its PR ${_L1_REPO}#${_L1_PR} is merged. Per ARCH-013, close it before you finish: UPDATE decisions SET status='executed', executed_by='${SUBAGENT_ROLE}', executed_at=<the PR merge time>, source_ref='${_L1_REPO}#${_L1_PR}' WHERE id=${_L1_ID} AND status='approved'. If this PR did NOT execute that spec, surface it to CoS instead — do not leave it 'approved'."
          break
        fi
      done
      [[ -n "$_L1_BLOCK" ]] && break
    done < <(juvant_db_query "
      SELECT input_summary FROM agent_actions_log
      WHERE agent = '$ROLE_ESC' AND session_id = '$_L1_SESS_ESC'
        AND status = 'success' AND input_summary LIKE '%pr%merge%';
    " 2>/dev/null || true)
  fi
fi

if [[ -n "$_L1_BLOCK" ]]; then
  # SubagentStop block: JSON decision on stdout + exit 2 with the reason on
  # stderr — defense-in-depth across CC's two documented block channels
  # (the BUG-053 lesson: emit both; do not assume one form is honored).
  jq -nc --arg r "$_L1_BLOCK" '{decision:"block", reason:$r}' 2>/dev/null \
    || printf '{"decision":"block","reason":"spec-marking gate: an approved pr-spec is unmarked after its PR merged"}\n'
  echo "$_L1_BLOCK" >&2
  exit 2
fi

exit 0
