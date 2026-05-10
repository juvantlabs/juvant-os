#!/usr/bin/env bash
# scripts/compile-templates.sh
#
# Substitute {{PLACEHOLDER}} tokens in agent templates from values in
# `.juvant/config.json`. The wizard's Step 7 procedure runs this script.
# Pre-v0.6.4, every wizard pass improvised an ad-hoc Python helper at a
# different path (5 different paths across 5 testco runs); shipping a
# canonical Bash script eliminates that drift, makes the operation
# deterministic across Skill sessions, and pre-allowlistable in
# `.claude/settings.json` (so adopters don't get prompted for each
# heredoc — finding F-6 + F-7 + F-8 family in the v0.6.4 backlog).
#
# Usage:
#   scripts/compile-templates.sh                              # default: company scope
#   scripts/compile-templates.sh --scope company
#   scripts/compile-templates.sh --scope projects --project=<slug>
#                                                             # at project init
#   scripts/compile-templates.sh --codeowners                 # render .github/CODEOWNERS
#   scripts/compile-templates.sh --rewrite-meta               # README/CHANGELOG/SECURITY/docs-adr-stub
#   scripts/compile-templates.sh --check-only                 # dry-run; report leftover placeholders
#
# Exit codes:
#   0   success — all targeted files compiled, only allowlisted placeholders survive
#   1   missing config / unsupported provider / no jq / project slug not resolved
#   2   surviving non-allowlisted placeholder (CSO Layer 5 finding) — refuse to write
#
# Allowlist behavior (F-23, v0.7.x):
# - --scope company → ALLOWLIST = ACTIVE_PROJECT|PROJECT_NAME (both
#   survive: ACTIVE_PROJECT bound at SessionStart per Boot Mode,
#   PROJECT_NAME bound later at project init).
# - --scope projects --project=<slug> → ALLOWLIST = ACTIVE_PROJECT only;
#   PROJECT_NAME is substituted with the resolved project's display
#   name. Project-scope agent name placeholders ({{CTO_NAME}}, {{CPO_NAME}},
#   {{CDO_NAME}}, {{COO_NAME}}, {{VPE_NAME}}, {{ENG_API_NAME}},
#   {{ENG_BACKEND_NAME}}, {{ENG_FRONTEND_NAME}}, {{ENG_AI_NAME}}) are
#   substituted from .juvant/config.json projects.<slug>.agent_names.<role>
#   with default fallback "<slug>-<role>" (e.g. apollo-cto).
# Any other surviving {{...}} aborts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$ROOT/.juvant/config.json"

SCOPE="company"
DO_CODEOWNERS=0
CHECK_ONLY=0
DO_REWRITE_META=0
PROJECT_SLUG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --scope=*) SCOPE="${1#--scope=}"; shift ;;
    --project) PROJECT_SLUG="$2"; shift 2 ;;
    --project=*) PROJECT_SLUG="${1#--project=}"; shift ;;
    --codeowners) DO_CODEOWNERS=1; shift ;;
    --rewrite-meta) DO_REWRITE_META=1; shift ;;
    --check-only) CHECK_ONLY=1; shift ;;
    -h|--help)
      sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *) echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: $CONFIG not found. Run JUVANT_OS.md wizard Step 1 first." >&2
  exit 1
fi
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq required but not found. Install with: brew install jq" >&2
  exit 1
fi

# ─────────────────────────────────────────────
# Resolve substitutions from .juvant/config.json + SYSTEM_INVARIANTS.md §2 defaults
# ─────────────────────────────────────────────

# Identity (Step 1)
COMPANY_NAME=$(jq -r '.company.name // empty' "$CONFIG")
COMPANY_NAME_SLUG=$(jq -r '.company.slug // empty' "$CONFIG")
COMPANY_DOMAIN=$(jq -r '.company.domain // empty' "$CONFIG")
COMPANY_DESCRIPTION=$(jq -r '.company.description // empty' "$CONFIG")
CEO_NAME=$(jq -r '.ceo.name // empty' "$CONFIG")

