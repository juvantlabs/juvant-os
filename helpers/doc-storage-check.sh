#!/usr/bin/env bash
# helpers/doc-storage-check.sh
# Document-storage config drift check (BUG-094, juvant-os-pm#197).
#
# Run at boot (JUVANT_OS.md § Boot sequence step 2c) and on demand. Read-only:
# it inspects .juvant/config.json and .mcp.json and never edits them.
#
# Findings (one line each on stdout, prefixed with the tag the agent surfaces):
#   [DOC STORAGE MCP RECORD DRIFT]  doc_storage.mcp_server is "ms-graph" (the
#       read-only fallback) while the write-capable m365-graph server is
#       registered in .mcp.json. Step 6 of the M365 write-capability setup
#       was skipped; agents reading the record conclude "no writes".
#   [DOC STORAGE SPLIT-BRAIN RISK] <role>  spaces.<role> is promoted but
#       folders.<role> is still bound. The legacy folder is read-only once
#       a space is promoted; null it.
#   [DOC STORAGE LIBRARY CONFIG] <role>[/<library>] — ADR 0035: `libraries`
#       without a valid `default_library`, a library without a drive id or
#       `purpose`, or two libraries sharing a drive id.
#   [DOC STORAGE PERIMETER GAP] <role>[/<library>] — ADR 0035 §4 / ADR 0025:
#       a sensitive space (`agent_allowlist` set) has a library whose drive id
#       is in no `space_access[].drive_ids` of the committed security policy.
#       That library is outside the hard perimeter. Security finding.
#
# The policy is read like the hook reads it: `security/policy.json` from
# origin/main (ADR 0034). --policy PATH overrides (tests). No policy at all ⇒
# every drive id of a sensitive space is a gap.
#
# Usage:
#   bash helpers/doc-storage-check.sh [--config PATH] [--mcp PATH] [--policy PATH]
#
# Exit codes: 0 = no drift, 1 = drift found, 2 = error (unreadable config).
# A missing .mcp.json is not an error (no project-scope MCP registered).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"
MCP="$SCRIPT_DIR/../.mcp.json"
POLICY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="${2:?--config needs a path}"; shift 2 ;;
    --mcp)    MCP="${2:?--mcp needs a path}"; shift 2 ;;
    --policy) POLICY="${2:?--policy needs a path}"; shift 2 ;;
    *) echo "Usage: $0 [--config PATH] [--mcp PATH] [--policy PATH]" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "doc-storage-check: jq is required" >&2; exit 2; }
[[ -r "$CONFIG" ]] || { echo "doc-storage-check: cannot read $CONFIG" >&2; exit 2; }
jq -e . "$CONFIG" >/dev/null 2>&1 || { echo "doc-storage-check: $CONFIG is not valid JSON" >&2; exit 2; }

findings=0

# R3 — mcp_server record drift.
record=$(jq -r '.doc_storage.mcp_server // ""' "$CONFIG")
m365_registered=0
if [[ -r "$MCP" ]] && jq -e '.mcpServers["m365-graph"] // empty' "$MCP" >/dev/null 2>&1; then
  m365_registered=1
fi
if [[ "$record" == "ms-graph" && "$m365_registered" == 1 ]]; then
  echo "[DOC STORAGE MCP RECORD DRIFT] doc_storage.mcp_server=\"ms-graph\" but m365-graph is registered in .mcp.json — run JUVANT_OS Step 1.5 M365 write-capability Step 6 (set mcp_server to \"m365-graph\")"
  findings=$((findings + 1))
fi

# R5 — split-brain guard: promoted space with the legacy folder still bound.
while IFS= read -r role; do
  [[ -n "$role" ]] || continue
  echo "[DOC STORAGE SPLIT-BRAIN RISK] $role — spaces.$role is promoted but folders.$role is still bound; the legacy folder is read-only, writes go to the space"
  findings=$((findings + 1))
done < <(jq -r '
  (.doc_storage // {}) as $d
  | ($d.spaces // {}) | keys[]
  | select((($d.folders // {})[.] // null) != null)
' "$CONFIG")

# ADR 0035 — library config validation.
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  echo "[DOC STORAGE LIBRARY CONFIG] $line"
  findings=$((findings + 1))
done < <(jq -r '
  def did: (.resource_ids.drive_id // .resource_ids.file_id // null);
  (.doc_storage.spaces // {}) | to_entries[]
  | .key as $r | .value as $sp
  | select(($sp.libraries // null) != null)
  | ($sp.libraries | if type == "object" then . else {} end) as $libs
  | ( if ($libs | length) == 0 then "\($r) — libraries is empty or not an object"
      elif ($sp.default_library // null) == null then "\($r) — default_library is required when libraries is set"
      elif ($libs | has($sp.default_library)) | not then "\($r) — default_library \"\($sp.default_library)\" names no library"
      else empty end ),
    ( $libs | to_entries[]
      | select((.value | did) == null) | "\($r)/\(.key) — library has no resource_ids.drive_id (or file_id)" ),
    ( $libs | to_entries[]
      | select(((.value.purpose // "") | tostring | length) == 0) | "\($r)/\(.key) — library has no purpose" ),
    ( [ $libs | to_entries[] | {k: .key, d: (.value | did)} | select(.d != null) ]
      | group_by(.d)[] | select(length > 1)
      | "\($r) — libraries \(map(.k) | join(", ")) share drive id \(.[0].d)" )
' "$CONFIG")

# ADR 0035 §4 — every drive id of a sensitive space must be in the perimeter.
policy_json='{}'
if [[ -n "$POLICY" ]]; then
  [[ -r "$POLICY" ]] && policy_json=$(cat "$POLICY")
elif git -C "$SCRIPT_DIR/.." rev-parse --verify -q origin/main >/dev/null 2>&1; then
  policy_json=$(git -C "$SCRIPT_DIR/.." show origin/main:security/policy.json 2>/dev/null || echo '{}')
fi
jq -e . >/dev/null 2>&1 <<<"$policy_json" || policy_json='{}'
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  echo "[DOC STORAGE PERIMETER GAP] $line"
  findings=$((findings + 1))
done < <(jq -r --argjson pol "$policy_json" '
  def did: (.resource_ids.drive_id // .resource_ids.file_id // null);
  ([ ($pol.space_access // [])[] | (.drive_ids // [])[] ]) as $covered
  | (.doc_storage.spaces // {}) | to_entries[]
  | .key as $r | .value as $sp
  | select(($sp.agent_allowlist // null) != null)
  | if (($sp.libraries // {}) | type == "object" and length > 0)
    then ($sp.libraries | to_entries[] | {n: "\($r)/\(.key)", d: (.value | did)})
    else {n: $r, d: ($sp | did)} end
  | select(.d != null and (.d as $d | $covered | index($d) | not))
  | "\(.n) — drive id \(.d) is in no security/policy.json space_access rule; the library is outside the hard perimeter"
' "$CONFIG")

if [[ "$findings" -gt 0 ]]; then
  exit 1
fi
echo "OK — doc_storage: no drift"
exit 0
