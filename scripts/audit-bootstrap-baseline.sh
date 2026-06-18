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
# to inspect agents/company/*.md vs agents/projects/*.md per ARCH-009
# #42 (juvantlabs/juvant-os-pm) script scope-flag uniformity pattern.
#
# v0.8.0 (ADR 0014 §1/§2/§6): expected agent counts are now
# parameterized rather than hard-coded.
#   Company-scope (mandatory): cos cfo clo cmo cco chro cso cetho cto
#                              (9 mandatory)
#                  + eng-platform   (toggle: feature_toggles.eng_platform_enabled, default true)
#                  + cro            (toggle: feature_toggles.cro_enabled, default false)
#                  + vpe            (toggle: feature_toggles.vpe_enabled, default false)
#                  → N = 9 + 1 (default-on eng-platform) = 10 (v0.8.0 baseline).
#   Project-scope: pca product-lead design-lead eng-lead
#                  eng-api eng-backend eng-frontend eng-ai
#                  → 8 per project (v0.8.0; was 9 in v0.7 with project-VPE).
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
  local manifests_count operational_count bootstrap_decisions expected_n

  # v0.8.0 (ADR 0014 §1): expected manifesto count is parameterized
  # from feature_toggles. 9 mandatory + eng-platform (default true)
  # + cro (default false) + vpe (default false).
  expected_n=9
  if [[ "$(jq -r '.feature_toggles.eng_platform_enabled // true' "$CONFIG")" == "true" ]]; then
    expected_n=$((expected_n + 1))
  fi
  if [[ "$(jq -r '.feature_toggles.cro_enabled // false' "$CONFIG")" == "true" ]]; then
    expected_n=$((expected_n + 1))
  fi
  if [[ "$(jq -r '.feature_toggles.vpe_enabled // false' "$CONFIG")" == "true" ]]; then
    expected_n=$((expected_n + 1))
  fi

  # Cloud Turso db shell pads numeric output with column-alignment whitespace
  # (e.g. "12          "). Strip at assignment so downstream string comparisons
  # against $expected_n / "0" work correctly. Applies to all 4 count queries
  # in this layer (manifests, operational, bootstrap_decisions, action_log).
  manifests_count=$(juvant_db_query \
    "SELECT COUNT(*) FROM manifests WHERE tier1_bootstrap=1 AND precondition_bypassed='bootstrap';" \
    | tail -1 | tr -d '[:space:]')
  operational_count=$(juvant_db_query \
    "SELECT COUNT(*) FROM agents WHERE manifesto_status IN ('operational','operational_restricted') AND tier1_bootstrap=1;" \
    | tail -1 | tr -d '[:space:]')
  bootstrap_decisions=$(juvant_db_query \
    "SELECT COUNT(*) FROM decisions WHERE category='bootstrap-action' AND status='executed';" \
    | tail -1 | tr -d '[:space:]')

  if [[ "${manifests_count:-0}" == "$expected_n" ]]; then
    emit "access" "info" \
      "${expected_n} founding manifestos in OPERATIONAL_RESTRICTED with tier1_bootstrap=1 and precondition_bypassed='bootstrap' (matches feature_toggles-derived expected count)."
  else
    emit "access" "high" \
      "Expected ${expected_n} founding manifestos with tier1_bootstrap=1 (per feature_toggles); found ${manifests_count:-0}." \
      "manifesto-bootstrap-incomplete"
  fi

  if [[ "${operational_count:-0}" == "$expected_n" ]]; then
    emit "access" "info" \
      "${expected_n} agent rows mirror manifesto state (operational/operational_restricted, tier1_bootstrap=1)."
  else
    emit "access" "medium" \
      "Expected ${expected_n} agent rows mirroring manifesto state; found ${operational_count:-0}." \
      "agent-manifest-drift"
  fi

  if [[ "${bootstrap_decisions:-0}" -ge "$expected_n" ]]; then
    emit "access" "info" \
      "${bootstrap_decisions} bootstrap-action decisions executed (≥${expected_n} expected — one per founding manifesto)."
  else
    emit "access" "medium" \
      "Expected ≥${expected_n} bootstrap-action decisions; found ${bootstrap_decisions:-0}." \
      "decision-trail-incomplete"
  fi

  # Layer 5 §11 sub-rule (forward-compat): empty agent_actions_log + populated
  # security_audit_log auditor='cso' = cover-up flag. Reported here at audit
  # time so CSO sees its own pre-state.
  local action_log_count
  action_log_count=$(juvant_db_query "SELECT COUNT(*) FROM agent_actions_log;" | tail -1 | tr -d '[:space:]')
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

  # .claude/settings.json is JSONC (line comments + trailing commas
  # permitted by Claude Code's loader). Strict json.load produces false
  # FAILs on every adopter who legitimately commented their settings
  # block. Use a JSONC-tolerant pre-pass: strip `//` line comments
  # (outside strings) and trailing commas, then attempt strict parse.
  # Stdlib-only (no node/json5 dependency).
  if python3 - "$ROOT/.claude/settings.json" <<'PYEOF' 2>/dev/null; then