# Per-agent names (Step 6 — §2 defaults if not overridden in config)
agent_name() {
  local role="$1"
  local default="$2"
  local v
  v=$(jq -r --arg r "$role" '.agent_names[$r] // empty' "$CONFIG")
  echo "${v:-$default}"
}
COS_NAME=$(agent_name cos Atlas)
CFO_NAME=$(agent_name cfo Theos)
CLO_NAME=$(agent_name clo Lex)
CMO_NAME=$(agent_name cmo Mira)
CCO_NAME=$(agent_name cco Clio)
CHRO_NAME=$(agent_name chro Sage)
CSO_NAME=$(agent_name cso Shield)
CETHO_NAME=$(agent_name cetho Vera)
CA_NAME=$(agent_name ca Arch)
CRO_NAME=$(agent_name cro Lumen)
ENG_PLATFORM_NAME=$(agent_name eng-platform Hephaestus)

# Project-scope agent names + project metadata (Step 3 of project-init).
# Read from .juvant/config.json `projects.<slug>` only when --scope projects
# is invoked with --project=<slug>. For company-scope, these stay empty.
project_agent_name() {
  local slug="$1"
  local role="$2"
  local default="$3"
  local v
  v=$(jq -r --arg s "$slug" --arg r "$role" '.projects[$s].agent_names[$r] // empty' "$CONFIG")
  echo "${v:-$default}"
}
PROJECT_NAME=""
PROJECT_NAME_SLUG=""
CTO_NAME=""
CPO_NAME=""
CDO_NAME=""
COO_NAME=""
VPE_NAME=""
ENG_API_NAME=""
ENG_BACKEND_NAME=""
ENG_FRONTEND_NAME=""
ENG_AI_NAME=""
if [[ "$SCOPE" == "projects" ]]; then
  # Resolve PROJECT_SLUG from --project flag, or from config.active_project,
  # or from a single project entry if exactly one exists.
  if [[ -z "$PROJECT_SLUG" ]]; then
    PROJECT_SLUG=$(jq -r '.active_project // empty' "$CONFIG")
  fi
  if [[ -z "$PROJECT_SLUG" ]]; then
    only=$(jq -r '.projects // {} | keys | if length == 1 then .[0] else "" end' "$CONFIG")
    [[ -n "$only" ]] && PROJECT_SLUG="$only"
  fi
  if [[ -z "$PROJECT_SLUG" ]]; then
    echo "ERROR: --scope projects requires --project=<slug> (or .active_project / single .projects entry in $CONFIG)." >&2
    exit 1
  fi
  PROJECT_NAME=$(jq -r --arg s "$PROJECT_SLUG" '.projects[$s].name // empty' "$CONFIG")
  PROJECT_NAME_SLUG="$PROJECT_SLUG"
  if [[ -z "$PROJECT_NAME" ]]; then
    # Fallback: if .projects.<slug>.name is missing, derive a Title-cased
    # display name from the slug (apollo → "Apollo"). Schemas pre-F-23
    # (v0.7.0) didn't always write .name; this fallback lets the script
    # succeed against partial configs while the wizard catches up.
    if jq -e --arg s "$PROJECT_SLUG" '.projects[$s]' "$CONFIG" >/dev/null; then
      PROJECT_NAME=$(echo "$PROJECT_SLUG" | awk -F'-' '{ for (i=1;i<=NF;i++) $i = toupper(substr($i,1,1)) substr($i,2); print }' OFS=' ')
      echo "WARN: .projects.$PROJECT_SLUG.name missing in $CONFIG; derived '$PROJECT_NAME' from slug." >&2
    else
      echo "ERROR: project '$PROJECT_SLUG' not found in $CONFIG (.projects.$PROJECT_SLUG missing)." >&2
      exit 1
    fi
  fi
  CTO_NAME=$(project_agent_name "$PROJECT_SLUG" cto "$PROJECT_SLUG-cto")
  CPO_NAME=$(project_agent_name "$PROJECT_SLUG" cpo "$PROJECT_SLUG-cpo")
  CDO_NAME=$(project_agent_name "$PROJECT_SLUG" cdo "$PROJECT_SLUG-cdo")
  COO_NAME=$(project_agent_name "$PROJECT_SLUG" coo "$PROJECT_SLUG-coo")
  VPE_NAME=$(project_agent_name "$PROJECT_SLUG" vpe "$PROJECT_SLUG-vpe")
  ENG_API_NAME=$(project_agent_name "$PROJECT_SLUG" eng-api "$PROJECT_SLUG-eng-api")
  ENG_BACKEND_NAME=$(project_agent_name "$PROJECT_SLUG" eng-backend "$PROJECT_SLUG-eng-backend")
  ENG_FRONTEND_NAME=$(project_agent_name "$PROJECT_SLUG" eng-frontend "$PROJECT_SLUG-eng-frontend")
  ENG_AI_NAME=$(project_agent_name "$PROJECT_SLUG" eng-ai "$PROJECT_SLUG-eng-ai")
