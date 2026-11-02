#!/usr/bin/env bash
# tests/helpers/test-doc-storage-check.sh
# Regression for helpers/doc-storage-check.sh (BUG-094, juvant-os-pm#197):
# mcp_server record drift (R3) and the split-brain guard (R5).
#
# Run: bash tests/helpers/test-doc-storage-check.sh
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/helpers/doc-storage-check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # name expected_exit expected_grep(or "") config mcp
  local name="$1" want="$2" pattern="$3" cfg="$4" mcp="$5" out rc
  out=$(bash "$HELPER" --config "$cfg" --mcp "$mcp" --policy "${POL:-$TMP/nopolicy.json}" 2>&1); rc=$?
  if [[ "$rc" != "$want" ]]; then
    echo "FAIL $name: exit $rc, want $want"; echo "$out"; fail=$((fail + 1)); return
  fi
  if [[ -n "$pattern" ]] && ! grep -qF -- "$pattern" <<<"$out"; then
    echo "FAIL $name: output lacks '$pattern'"; echo "$out"; fail=$((fail + 1)); return
  fi
  echo "ok   $name"; pass=$((pass + 1))
}

MCP_M365="$TMP/mcp-m365.json"
echo '{"mcpServers":{"m365-graph":{"command":"scripts/run-m365-graph-mcp.sh"}}}' >"$MCP_M365"
MCP_NONE="$TMP/mcp-none.json"
echo '{"mcpServers":{}}' >"$MCP_NONE"

cfg() { echo "$2" >"$TMP/$1.json"; echo "$TMP/$1.json"; }

C_CLEAN=$(cfg clean '{"doc_storage":{"mcp_server":"m365-graph","folders":{"finance":null},"spaces":{"finance":{"container":"org"}}}}')
check "clean promoted space, m365-graph record" 0 "OK — doc_storage: no drift" "$C_CLEAN" "$MCP_M365"

C_DRIFT=$(cfg drift '{"doc_storage":{"mcp_server":"ms-graph","folders":{}}}')
check "ms-graph record + m365-graph registered → drift" 1 "[DOC STORAGE MCP RECORD DRIFT]" "$C_DRIFT" "$MCP_M365"
check "ms-graph record, nothing registered → no drift" 0 "OK" "$C_DRIFT" "$MCP_NONE"
check "ms-graph record, no .mcp.json → no drift" 0 "OK" "$C_DRIFT" "$TMP/absent.json"

C_SPLIT=$(cfg split '{"doc_storage":{"mcp_server":"m365-graph","folders":{"finance":"/Co/02 - Finance","legal":"/Co/01 - Legal"},"spaces":{"finance":{"container":"org"}}}}')
check "promoted space with legacy folder bound → split-brain" 1 "[DOC STORAGE SPLIT-BRAIN RISK] finance" "$C_SPLIT" "$MCP_M365"
out=$(bash "$HELPER" --config "$C_SPLIT" --mcp "$MCP_M365" --policy "$TMP/nopolicy.json" 2>&1)
if grep -q "SPLIT-BRAIN RISK] legal" <<<"$out"; then
  echo "FAIL soft role (no space) must not be flagged"; fail=$((fail + 1))
else
  echo "ok   soft role (no space) not flagged"; pass=$((pass + 1))
fi

C_NODS=$(cfg nods '{}')
check "no doc_storage block → no drift" 0 "OK" "$C_NODS" "$MCP_M365"

echo 'not json' >"$TMP/bad.json"
check "invalid config → error" 2 "not valid JSON" "$TMP/bad.json" "$MCP_M365"

# ADR 0035 — multi-library spaces.
C_LIB_OK=$(cfg libok '{"doc_storage":{"mcp_server":"m365-graph","spaces":{"finance":{"container":"org","default_library":"general","libraries":{"general":{"resource_ids":{"drive_id":"b!g"},"purpose":"working docs"},"invoices":{"resource_ids":{"drive_id":"b!i"},"purpose":"invoices"}}}}}}')
check "valid multi-library space → no drift" 0 "OK" "$C_LIB_OK" "$MCP_M365"

C_LIB_NODEF=$(cfg libnodef '{"doc_storage":{"spaces":{"finance":{"libraries":{"general":{"resource_ids":{"drive_id":"b!g"},"purpose":"x"}}}}}}')
check "libraries without default_library" 1 "[DOC STORAGE LIBRARY CONFIG] finance — default_library is required" "$C_LIB_NODEF" "$MCP_NONE"