import json, re, sys
path = sys.argv[1]
with open(path) as fp:
    src = fp.read()
# Strip // line comments, but only when '//' is not inside a string.
out = []
i, n = 0, len(src)
in_str = False
str_ch = ""
while i < n:
    c = src[i]
    if in_str:
        out.append(c)
        if c == "\\" and i + 1 < n:
            out.append(src[i + 1]); i += 2; continue
        if c == str_ch:
            in_str = False
        i += 1; continue
    if c in ('"', "'"):
        in_str = True; str_ch = c; out.append(c); i += 1; continue
    if c == "/" and i + 1 < n and src[i + 1] == "/":
        # consume to end of line
        while i < n and src[i] != "\n":
            i += 1
        continue
    out.append(c); i += 1
stripped = "".join(out)
# Strip trailing commas before } or ]
stripped = re.sub(r",(\s*[}\]])", r"\1", stripped)
json.loads(stripped)
PYEOF
    emit "network" "info" \
      ".claude/settings.json valid JSONC (line comments + trailing commas tolerated); hook + permission registration coherent."
  else
    emit "network" "high" \
      ".claude/settings.json invalid JSONC." \
      "settings-invalid"
  fi
}

# ─────────────────────────────────────────────
# Layer 4 — Code
# ─────────────────────────────────────────────