fi

# GitHub user map (Step 1.6 — single CEO handle by default)
github_handle() {
  local role="$1"
  jq -r --arg r "$role" '.github_user_map[$r] // .ceo.github // empty' "$CONFIG"
}
CEO_GITHUB=$(github_handle ceo)
COS_GITHUB=$(github_handle cos)
CFO_GITHUB=$(github_handle cfo)
CLO_GITHUB=$(github_handle clo)
CMO_GITHUB=$(github_handle cmo)
CCO_GITHUB=$(github_handle cco)
CHRO_GITHUB=$(github_handle chro)
CSO_GITHUB=$(github_handle cso)
CETHO_GITHUB=$(github_handle cetho)
CA_GITHUB=$(github_handle ca)
CRO_GITHUB=$(github_handle cro)
ENG_PLATFORM_GITHUB=$(github_handle eng-platform)

# Tunables (SYSTEM_INVARIANTS.md §2 defaults; overridable in config.tunables)
tunable() {
  local key="$1"
  local default="$2"
  local v
  v=$(jq -r --arg k "$key" '.tunables[$k] // empty' "$CONFIG")
  echo "${v:-$default}"
}
HIGH_VALUE_THRESHOLD=$(tunable HIGH_VALUE_THRESHOLD "10000")
SPRINT_LENGTH=$(tunable SPRINT_LENGTH "2 weeks")
ACCESSIBILITY_FLOOR=$(tunable ACCESSIBILITY_FLOOR "WCAG 2.2 AA")
RUNBOOK_DRILL_CADENCE=$(tunable RUNBOOK_DRILL_CADENCE "90 days")
POSTS_PER_CHANNEL_PER_WEEK=$(tunable POSTS_PER_CHANNEL_PER_WEEK "3")
TIER_STRATEGIC=$(tunable TIER_STRATEGIC "Strategic")
TIER_COMMERCIAL=$(tunable TIER_COMMERCIAL "Commercial")
TIER_TECHNICAL=$(tunable TIER_TECHNICAL "Technical")
VOICE_LONGFORM=$(tunable VOICE_LONGFORM "considered, evidence-led")
VOICE_TWITTER=$(tunable VOICE_TWITTER "concise, builder, no hype")
VOICE_LINKEDIN=$(tunable VOICE_LINKEDIN "professional, grounded, no slogans")
VOICE_PRESS=$(tunable VOICE_PRESS "factual, attributable, AP-style")
VOICE_BLOG=$(tunable VOICE_BLOG "conversational expert, examples-first")
VOICE_CRISIS=$(tunable VOICE_CRISIS "calm, factual, accountable, no hedging")
W_COMPLETION=$(tunable W_COMPLETION "0.30")
W_EFFICIENCY=$(tunable W_EFFICIENCY "0.20")
W_ESCALATION=$(tunable W_ESCALATION "0.30")
W_QUALITY=$(tunable W_QUALITY "0.20")
BACKEND_LANG=$(tunable BACKEND_LANG "Python")
BACKEND_FRAMEWORK=$(tunable BACKEND_FRAMEWORK "FastAPI")
FRONTEND_PLATFORM=$(tunable FRONTEND_PLATFORM "React Native + Expo")
WEB_FRAMEWORK=$(tunable WEB_FRAMEWORK "Next.js")
MONOREPO_TOOL=$(tunable MONOREPO_TOOL "Turborepo")
STATE_SERVER=$(tunable STATE_SERVER "TanStack Query")
STATE_CLIENT=$(tunable STATE_CLIENT "Zustand")
FORMS_LIB=$(tunable FORMS_LIB "React Hook Form + Zod")
DATABASE=$(tunable DATABASE "LibSQL via Turso")
OBSERVABILITY=$(tunable OBSERVABILITY "OpenTelemetry")
CICD=$(tunable CICD "GitHub Actions")

