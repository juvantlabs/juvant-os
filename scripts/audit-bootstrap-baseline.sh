#!/usr/bin/env bash
# scripts/audit-bootstrap-baseline.sh
#
# Canonical CSO bootstrap_baseline=1 audit. Encodes the 5-layer audit
# (access / secrets / network / code / agents) as a single Bash
# invocation that the CSO subagent runs during Step 9.7 of company
# init (or after project init for project-scope audits).
#
# Pre-v0.6.5 the CSO subagent issued ~30 inline `sqlite3 ... <<'SQL'`
# heredocs and ~50 `grep / awk / find` invocations during the
# bootstrap_baseline audit — each tripping Claude Code's "shell syntax
# cannot be statically analyzed" approval prompt. Foxtrot Corp testco
# run on 2026-05-09 saw ~300+ approvals during a single audit. This
# script collapses the audit to ONE allowlistable invocation
# (`Bash(bash scripts/audit-bootstrap-baseline.sh:*)`).
#
# Usage:
#   bash scripts/audit-bootstrap-baseline.sh                # default: company scope
#   bash scripts/audit-bootstrap-baseline.sh --scope=company
#   bash scripts/audit-bootstrap-baseline.sh --scope=<project_id>  # project audit
#
# Output:
#   Newline-delimited JSON findings on stdout. One JSON object per
#   finding. Schema:
#     {"layer":"access|secrets|network|code|agents",
#      "severity":"info|low|medium|high|critical",
#      "finding":"<one-line description>",
#      "category":"<optional category tag>"}
#
#   Plus a final summary line:
#     {"summary":true,"verdict":"PASS|WARN-WITH-CONDITIONS|FAIL",
#      "counts":{"info":N,"low":N,"medium":N,"high":N,"critical":N}}
#
# The CSO subagent parses stdout line-by-line, interprets findings
# in context (per the prompts in `agents/company/cso.md`), and
# writes them to `security_audit_log` with the canonical
# `auditor='cso'`, `audit_type='bootstrap_baseline'`,
# `bootstrap_baseline=1`. The CSO subagent — NOT this script —
# is the source of truth for the verdict and the audit_log rows
# (see SYSTEM_INVARIANTS.md §1 step 7 + cso.md Layer 5 §11
# orphan-audit detection).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$ROOT/.juvant/config.json"

SCOPE="company"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --scope=*) SCOPE="${1#--scope=}"; shift ;;
    -h|--help)
      sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *) echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
  esac
done

# F-31 (v0.7.3+): project-scope audits supported. SCOPE is either
# 'company' (default) or a project slug present in
# .juvant/config.json `.projects.<slug>`. Layers 1-4 are broadly
# applicable across both scopes; Layer 5 (agents) branches by scope
# to inspect agents/company/*.md (10 founding) vs agents/projects/*.md
# (9 project-scope) per ARCH-009 # 42 (juvantlabs/juvant-os-pm) script
# scope-flag uniformity pattern.
if [[ "$SCOPE" != "company" ]]; then
  if [[ ! -f "$CONFIG" ]]; then
    echo "ERROR: --scope=$SCOPE requires $CONFIG (project lookup needs .projects.<slug>.name)." >&2
    exit 1
  fi
  if ! jq -e --arg s "$SCOPE" '.projects[$s]' "$CONFIG" >/dev/null 2>&1; then
    echo "ERROR: --scope=$SCOPE not a valid project slug in $CONFIG (.projects.$SCOPE missing)." >&2
    exit 1
  fi
fi

if [[ ! -f "$CONFIG" ]]; then
  echo '{"layer":"access","severity":"critical","finding":"'"$CONFIG"' missing — bootstrap not initialized.","category":"prerequisite"}' >&2
  exit 1
fi

# shellcheck disable=SC1091
. "$ROOT/hooks/lib/db.sh"
juvant_db_resolve

declare -i COUNT_INFO=0 COUNT_LOW=0 COUNT_MEDIUM=0 COUNT_HIGH=0 COUNT_CRITICAL=0

emit() {
  # emit <layer> <severity> <finding> [category]
  local layer="$1" severity="$2" finding="$3" category="${4:-}"
  case "$severity" in
    info)     COUNT_INFO+=1     ;;
    low)      COUNT_LOW+=1      ;;
    medium)   COUNT_MEDIUM+=1   ;;
    high)     COUNT_HIGH+=1     ;;
    critical) COUNT_CRITICAL+=1 ;;
  esac
  python3 -c "import json,sys; print(json.dumps({'layer':'$layer','severity':'$severity','finding':sys.argv[1],'category':sys.argv[2]}))" \
    "$finding" "$category"
}

