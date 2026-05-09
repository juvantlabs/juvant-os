#!/usr/bin/env bash
# scripts/validate-batch-fixture.sh
#
# Schema validator for batch testco fixtures. Run by the driver as a
# pre-flight check; also run by CI as a separate workflow step so a
# malformed fixture surfaces independently of a Skill failure.
#
# Usage:
#   bash scripts/validate-batch-fixture.sh <fixture.yaml>
#
# Exit codes:
#   0   schema valid
#   1   missing tooling (yq / jq)
#   2   file not found / unreadable
#   3   schema violation (missing required field, wrong type, etc.)
#
# The schema is encoded inline in this script as a sequence of yq
# field-existence + type-shape checks. Keep in sync with
# `docs/adr/0012-batch-testco-mode.md` § Schema and the canonical
# example at `tests/fixtures/testco/single-company.yaml`.

set -euo pipefail

FIXTURE="${1:-}"

if [[ -z "$FIXTURE" ]]; then
  echo "ERROR: missing fixture path. Usage: $0 <fixture.yaml>" >&2
  exit 1
fi

if [[ ! -f "$FIXTURE" ]]; then
  echo "ERROR: fixture not found: $FIXTURE" >&2
  exit 2
fi

if ! command -v yq >/dev/null; then
  echo "ERROR: yq required (brew install yq)." >&2
  exit 1
fi

if ! command -v jq >/dev/null; then
  echo "ERROR: jq required." >&2
  exit 1
fi

# Convert YAML → JSON for jq's stronger type checking.
JSON=$(yq -o=json "$FIXTURE")

errs=0
fail() {
  echo "SCHEMA: $1" >&2
  errs=$((errs+1))
}

require_string() {
  local path="$1"
  local value
  value=$(jq -r "$path // empty" <<<"$JSON")
  if [[ -z "$value" ]]; then
    fail "missing required field: $path"
  fi
}

require_bool() {
  local path="$1"
  local type
  type=$(jq -r "$path | type" <<<"$JSON" 2>/dev/null || echo "missing")
  if [[ "$type" != "boolean" ]]; then
    fail "field $path must be boolean (got: $type)"
  fi
}

require_object() {
  local path="$1"
  local type
  type=$(jq -r "$path | type" <<<"$JSON" 2>/dev/null || echo "missing")
  if [[ "$type" != "object" ]]; then
    fail "field $path must be object (got: $type)"
  fi
}

require_one_of() {
  local path="$1"
  shift
  local value
  value=$(jq -r "$path // empty" <<<"$JSON")
  local match=0
  for v in "$@"; do
    if [[ "$value" == "$v" ]]; then match=1; break; fi
  done
  if [[ "$match" == "0" ]]; then
    fail "field $path must be one of [$*] (got: $value)"
  fi
}

# ─── top-level ─────────────────────────────────────────────────────
require_string '.scenario'
require_string '.fixture_version'
require_string '.juvant_os_version'
require_object '.inputs'
require_object '.expect'

# ─── inputs.identity ───────────────────────────────────────────────
require_string '.inputs.identity.company_name'
require_string '.inputs.identity.company_slug'
require_string '.inputs.identity.company_domain'
require_string '.inputs.identity.ceo_name'
require_string '.inputs.identity.copyright_holder'

# ─── inputs.doc_storage ────────────────────────────────────────────
require_one_of '.inputs.doc_storage.provider' onedrive sharepoint googledrive dropbox skip
require_string '.inputs.doc_storage.mcp_server'

# ─── inputs.github_user_map ────────────────────────────────────────
require_object '.inputs.github_user_map'
for role in ceo cos cfo clo cmo cco chro cso cetho ca cro eng-platform; do
  require_string ".inputs.github_user_map[\"$role\"]"
done

# ─── inputs.database ───────────────────────────────────────────────
require_one_of '.inputs.database.provider' local turso azure aws gcp
require_string '.inputs.database.url'