AGENT_DESCRIPTION="$COMPANY_DESCRIPTION"

# Allowlist of placeholders that may legitimately survive at company init
# (runtime-bound at SessionStart, project init, or agent self-binding).
# Intentionally short:
# - ACTIVE_PROJECT survives both scopes (runtime-bound at SessionStart).
# - PROJECT_NAME survives company-scope (project bound later); is
#   substituted under --scope projects --project=<slug>.
# - AGENT_DESCRIPTION survives both scopes (agent-self-bound at first
#   manifesto write — pre-v0.7.x adopters left this placeholder
#   intentionally; the wizard has no formal per-agent description
#   schema yet). Listed here so the validator does not fail-loud on
#   unbound files.
if [[ "$SCOPE" == "projects" && -n "${PROJECT_NAME:-}" ]]; then
  ALLOWLIST_REGEX='ACTIVE_PROJECT|AGENT_DESCRIPTION'
else
  ALLOWLIST_REGEX='ACTIVE_PROJECT|PROJECT_NAME|AGENT_DESCRIPTION'
fi

# ─────────────────────────────────────────────
# Substitute one file in place, validate residue
# ─────────────────────────────────────────────

# bash 3.2 (macOS default) mis-handles ${V//\\\}; sed sidesteps the issue.
# We use Python for in-place substitution to avoid shell-escape nightmares
# in heredoc/awk for arbitrary text content.
substitute_file() {
  local file="$1"
  local file_basename
  file_basename=$(basename "$file")

  # Per-agent {{AGENT_NAME}} resolves to the agent's name based on the file
  # basename. agents/company/cso.md → Shield, etc.
  local agent_name_token=""
  case "$file_basename" in
    cos.md)           agent_name_token="$COS_NAME" ;;
    cfo.md)           agent_name_token="$CFO_NAME" ;;
    clo.md)           agent_name_token="$CLO_NAME" ;;
    cmo.md)           agent_name_token="$CMO_NAME" ;;
    cco.md)           agent_name_token="$CCO_NAME" ;;
    chro.md)          agent_name_token="$CHRO_NAME" ;;
    cso.md)           agent_name_token="$CSO_NAME" ;;
    cetho.md)         agent_name_token="$CETHO_NAME" ;;
    ca.md)            agent_name_token="$CA_NAME" ;;
    cro.md)           agent_name_token="$CRO_NAME" ;;
    eng-platform.md)  agent_name_token="$ENG_PLATFORM_NAME" ;;
    cto.md)           agent_name_token="$CTO_NAME" ;;
    cpo.md)           agent_name_token="$CPO_NAME" ;;
    cdo.md)           agent_name_token="$CDO_NAME" ;;
    coo.md)           agent_name_token="$COO_NAME" ;;
    vpe.md)           agent_name_token="$VPE_NAME" ;;
    eng-api.md)       agent_name_token="$ENG_API_NAME" ;;
    eng-backend.md)   agent_name_token="$ENG_BACKEND_NAME" ;;
    eng-frontend.md)  agent_name_token="$ENG_FRONTEND_NAME" ;;
    eng-ai.md)        agent_name_token="$ENG_AI_NAME" ;;
    *)                agent_name_token="" ;;
  esac

  python3 - "$file" "$agent_name_token" "$ALLOWLIST_REGEX" "$CHECK_ONLY" <<'PYEOF'
import os, re, sys

path, agent_name_token, allowlist_re, check_only = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(path) as f:
    content = f.read()

