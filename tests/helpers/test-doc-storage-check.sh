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
  out=$(bash "$HELPER" --config "$cfg" --mcp "$mcp" 2>&1); rc=$?
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
out=$(bash "$HELPER" --config "$C_SPLIT" --mcp "$MCP_M365" 2>&1)
if grep -q "SPLIT-BRAIN RISK] legal" <<<"$out"; then
  echo "FAIL soft role (no space) must not be flagged"; fail=$((fail + 1))
else
  echo "ok   soft role (no space) not flagged"; pass=$((pass + 1))
fi

C_NODS=$(cfg nods '{}')
check "no doc_storage block → no drift" 0 "OK" "$C_NODS" "$MCP_M365"

echo 'not json' >"$TMP/bad.json"
check "invalid config → error" 2 "not valid JSON" "$TMP/bad.json" "$MCP_M365"

# Template canon (R1/R2): agent templates resolve through resolve_space and
# never carry the static "until configured" write flag.
stale=$(grep -rlE "until the M365 write-capability|folder-resolution algorithm|doc_storage\.folders\." "$ROOT/agents" 2>/dev/null || true)
if [[ -n "$stale" ]]; then
  echo "FAIL agent templates bypass resolve_space / use a static write flag:"; echo "$stale"; fail=$((fail + 1))
else
  echo "ok   agent templates resolve via resolve_space"; pass=$((pass + 1))
fi
if grep -qE "def can_write\(role: str\) " "$ROOT/JUVANT_OS.md" \
   || ! grep -qE "target = resolve_space\(role, caller\)" "$ROOT/JUVANT_OS.md"; then
  echo "FAIL JUVANT_OS.md can_write must resolve through resolve_space(role, caller)"; fail=$((fail + 1))
else
  echo "ok   can_write resolves through resolve_space"; pass=$((pass + 1))
fi

echo "doc-storage-check: $pass passed, $fail failed"
[[ "$fail" == 0 ]]
