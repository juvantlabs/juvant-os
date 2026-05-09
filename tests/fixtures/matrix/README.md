# Matrix fixtures — Step 8.5 cross-check captures

This directory holds **F-12 capture fixtures**: raw / errors / corrected
JSON triples produced by the JUVANT_OS Skill's Step 8.5 cross-check
during instrumented testco runs.

Each triple captures, for one bootstrap run:

| File | Content |
|---|---|
| `<date>-<company>-raw.json` | Canonical v0 matrix as derived from upstream `agents/company/ca.md` § Default Agent Tool Matrix + `agents/projects/coo.md`. The "as-documented" matrix before any corrections. |
| `<date>-<company>-errors.json` | Newline-delimited JSON findings from the Step 8.5 cross-check against `docs/MCP_INVENTORY.md` and `SYSTEM_INVARIANTS.md` §4. One JSON object per finding, layered L1 (server-inventory) / L2 (universal-boundary) / L3 (status-warnings) / L4 (registration-completeness). |
| `<date>-<company>-corrected.json` | Post-correction matrix actually written to the per-company `agent_tool_matrix` table. Includes `corrections_applied` (list of human-readable change descriptions) and `deltas_vs_raw` (added / modified / unchanged rows). |

These fixtures are the **canonical reference for upstream matrix
correctness work**. When `agents/company/ca.md` § Default Agent Tool
Matrix or `docs/MCP_INVENTORY.md` change, the next testco run's
`errors.json` should shrink (ideally to zero non-info findings — i.e.
no boundary violations, no coverage gaps, no registration ambiguities).

## Provenance

Fixtures land here by the wizard's instrumented Step 8.5 capture. The
instrumentation is enabled by passing `F-12 instrumented capture` in
the run prompt; the wizard writes to `/tmp/<company>-matrix-{raw,
errors,corrected}.json` and the orchestrator copies into this
directory at run close. Without instrumentation, no fixtures are
captured (Step 8.5 still runs, but findings live only in
`security_audit_log` for that run).

## How to use

Diff a new run's `corrected.json` against the prior run's to see
whether canonical-matrix patches are landing:

```bash
diff <(jq -S '.rows' tests/fixtures/matrix/2026-05-09-golf-corrected.json) \
     <(jq -S '.rows' tests/fixtures/matrix/<later>-corrected.json)
```

A clean upstream means `errors.json` contains only `error_type:"ok"`
or `error_type:"info"` rows. Anything else (boundary-violation,
coverage-gap, founding-vs-deferred-ambiguity) is an upstream drift
that should be patched.

## Current status

`2026-05-09-golf-testco` (v0.6.5 baseline, commit `92bf94d`):
**16 findings** — 1 P1 boundary-violation (cos / turso + telegram:send),
4 P2 (eng-platform, m365-graph gap, fattura_elettronica gap,
bank-stub-not-in-inventory), plus L3 status-warnings and L4 ok rows.
v0.6.6 ships the upstream patches that close the P1 + P2 findings;
expect a near-empty `errors.json` for the next testco run.