# Read substitutions from environment (parent shell exports them).
subs = {
    "COMPANY_NAME":              os.environ.get("COMPANY_NAME", ""),
    "COMPANY_NAME_SLUG":         os.environ.get("COMPANY_NAME_SLUG", ""),
    "COMPANY_DOMAIN":            os.environ.get("COMPANY_DOMAIN", ""),
    "CEO_NAME":                  os.environ.get("CEO_NAME", ""),
    "AGENT_DESCRIPTION":         os.environ.get("AGENT_DESCRIPTION", ""),
    "AGENT_NAME":                agent_name_token,
    "COS_NAME":                  os.environ.get("COS_NAME", ""),
    "CFO_NAME":                  os.environ.get("CFO_NAME", ""),
    "CLO_NAME":                  os.environ.get("CLO_NAME", ""),
    "CMO_NAME":                  os.environ.get("CMO_NAME", ""),
    "CCO_NAME":                  os.environ.get("CCO_NAME", ""),
    "CHRO_NAME":                 os.environ.get("CHRO_NAME", ""),
    "CSO_NAME":                  os.environ.get("CSO_NAME", ""),
    "CETHO_NAME":                os.environ.get("CETHO_NAME", ""),
    "CA_NAME":                   os.environ.get("CA_NAME", ""),
    "CRO_NAME":                  os.environ.get("CRO_NAME", ""),
    "ENG_PLATFORM_NAME":         os.environ.get("ENG_PLATFORM_NAME", ""),
    "PROJECT_NAME":              os.environ.get("PROJECT_NAME", ""),
    "PROJECT_NAME_SLUG":         os.environ.get("PROJECT_NAME_SLUG", ""),
    "CTO_NAME":                  os.environ.get("CTO_NAME", ""),
    "CPO_NAME":                  os.environ.get("CPO_NAME", ""),
    "CDO_NAME":                  os.environ.get("CDO_NAME", ""),
    "COO_NAME":                  os.environ.get("COO_NAME", ""),
    "VPE_NAME":                  os.environ.get("VPE_NAME", ""),
    "ENG_API_NAME":              os.environ.get("ENG_API_NAME", ""),
    "ENG_BACKEND_NAME":          os.environ.get("ENG_BACKEND_NAME", ""),
    "ENG_FRONTEND_NAME":         os.environ.get("ENG_FRONTEND_NAME", ""),
    "ENG_AI_NAME":               os.environ.get("ENG_AI_NAME", ""),
    "CEO_GITHUB":                os.environ.get("CEO_GITHUB", ""),
    "COS_GITHUB":                os.environ.get("COS_GITHUB", ""),
    "CFO_GITHUB":                os.environ.get("CFO_GITHUB", ""),
    "CLO_GITHUB":                os.environ.get("CLO_GITHUB", ""),
    "CMO_GITHUB":                os.environ.get("CMO_GITHUB", ""),
    "CCO_GITHUB":                os.environ.get("CCO_GITHUB", ""),
    "CHRO_GITHUB":               os.environ.get("CHRO_GITHUB", ""),
    "CSO_GITHUB":                os.environ.get("CSO_GITHUB", ""),
    "CETHO_GITHUB":              os.environ.get("CETHO_GITHUB", ""),
    "CA_GITHUB":                 os.environ.get("CA_GITHUB", ""),
    "CRO_GITHUB":                os.environ.get("CRO_GITHUB", ""),
    "ENG_PLATFORM_GITHUB":       os.environ.get("ENG_PLATFORM_GITHUB", ""),
    "HIGH_VALUE_THRESHOLD":      os.environ.get("HIGH_VALUE_THRESHOLD", ""),
    "SPRINT_LENGTH":             os.environ.get("SPRINT_LENGTH", ""),
    "ACCESSIBILITY_FLOOR":       os.environ.get("ACCESSIBILITY_FLOOR", ""),
    "RUNBOOK_DRILL_CADENCE":     os.environ.get("RUNBOOK_DRILL_CADENCE", ""),
    "POSTS_PER_CHANNEL_PER_WEEK":os.environ.get("POSTS_PER_CHANNEL_PER_WEEK", ""),
    "TIER_STRATEGIC":            os.environ.get("TIER_STRATEGIC", ""),
    "TIER_COMMERCIAL":           os.environ.get("TIER_COMMERCIAL", ""),
    "TIER_TECHNICAL":            os.environ.get("TIER_TECHNICAL", ""),
    "VOICE_LONGFORM":            os.environ.get("VOICE_LONGFORM", ""),
    "VOICE_TWITTER":             os.environ.get("VOICE_TWITTER", ""),
    "VOICE_LINKEDIN":            os.environ.get("VOICE_LINKEDIN", ""),
    "VOICE_PRESS":               os.environ.get("VOICE_PRESS", ""),
    "VOICE_BLOG":                os.environ.get("VOICE_BLOG", ""),
    "VOICE_CRISIS":              os.environ.get("VOICE_CRISIS", ""),
    "W_COMPLETION":              os.environ.get("W_COMPLETION", ""),
    "W_EFFICIENCY":              os.environ.get("W_EFFICIENCY", ""),
    "W_ESCALATION":              os.environ.get("W_ESCALATION", ""),
    "W_QUALITY":                 os.environ.get("W_QUALITY", ""),
    "BACKEND_LANG":              os.environ.get("BACKEND_LANG", ""),
    "BACKEND_FRAMEWORK":         os.environ.get("BACKEND_FRAMEWORK", ""),
    "FRONTEND_PLATFORM":         os.environ.get("FRONTEND_PLATFORM", ""),
    "WEB_FRAMEWORK":             os.environ.get("WEB_FRAMEWORK", ""),
    "MONOREPO_TOOL":             os.environ.get("MONOREPO_TOOL", ""),
    "STATE_SERVER":              os.environ.get("STATE_SERVER", ""),
    "STATE_CLIENT":              os.environ.get("STATE_CLIENT", ""),
    "FORMS_LIB":                 os.environ.get("FORMS_LIB", ""),
    "DATABASE":                  os.environ.get("DATABASE", ""),
    "OBSERVABILITY":             os.environ.get("OBSERVABILITY", ""),
    "CICD":                      os.environ.get("CICD", ""),
}