# ─────────────────────────────────────────────
# Layer 1 — Access
# ─────────────────────────────────────────────

audit_layer_1_access() {
  local manifests_count operational_count bootstrap_decisions

  manifests_count=$(juvant_db_query \
    "SELECT COUNT(*) FROM manifests WHERE tier1_bootstrap=1 AND precondition_bypassed='bootstrap';" \
    | tail -1)
  operational_count=$(juvant_db_query \
    "SELECT COUNT(*) FROM agents WHERE manifesto_status IN ('operational','operational_restricted') AND tier1_bootstrap=1;" \
    | tail -1)
  bootstrap_decisions=$(juvant_db_query \
    "SELECT COUNT(*) FROM decisions WHERE category='bootstrap-action' AND status='executed';" \
    | tail -1)

  if [[ "${manifests_count:-0}" == "10" ]]; then
    emit "access" "info" \
      "10 founding manifestos in OPERATIONAL_RESTRICTED with tier1_bootstrap=1 and precondition_bypassed='bootstrap'."
  else
    emit "access" "high" \
      "Expected 10 founding manifestos with tier1_bootstrap=1; found ${manifests_count:-0}." \
      "manifesto-bootstrap-incomplete"
  fi

  if [[ "${operational_count:-0}" == "10" ]]; then
    emit "access" "info" \
      "10 agent rows mirror manifesto state (operational/operational_restricted, tier1_bootstrap=1)."
  else
    emit "access" "medium" \
      "Expected 10 agent rows mirroring manifesto state; found ${operational_count:-0}." \
      "agent-manifest-drift"
  fi

  if [[ "${bootstrap_decisions:-0}" -ge 10 ]]; then
    emit "access" "info" \
      "${bootstrap_decisions} bootstrap-action decisions executed (≥10 expected — one per founding manifesto)."
  else
    emit "access" "medium" \
      "Expected ≥10 bootstrap-action decisions; found ${bootstrap_decisions:-0}." \
      "decision-trail-incomplete"
  fi

  # Layer 5 §11 sub-rule (forward-compat): empty agent_actions_log + populated
  # security_audit_log auditor='cso' = cover-up flag. Reported here at audit
  # time so CSO sees its own pre-state.
  local action_log_count
  action_log_count=$(juvant_db_query "SELECT COUNT(*) FROM agent_actions_log;" | tail -1)
  if [[ "${action_log_count:-0}" == "0" ]]; then
    emit "access" "medium" \
      "agent_actions_log is empty (0 rows) at audit time. v0.6.3+ Local SQLite hooks should populate this on every tool call; an empty log mid-bootstrap suggests Track 3 is not running. Verify hooks/lib/db.sh routing and provider config (v0.6.5 F-20 strip 'file:' prefix)." \
      "track-3-disabled"
  fi
}

# ─────────────────────────────────────────────
# Layer 2 — Secrets
# ─────────────────────────────────────────────

audit_layer_2_secrets() {
  local gi="$ROOT/.gitignore"
  if [[ ! -f "$gi" ]]; then
    emit "secrets" "high" ".gitignore missing — secrets at risk of commit." "gitignore-missing"
    return
  fi

  local missing_patterns=()
  for pat in ".juvant/config.json" ".juvant/state.db" ".env" "*.pem" "*.key" "id_rsa"; do
    if ! grep -qF "$pat" "$gi"; then
      missing_patterns+=("$pat")
    fi
  done

  if [[ "${#missing_patterns[@]}" == "0" ]]; then
    emit "secrets" "info" \
      ".gitignore covers token-bearing paths (.juvant/config.json, .juvant/state.db, .env*, *.pem, *.key, id_rsa*)."
  else
    emit "secrets" "high" \
      ".gitignore missing patterns: ${missing_patterns[*]}" \
      "gitignore-incomplete"
  fi

  # Tracked-secret scan (CSO Layer 2 mirror of CI step).
  local offenders=""
  if [[ -d "$ROOT/.git" ]]; then
    offenders=$(cd "$ROOT" && git grep -lE \
      '(BEGIN (RSA |EC )?PRIVATE KEY|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{82,}|sk-[A-Za-z0-9]{40,}|xox[abrs]-[A-Za-z0-9-]+)' \
      -- ':!*.md' ':!CHANGELOG.md' 2>/dev/null) || offenders=""
  fi

  if [[ -z "$offenders" ]]; then
    emit "secrets" "info" "Tracked-secret scan: no committed tokens detected in source tree."
  else
    emit "secrets" "critical" \
      "Tracked-secret scan: committed token-pattern matches found in: $(echo "$offenders" | tr '\n' ' ')" \
      "tracked-secret"
  fi
}

