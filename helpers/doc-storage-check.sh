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
#       a space is promoted; null it (or keep it as a read-only archive and
#       record a binding-confirmation decision).
#
# Usage:
#   bash helpers/doc-storage-check.sh [--config PATH] [--mcp PATH]
#
# Exit codes: 0 = no drift, 1 = drift found, 2 = error (unreadable config).
# A missing .mcp.json is not an error (no project-scope MCP registered).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../.juvant/config.json"
MCP="$SCRIPT_DIR/../.mcp.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="${2:?--config needs a path}"; shift 2 ;;
    --mcp)    MCP="${2:?--mcp needs a path}"; shift 2 ;;
    *) echo "Usage: $0 [--config PATH] [--mcp PATH]" >&2; exit 2 ;;
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

if [[ "$findings" -gt 0 ]]; then
  exit 1
fi
echo "OK — doc_storage: no drift"
exit 0