# Whole-token substitution (no partial matches).
for key, val in subs.items():
    if val == "":
        continue  # don't substitute empty — leave placeholder for visibility
    content = content.replace("{{" + key + "}}", val)

# Verify residue.
allowlist = re.compile(allowlist_re)
survivors = set(re.findall(r"\{\{([A-Z_][A-Z0-9_]*)\}\}", content))
disallowed = sorted(s for s in survivors if not allowlist.fullmatch(s))

if disallowed:
    print(f"FAIL {path}: surviving non-allowlisted placeholders: {disallowed}", file=sys.stderr)
    sys.exit(2)

if check_only == "1":
    if survivors:
        print(f"OK   {path} (allowlisted survivors: {sorted(survivors)})")
    else:
        print(f"OK   {path}")
    sys.exit(0)

with open(path, "w") as f:
    f.write(content)

if survivors:
    print(f"compiled: {path} (allowlisted survivors: {sorted(survivors)})")
else:
    print(f"compiled: {path}")
PYEOF
}

# Export shell variables so the embedded Python sees them via os.environ.
export COMPANY_NAME COMPANY_NAME_SLUG COMPANY_DOMAIN CEO_NAME AGENT_DESCRIPTION
export COS_NAME CFO_NAME CLO_NAME CMO_NAME CCO_NAME CHRO_NAME CSO_NAME CETHO_NAME CA_NAME CRO_NAME ENG_PLATFORM_NAME
export PROJECT_NAME PROJECT_NAME_SLUG
export CTO_NAME CPO_NAME CDO_NAME COO_NAME VPE_NAME ENG_API_NAME ENG_BACKEND_NAME ENG_FRONTEND_NAME ENG_AI_NAME
export CEO_GITHUB COS_GITHUB CFO_GITHUB CLO_GITHUB CMO_GITHUB CCO_GITHUB CHRO_GITHUB CSO_GITHUB CETHO_GITHUB CA_GITHUB CRO_GITHUB ENG_PLATFORM_GITHUB
export HIGH_VALUE_THRESHOLD SPRINT_LENGTH ACCESSIBILITY_FLOOR RUNBOOK_DRILL_CADENCE POSTS_PER_CHANNEL_PER_WEEK
export TIER_STRATEGIC TIER_COMMERCIAL TIER_TECHNICAL
export VOICE_LONGFORM VOICE_TWITTER VOICE_LINKEDIN VOICE_PRESS VOICE_BLOG VOICE_CRISIS
export W_COMPLETION W_EFFICIENCY W_ESCALATION W_QUALITY
export BACKEND_LANG BACKEND_FRAMEWORK FRONTEND_PLATFORM WEB_FRAMEWORK MONOREPO_TOOL
export STATE_SERVER STATE_CLIENT FORMS_LIB DATABASE OBSERVABILITY CICD