C_LIB_BADDEF=$(cfg libbaddef '{"doc_storage":{"spaces":{"finance":{"default_library":"nope","libraries":{"general":{"resource_ids":{"drive_id":"b!g"},"purpose":"x"}}}}}}')
check "default_library names no library" 1 'default_library "nope" names no library' "$C_LIB_BADDEF" "$MCP_NONE"

C_LIB_HOLES=$(cfg libholes '{"doc_storage":{"spaces":{"finance":{"default_library":"a","libraries":{"a":{"resource_ids":{},"purpose":"x"},"b":{"resource_ids":{"drive_id":"b!1"}}}}}}}')
check "library without drive id" 1 "finance/a — library has no resource_ids.drive_id" "$C_LIB_HOLES" "$MCP_NONE"
check "library without purpose" 1 "finance/b — library has no purpose" "$C_LIB_HOLES" "$MCP_NONE"

C_LIB_DUP=$(cfg libdup '{"doc_storage":{"spaces":{"finance":{"default_library":"a","libraries":{"a":{"resource_ids":{"drive_id":"b!1"},"purpose":"x"},"b":{"resource_ids":{"drive_id":"b!1"},"purpose":"y"}}}}}}')
check "two libraries share a drive id" 1 "finance — libraries a, b share drive id b!1" "$C_LIB_DUP" "$MCP_NONE"

# ADR 0035 §4 — sensitive-space perimeter covers every library.
C_SENS=$(cfg sens '{"doc_storage":{"spaces":{"legal-ip":{"agent_allowlist":["clo","cso"],"default_library":"main","libraries":{"main":{"resource_ids":{"drive_id":"b!m"},"purpose":"IP filings"},"drafts":{"resource_ids":{"drive_id":"b!d"},"purpose":"drafts"}}}}}}')
echo '{"space_access":[{"space":"legal-ip","tool_prefix":"mcp__m365-graph__","drive_ids":["b!m"],"allowlist":["clo","cso"]}]}' >"$TMP/pol-partial.json"
echo '{"space_access":[{"space":"legal-ip","tool_prefix":"mcp__m365-graph__","drive_ids":["b!m","b!d"],"allowlist":["clo","cso"]}]}' >"$TMP/pol-full.json"
POL="$TMP/pol-partial.json" check "sensitive library outside policy → perimeter gap" 1 "[DOC STORAGE PERIMETER GAP] legal-ip/drafts" "$C_SENS" "$MCP_NONE"
out=$(bash "$HELPER" --config "$C_SENS" --mcp "$MCP_NONE" --policy "$TMP/pol-partial.json" 2>&1)
if grep -q "PERIMETER GAP\] legal-ip/main" <<<"$out"; then
  echo "FAIL covered library must not be flagged"; fail=$((fail + 1))
else
  echo "ok   covered library not flagged"; pass=$((pass + 1))
fi
POL="$TMP/pol-full.json" check "every library covered → no gap" 0 "OK" "$C_SENS" "$MCP_NONE"
check "sensitive space, no policy → every library is a gap" 1 "[DOC STORAGE PERIMETER GAP] legal-ip/main" "$C_SENS" "$MCP_NONE"
C_SENS1=$(cfg sens1 '{"doc_storage":{"spaces":{"legal-ip":{"agent_allowlist":["clo"],"resource_ids":{"drive_id":"b!m"}}}}}')
check "single-library sensitive space outside policy → gap" 1 "[DOC STORAGE PERIMETER GAP] legal-ip — drive id b!m" "$C_SENS1" "$MCP_NONE"
POL="$TMP/pol-full.json" check "single-library sensitive space covered → no gap" 0 "OK" "$C_SENS1" "$MCP_NONE"

# Template canon (R1/R2): agent templates resolve through resolve_space and
# never carry the static "until configured" write flag.
stale=$(grep -rlE "until the M365 write-capability|folder-resolution algorithm|doc_storage\.folders\." "$ROOT/agents" 2>/dev/null || true)
if [[ -n "$stale" ]]; then
  echo "FAIL agent templates bypass resolve_space / use a static write flag:"; echo "$stale"; fail=$((fail + 1))
else
  echo "ok   agent templates resolve via resolve_space"; pass=$((pass + 1))
fi
if grep -qE "def can_write\(role: str\) " "$ROOT/JUVANT_OS.md" \
   || ! grep -qE "target = resolve_space\(role, caller" "$ROOT/JUVANT_OS.md"; then
  echo "FAIL JUVANT_OS.md can_write must resolve through resolve_space(role, caller)"; fail=$((fail + 1))
else
  echo "ok   can_write resolves through resolve_space"; pass=$((pass + 1))
fi

echo "doc-storage-check: $pass passed, $fail failed"
[[ "$fail" == 0 ]]