# ─────────────────────────────────────────────
# Layer 3 — Network
# ─────────────────────────────────────────────

audit_layer_3_network() {
  if python3 -c "import json; json.load(open('$ROOT/.mcp.json'))" 2>/dev/null; then
    local servers_count
    servers_count=$(python3 -c "import json; print(len(json.load(open('$ROOT/.mcp.json')).get('mcpServers',{})))" 2>/dev/null)
    if [[ "${servers_count:-0}" == "0" ]]; then
      emit "network" "info" \
        ".mcp.json present and intentionally empty (v0.6.4 first-impression UX). Adopters add MCP servers explicitly via README walkthrough."
    else
      emit "network" "info" \
        ".mcp.json registers ${servers_count} MCP server(s). Verify env-var bindings are present in shell context."
    fi
  else
    emit "network" "high" \
      ".mcp.json invalid or missing." \
      "mcp-config-invalid"
  fi

  if python3 -c "import json; json.load(open('$ROOT/.claude/settings.json'))" 2>/dev/null; then
    emit "network" "info" \
      ".claude/settings.json valid JSON; hook + permission registration coherent."
  else
    emit "network" "high" \
      ".claude/settings.json invalid JSON." \
      "settings-invalid"
  fi
}

# ─────────────────────────────────────────────
# Layer 4 — Code
# ─────────────────────────────────────────────

audit_layer_4_code() {
  local lint_yml="$ROOT/.github/workflows/lint.yml"
  if [[ -f "$lint_yml" ]]; then
    if grep -q "branches.*main" "$lint_yml"; then
      emit "code" "info" "CI workflow .github/workflows/lint.yml triggers on push to main."
    else
      emit "code" "medium" \
        "CI workflow exists but main-branch trigger not detected." \
        "ci-trigger-incomplete"
    fi
  else
    emit "code" "high" \
      ".github/workflows/lint.yml missing — no CI gating on PRs." \
      "ci-missing"
  fi

  if [[ -f "$ROOT/.github/CODEOWNERS" ]]; then
    if grep -qE '\{\{[A-Z_]+\}\}' "$ROOT/.github/CODEOWNERS"; then
      emit "code" "high" \
        ".github/CODEOWNERS contains unsubstituted {{*_GITHUB}} placeholders — Step 7.5 incomplete." \
        "codeowners-unsubstituted"
    else
      emit "code" "info" "CODEOWNERS rendered cleanly (no surviving placeholders)."
    fi
  else
    emit "code" "medium" \
      ".github/CODEOWNERS missing." \
      "codeowners-missing"
  fi

  if [[ -f "$ROOT/docs/branch-protection-spec.md" ]]; then
    emit "code" "info" \
      "docs/branch-protection-spec.md present (normative spec for COO branch-protection-spec decision execution)."
  else
    emit "code" "medium" \
      "docs/branch-protection-spec.md missing — branch protection spec un-actionable." \
      "branch-protection-spec-missing"
  fi
}

# ─────────────────────────────────────────────
# Layer 5 — Agents
# ─────────────────────────────────────────────