# ─────────────────────────────────────────────
# --rewrite-meta — replace per-company README/CHANGELOG/SECURITY +
# replace docs/adr/* with company-scope stub. v0.6.5+ (F-16).
# ─────────────────────────────────────────────
#
# Pre-v0.6.5 the per-company instance shipped with the Juvant OS framework's
# README/CHANGELOG/SECURITY committed as if they were the company's own —
# every adopter looking at their repo saw "Juvant OS — The OSS multi-agent
# operating system" instead of their own brand. Same for `docs/adr/`:
# framework-architecture decisions (Skill-first, ADR 0010 symlinks, etc.)
# leaked into the per-company namespace, blocking adopters from numbering
# their own ADRs from 0001.
#
# `--rewrite-meta` swaps these at bootstrap (Step 7.6, after substitution
# but before commit):
#   README.md            → from scripts/templates/README.md.template
#   CHANGELOG.md         → from scripts/templates/CHANGELOG.md.template
#   SECURITY.md          → from scripts/templates/SECURITY.md.template
#   docs/adr/README.md   → from scripts/templates/docs-adr-README.md.template
#   docs/adr/0001-*.md   → REMOVED (framework ADRs not part of company repo)
#   docs/adr/0002-*.md   → REMOVED
#   ... through docs/adr/0010-*.md
#
# Bootstrap metadata (date, audit verdict, DB provider, etc.) is read from
# .juvant/state.db (master_context table — populated by Step 9.7+) and from
# .juvant/config.json. JUVANT_OS_VERSION is read from the repo's `VERSION`
# file at the root.
rewrite_meta() {
  local templates="$ROOT/scripts/templates"
  if [[ ! -d "$templates" ]]; then
    echo "ERROR: $templates not found — cannot run --rewrite-meta." >&2
    exit 1
  fi

  # Resolve metadata for substitution.
  local bootstrap_date bootstrap_verdict juvant_os_version
  local db_url_raw db_url_display db_provider bank_provider doc_storage_provider

  juvant_os_version=$(cat "$ROOT/VERSION" 2>/dev/null || echo "unknown")
  juvant_os_version="v${juvant_os_version}"

  # Read bootstrap state from state.db if available (provider=local path).
  # juvant_db_resolve via the library handles file: prefix stripping (F-20).
  # shellcheck disable=SC1091
  . "$ROOT/hooks/lib/db.sh" 2>/dev/null || true
  juvant_db_resolve 2>/dev/null || true

  if [[ -n "${JUVANT_DB_PATH:-}" && -f "$JUVANT_DB_PATH" ]] && command -v sqlite3 &>/dev/null; then
    bootstrap_date=$(sqlite3 "$JUVANT_DB_PATH" \
      "SELECT value FROM master_context WHERE key='bootstrap_completed_at';" \
      2>/dev/null | head -1)
    bootstrap_verdict=$(sqlite3 "$JUVANT_DB_PATH" \
      "SELECT value FROM master_context WHERE key='bootstrap_audit_verdict';" \
      2>/dev/null | head -1)
  fi
  bootstrap_date="${bootstrap_date:-$(date -u +%Y-%m-%d)}"
  bootstrap_verdict="${bootstrap_verdict:-PENDING}"

  db_provider=$(jq -r '.db.provider // "unknown"' "$CONFIG")
  db_url_raw=$(jq -r '.db.url // "unknown"' "$CONFIG")
  db_url_display="${db_url_raw#file:}"
  bank_provider=$(jq -r '.bank.provider // "unbound"' "$CONFIG")
  doc_storage_provider=$(jq -r '.doc_storage.provider // "unbound"' "$CONFIG")

  export JUVANT_OS_VERSION="$juvant_os_version"
  export BOOTSTRAP_DATE="$bootstrap_date"
  export BOOTSTRAP_VERDICT="$bootstrap_verdict"
  export DB_PROVIDER="$db_provider"
  export DB_URL_DISPLAY="$db_url_display"
  export BANK_PROVIDER="$bank_provider"
  export DOC_STORAGE_PROVIDER="$doc_storage_provider"

  render_template() {
    local template="$1"
    local target="$2"
    if [[ ! -f "$template" ]]; then
      echo "ERROR: template not found: $template" >&2
      exit 1
    fi
    python3 - "$template" "$target" <<'PYEOF'
import os, sys
template_path, target_path = sys.argv[1], sys.argv[2]
with open(template_path) as f:
    content = f.read()
subs = {
    "COMPANY_NAME":            os.environ.get("COMPANY_NAME", ""),
    "COMPANY_DESCRIPTION":     os.environ.get("AGENT_DESCRIPTION", ""),
    "COMPANY_DOMAIN":          os.environ.get("COMPANY_DOMAIN", ""),
    "CEO_NAME":                os.environ.get("CEO_NAME", ""),
    "BOOTSTRAP_DATE":          os.environ.get("BOOTSTRAP_DATE", ""),
    "BOOTSTRAP_VERDICT":       os.environ.get("BOOTSTRAP_VERDICT", ""),
    "JUVANT_OS_VERSION":       os.environ.get("JUVANT_OS_VERSION", ""),
    "DB_PROVIDER":             os.environ.get("DB_PROVIDER", ""),
    "DB_URL_DISPLAY":          os.environ.get("DB_URL_DISPLAY", ""),
    "BANK_PROVIDER":           os.environ.get("BANK_PROVIDER", ""),
    "DOC_STORAGE_PROVIDER":    os.environ.get("DOC_STORAGE_PROVIDER", ""),
}
for key, val in subs.items():
    if val:
        content = content.replace("{{" + key + "}}", val)
os.makedirs(os.path.dirname(target_path) or ".", exist_ok=True)
with open(target_path, "w") as f:
    f.write(content)
print(f"rewrote: {target_path}")
PYEOF
  }

  render_template "$templates/README.md.template"          "$ROOT/README.md"
  render_template "$templates/CHANGELOG.md.template"       "$ROOT/CHANGELOG.md"
  render_template "$templates/SECURITY.md.template"        "$ROOT/SECURITY.md"
  render_template "$templates/docs-adr-README.md.template" "$ROOT/docs/adr/README.md"

  # Remove framework ADRs (0001-NNNN .md files); leave the (now-rewritten)
  # README.md as the company-scope ADR stub.
  echo "removing framework ADRs from docs/adr/ (kept upstream)…"
  if compgen -G "$ROOT/docs/adr/0[0-9][0-9][0-9]-*.md" > /dev/null; then
    for f in "$ROOT/docs/adr/"0[0-9][0-9][0-9]-*.md; do
      [[ -f "$f" ]] || continue
      rm -f "$f"
      echo "  removed: $f"
    done
  fi

  echo "rewrite-meta: complete."
}

# ─────────────────────────────────────────────
# Drive
# ─────────────────────────────────────────────

if [[ "$DO_REWRITE_META" == "1" ]]; then
  rewrite_meta
elif [[ "$DO_CODEOWNERS" == "1" ]]; then
  TARGET="$ROOT/.github/CODEOWNERS"
  if [[ ! -f "$TARGET" ]]; then
    echo "ERROR: $TARGET not found." >&2
    exit 1
  fi
  substitute_file "$TARGET"
else
  case "$SCOPE" in
    company)  TARGET_DIR="$ROOT/agents/company" ;;
    projects) TARGET_DIR="$ROOT/agents/projects" ;;
    *) echo "ERROR: unknown --scope '$SCOPE' (expected 'company' or 'projects')" >&2; exit 1 ;;
  esac

  if [[ ! -d "$TARGET_DIR" ]]; then
    echo "ERROR: $TARGET_DIR not found." >&2
    exit 1
  fi

  for f in "$TARGET_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    substitute_file "$f"
  done
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
  echo "check-only: no files modified."
fi