audit_layer_4_code() {
  # CI PR-gate detection. Pre-fix the check inspected only lint.yml and
  # only for a push-to-main trigger; but some workflows are
  # legitimately workflow_dispatch-only (e.g. lint.yml in repos that
  # gate via a different workflow), and the real PR gate may live in
  # any .github/workflows/*.yml. Scan ALL workflows for a `pull_request`
  # trigger; flag CI as incomplete only when none has one.
  local workflows_dir="$ROOT/.github/workflows"
  if [[ -d "$workflows_dir" ]]; then
    local pr_trigger_files=""
    local wf
    for wf in "$workflows_dir"/*.yml "$workflows_dir"/*.yaml; do
      [[ -f "$wf" ]] || continue
      # Match `pull_request:` or `pull_request_target:` at trigger level
      # (line starts with optional indent, then the key, then `:`).
      if grep -qE '^[[:space:]]*pull_request(_target)?[[:space:]]*:' "$wf"; then
        pr_trigger_files="$pr_trigger_files $(basename "$wf")"
      fi
    done
    if [[ -n "$pr_trigger_files" ]]; then
      emit "code" "info" \
        "CI PR gate present: workflow(s)${pr_trigger_files} trigger on pull_request."
    else
      emit "code" "medium" \
        "No .github/workflows/*.yml file declares a pull_request trigger — PRs are not gated by CI." \
        "ci-trigger-incomplete"
    fi
  else
    emit "code" "high" \
      ".github/workflows/ missing — no CI gating on PRs." \
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
    # v0.8.0 (ADR 0014 §1/§2): mandatory 9 + toggle-gated 3.
    expected_agents=(cos cfo clo cmo cco chro cso cetho cto)
    if [[ "$(jq -r '.feature_toggles.eng_platform_enabled // true' "$CONFIG")" == "true" ]]; then
      expected_agents+=(eng-platform)
    fi
    if [[ "$(jq -r '.feature_toggles.cro_enabled // false' "$CONFIG")" == "true" ]]; then
      expected_agents+=(cro)
    fi
    if [[ "$(jq -r '.feature_toggles.vpe_enabled // false' "$CONFIG")" == "true" ]]; then
      expected_agents+=(vpe)
    fi
    agent_count="${#expected_agents[@]}"
    agent_set_label="founding company-scope"
    # Company-init: PROJECT_NAME may survive (no project bound yet).
    allowlist_csv="ACTIVE_PROJECT,PROJECT_NAME"
  else
    # F-31 (v0.7.3+): project-scope audit. agents/projects/*.md should
    # have been compiled by `compile-templates.sh --scope projects
    # --project=<slug>` per F-23. PROJECT_NAME is now bound; only
    # ACTIVE_PROJECT (runtime-resolved at SessionStart) survives.
    # v0.8.0 (ADR 0014 §1/§2): project-scope agents renamed; project-VPE
    # removed (absorbed by eng-lead).
    agents_dir="$ROOT/agents/projects/$SCOPE"
    expected_agents=(pca product-lead design-lead eng-lead eng-api eng-backend eng-frontend eng-ai)
    agent_count=8
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
      (( survivors_found += 1 ))
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

  # BUG-029: detect duplicate name: values across .claude/agents/ — multi-project
  # collision where two compiled project-agent files share the same unqualified
  # name: field (e.g. both resolve to name: design-lead). Non-deterministic
  # subagent_type resolution; surfaces silently when ≥2 projects are active.
  local dup_names
  dup_names=$(grep -rh '^name:' "$agents_dir"/*.md 2>/dev/null | sort | uniq -d | tr -d ' ' | sed 's/^name://' | tr '\n' ' ')
  if [[ -n "$dup_names" ]]; then
    emit "agents" "high" \
      "Duplicate agent name: field detected across .claude/agents/ — non-deterministic subagent_type resolution for: ${dup_names}. Re-run compile-templates.sh --scope projects for each slug (BUG-029)." \
      "duplicate-agent-name"
  else
    emit "agents" "info" \
      "No duplicate name: fields in compiled agent files — subagent_type resolution is deterministic."
  fi

  # eng-platform / vpe / cro toggle-coherence checks (company-scope only).
  # v0.8.0 (ADR 0014 §1/§2): for each optional role, confirm the file
  # presence + agent_tool_matrix row state matches the toggle.
  if [[ "$SCOPE" == "company" ]]; then
    for optional_role in eng-platform cro vpe; do
      local toggle_key default_value enabled
      case "$optional_role" in
        eng-platform) toggle_key="eng_platform_enabled"; default_value="true" ;;
        cro)          toggle_key="cro_enabled";          default_value="false" ;;
        vpe)          toggle_key="vpe_enabled";          default_value="false" ;;
      esac
      enabled=$(jq -r --arg k "$toggle_key" --arg d "$default_value" '.feature_toggles[$k] // $d' "$CONFIG")

      local in_matrix
      in_matrix=$(juvant_db_query \
        "SELECT COUNT(*) FROM agent_tool_matrix WHERE role='$optional_role' AND superseded_by IS NULL;" | tail -1)

      if [[ "$enabled" == "true" ]]; then
        if [[ -f "$agents_dir/${optional_role}.md" && "${in_matrix:-0}" -ge 1 ]]; then
          emit "agents" "info" \
            "Optional role '${optional_role}' enabled (feature_toggles.${toggle_key}=true): file + matrix row both present."
        else
          emit "agents" "high" \
            "Optional role '${optional_role}' enabled (feature_toggles.${toggle_key}=true) but file missing or matrix row missing (file=$([[ -f \"$agents_dir/${optional_role}.md\" ]] && echo present || echo missing), matrix=${in_matrix:-0})." \
            "optional-role-toggle-mismatch"
        fi
      else
        if [[ -f "$agents_dir/${optional_role}.md" || "${in_matrix:-0}" -ge 1 ]]; then
          emit "agents" "low" \
            "Optional role '${optional_role}' disabled (feature_toggles.${toggle_key}=false) but file present or matrix row exists (file=$([[ -f \"$agents_dir/${optional_role}.md\" ]] && echo present || echo missing), matrix=${in_matrix:-0}). Toggle-gating expects neither when disabled." \
            "optional-role-toggle-leak"
        fi
      fi
    done
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