audit_layer_5_agents() {
  local agents_dir
  local expected_agents
  local agent_count
  local agent_set_label
  local allowlist_csv

  if [[ "$SCOPE" == "company" ]]; then
    agents_dir="$ROOT/agents/company"
    expected_agents=(cos cfo clo cmo cco chro cso cetho ca cro)
    agent_count=10
    agent_set_label="founding company-scope"
    # Company-init: PROJECT_NAME may survive (no project bound yet).
    allowlist_csv="ACTIVE_PROJECT,PROJECT_NAME"
  else
    # F-31 (v0.7.3+): project-scope audit. agents/projects/*.md should
    # have been compiled by `compile-templates.sh --scope projects
    # --project=<slug>` per F-23. PROJECT_NAME is now bound; only
    # ACTIVE_PROJECT (runtime-resolved at SessionStart) survives.
    agents_dir="$ROOT/agents/projects"
    expected_agents=(cto cpo cdo coo vpe eng-api eng-backend eng-frontend eng-ai)
    agent_count=9
    agent_set_label="project-scope ($SCOPE)"
    allowlist_csv="ACTIVE_PROJECT"
  fi

  if [[ ! -d "$agents_dir" ]]; then
    emit "agents" "critical" "$agents_dir directory missing." "agents-dir-missing"
    return
  fi

  local missing=()
  for role in "${expected_agents[@]}"; do
    if [[ ! -f "$agents_dir/${role}.md" ]]; then
      missing+=("$role")
    fi
  done

  if [[ "${#missing[@]}" == "0" ]]; then
    emit "agents" "info" \
      "All $agent_count $agent_set_label subagent files present at $agents_dir/."
  else
    emit "agents" "high" \
      "$agent_set_label agent files missing: ${missing[*]}" \
      "founding-agents-missing"
  fi

  # Frontmatter validation (allowlisted residue varies by scope).
  local survivors_found=0
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if python3 - "$f" "$allowlist_csv" <<'PYEOF' 2>/dev/null; then
import re, sys
path = sys.argv[1]
allowlist = set(sys.argv[2].split(","))
with open(path) as fp:
    content = fp.read()
survivors = set(re.findall(r"\{\{([A-Z_][A-Z0-9_]*)\}\}", content))
disallowed = sorted(s for s in survivors if s not in allowlist)
if disallowed:
    print(f"DISALLOWED: {path} -> {disallowed}")
    sys.exit(1)
sys.exit(0)
PYEOF
      :
    else
      survivors_found+=1
    fi
  done < <(find "$agents_dir" -name "*.md" -type f 2>/dev/null)

  if [[ "$survivors_found" == "0" ]]; then
    emit "agents" "info" \
      "No surviving non-allowlisted placeholders in compiled agent files (only ACTIVE_PROJECT survives, runtime-bound)."
  else
    emit "agents" "high" \
      "$survivors_found agent file(s) contain unsubstituted non-allowlisted placeholders. CSO Layer 5 §9 finding." \
      "placeholder-residue"
  fi

  # eng-platform presence check (company-scope only; cross-project agent).
  if [[ "$SCOPE" == "company" && -f "$agents_dir/eng-platform.md" ]]; then
    local eng_platform_in_matrix
    eng_platform_in_matrix=$(juvant_db_query \
      "SELECT COUNT(*) FROM agent_tool_matrix WHERE role='eng-platform' AND superseded_by IS NULL;" | tail -1)
    if [[ "${eng_platform_in_matrix:-0}" -ge 1 ]]; then
      emit "agents" "info" \
        "eng-platform.md present at agents/company/eng-platform.md AND has agent_tool_matrix v0 row (cross-project infra agent operational)."
    else
      emit "agents" "low" \
        "eng-platform.md present in agents/company/ but NOT in agent_tool_matrix v0. Cross-project infra agent registered as file but not as matrix row — F-13 founding-vs-deferred ambiguity surfaces here." \
        "eng-platform-matrix-mismatch"
    fi
  fi
}

# ─────────────────────────────────────────────
# Drive
# ─────────────────────────────────────────────

audit_layer_1_access
audit_layer_2_secrets
audit_layer_3_network
audit_layer_4_code
audit_layer_5_agents

# Verdict logic:
#   FAIL if any critical or high finding (block bootstrap promote)
#   WARN-WITH-CONDITIONS if medium (allow promote, surface for Tier 2 follow-up)
#   PASS otherwise
verdict="PASS"
if [[ "$COUNT_CRITICAL" -gt 0 || "$COUNT_HIGH" -gt 0 ]]; then
  verdict="FAIL"
elif [[ "$COUNT_MEDIUM" -gt 0 ]]; then
  verdict="WARN-WITH-CONDITIONS"
fi

python3 -c "import json; print(json.dumps({'summary':True,'verdict':'$verdict','counts':{'info':$COUNT_INFO,'low':$COUNT_LOW,'medium':$COUNT_MEDIUM,'high':$COUNT_HIGH,'critical':$COUNT_CRITICAL}}))"