# ─── inputs.bank ───────────────────────────────────────────────────
require_one_of '.inputs.bank.provider' finom mercury revolut wise other skip
if [[ "$(jq -r '.inputs.bank.provider' <<<"$JSON")" == "other" ]]; then
  require_string '.inputs.bank.name'
  require_string '.inputs.bank.mcp_server'
fi

# ─── inputs.notifications ──────────────────────────────────────────
require_object '.inputs.notifications'
if [[ "$(jq -r '.inputs.notifications.telegram.enabled // false' <<<"$JSON")" == "true" ]]; then
  require_string '.inputs.notifications.telegram.bot_token'
  require_string '.inputs.notifications.telegram.chat_id'
  require_bool '.inputs.notifications.telegram.is_operator_personal_channel'
  # ADR 0011 carve-out gate: cos can only hold telegram:send-ceo-only if
  # the operator confirms this is their personal channel.
  if [[ "$(jq -r '.inputs.notifications.telegram.is_operator_personal_channel' <<<"$JSON")" != "true" ]]; then
    fail "telegram.is_operator_personal_channel must be true for the :send-ceo-only carve-out (ADR 0011)."
  fi
fi

# ─── inputs.guardrails ─────────────────────────────────────────────
require_object '.inputs.guardrails'

# ─── inputs.agent_names + cro_enabled ──────────────────────────────
require_object '.inputs.agent_names'
for role in cos cfo clo cmo cco chro cso cetho ca cro eng-platform; do
  require_string ".inputs.agent_names[\"$role\"]"
done
require_bool '.inputs.cro_enabled'

# ─── inputs.bootstrap ──────────────────────────────────────────────
require_one_of '.inputs.bootstrap.manifesto_approval_mode' \
  accept_all_defaults edit_specific walk_through_each skip

# ─── inputs.project (optional — present in single-project + multi-project) ──
if [[ "$(jq -r '.inputs.project // null | type' <<<"$JSON")" == "object" ]]; then
  require_string '.inputs.project.slug'
  require_string '.inputs.project.name'
  require_one_of '.inputs.project.github_repo.mode' skip_in_batch create_via_gh existing
  require_one_of '.inputs.project.doc_folder.mode' skip_auto_discovery direct_path scan
  require_one_of '.inputs.project.database.provider' local turso azure aws gcp
  require_string '.inputs.project.database.url'
  require_object '.inputs.project.agent_names'
  for role in cto cpo cdo coo vpe eng-api eng-backend eng-frontend eng-ai; do
    # agent_names accepts null (= use default <slug>-<role>) or string.
    proj_type=$(jq -r ".inputs.project.agent_names[\"$role\"] | type" <<<"$JSON" 2>/dev/null || echo "missing")
    if [[ "$proj_type" != "string" && "$proj_type" != "null" ]]; then
      fail "field .inputs.project.agent_names[\"$role\"] must be string or null (got: $proj_type)"
    fi
  done
  require_one_of '.inputs.project.bootstrap.manifesto_approval_mode' \
    accept_all_defaults edit_specific walk_through_each skip
fi

# ─── expect block ──────────────────────────────────────────────────
require_string '.expect.bootstrap_verdict'
require_one_of '.expect.bootstrap_verdict' PASS WARN-WITH-CONDITIONS FAIL
# manifests count is mechanical: 10 founding for company-only scenarios,
# 19 = 10 + 9 for single-project, etc. Acceptable values: 10 (no project),
# 19 (1 project), 28 (2 projects), … (10 + 9*N).
mc=$(jq -r '.expect.manifests_count // empty' <<<"$JSON")
case "$mc" in
  10|19|28|37|46) ;;
  *) fail ".expect.manifests_count must be 10 + 9*N where N = project count (got: $mc)" ;;
esac

# ─── exit ──────────────────────────────────────────────────────────
if [[ "$errs" -gt 0 ]]; then
  echo "FAILED: $errs schema violation(s) in $FIXTURE" >&2
  exit 3
fi

echo "OK: $FIXTURE schema valid (scenario=$(jq -r '.scenario' <<<"$JSON"), juvant_os_version=$(jq -r '.juvant_os_version' <<<"$JSON"))."
