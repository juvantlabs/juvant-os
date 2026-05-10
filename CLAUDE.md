# CLAUDE.md — framework-development instructions

> **Scope**: this file is **framework-only**. It exists in the upstream
> `juvantlabs/juvant-os` repository and is **replaced** at company init
> by `scripts/compile-templates.sh --rewrite-meta` with a 3-line
> per-company stub (`scripts/templates/CLAUDE.md.template`). Adopters
> never see the framework-dev content below; they get a clean stub
> they can fill in with their own per-company guidance.
>
> If you are reading this file, you are working on the **framework
> itself** — the OSS Skill, hooks, scripts, and ADRs that ship to
> adopters. Stay in framework-dev mindset: every change here ships to
> every adopter who pulls upstream.

## Quick commands the CEO might say

When the CEO/contributor says any of the phrases below, follow the
matching procedure. These are framework-dev shortcuts that don't apply
to adopter sessions.

### "facciamo e2e test" / "lancia un batch test" / "run e2e"

End-to-end batch run of the JUVANT_OS Skill against a fixture under
`tests/fixtures/testco/`. Per ADR 0012 (Batch testco mode + CI
integration).

**Procedure**:

1. Pick the scenario:
   - Default: `single-project` (post-v0.7.1 baseline; covers
     company-init + 1 project-init in one batch run).
   - If the CEO says "single-company" or "company-init only", use
     `single-company`.
   - If they say "all" or "multi", run multiple in sequence.
2. Pre-flight cleanup:
   ```bash
   rm -rf /tmp/testco-batch-<scenario> /tmp/testco-batch-<scenario>-origin.git
   ```
3. Spawn the driver. Use `Bash` with `dangerouslyDisableSandbox: true`
   and `timeout: 600000` (10 min hard cap; single-project typically
   finishes in 3-13 min depending on cache state):
   ```bash
   bash scripts/run-testco-batch.sh tests/fixtures/testco/<scenario>.yaml --no-render --keep-tmp 2>&1 | tail -120
   ```
4. Live progress feedback (HARD-REQUIRED) — arm a `Monitor` task
   tailing both event sinks so the operator sees `[BATCH]` events
   flowing in real time:
   ```bash
   EVENTS=/tmp/testco-batch-<scenario>/.juvant/batch-events.jsonl
   STREAM=/tmp/testco-batch-<scenario>/stream.jsonl
   # poll both, emit events with elapsed-second timestamps and
   # periodic ping every 30s; exit on `"type":"result"` in stream
   ```
5. After the run completes, parse the driver's exit code and the
   results files at `tests/fixtures/testco/results/<date>-<scenario>.{jsonl,md}`.
   Surface:
   - `bootstrap_verdict` (PASS / WARN-WITH-CONDITIONS / FAIL)
   - assertion pass/fail count
   - cost ($), wall duration, tool-call breakdown, model_usage

**Pre-requisites** (verify before spawning):

- `.claude/settings.json` allow-list contains `"Bash(bash scripts/run-testco-batch.sh:*)"`.
  Without it, the Bash-tool sandbox isolates `/opt/homebrew/bin/claude`
  from the spawned subshell and the run fails with "No such file or
  directory" on the binary.
- Authentication: the local Mac uses claude.ai subscription auth (no
  API key). On CI runners, set `ANTHROPIC_API_KEY` repo secret OR
  configure Microsoft Foundry / AWS Bedrock / GCP Vertex per the
  `.github/workflows/testco-batch.yml` env block.

### "facciamo un manual testco" / "lancia testco manuale"

Manual operator-driven testco. Per ADR 0012, manual remains the
**primary validation mode**; batch is supplementary CI / regression
detection. Direct the CEO to drive `claude` from their own terminal
in a freshly-cloned `/tmp/testco/` directory; capture findings into a
new `tests/integration/results-<date>-<company>-testco.md` file
following the existing report format (Acme/Beta/Gamma/Delta/Echo/
Foxtrot/Golf are the canonical examples).

### "tag vX.Y.Z"

Release ceremony. Verify in this order:

1. `gh pr checks <pr#>` shows lint green on the merged PR.
2. `tests/fixtures/testco/results/` has a green result file for at
   least the `single-project` (or `single-company` for company-only
   minor) scenario, dated within the last 7 days.
3. `git tag -a vX.Y.Z -m "<release notes>" && git push origin vX.Y.Z`.

If batch CI auto-trigger is configured (currently `workflow_dispatch`
only per ADR 0012 § Rationale for opt-in CI), the tag does NOT
auto-fire CI batch. Operator decides whether to manually dispatch
post-tag.

### "ultrareview" / "review questa PR"

Multi-agent cloud review. The user invokes `/ultrareview <PR#>` as a
slash command (it's billed and cloud-driven). I do not launch it
myself.

## Architecture pointers (for fast onboarding)

| Surface | Path | Purpose |
|---|---|---|
| Skill orchestrator | `JUVANT_OS.md` | Runtime entry point; Claude reads it for every operation |
| Invariants | `SYSTEM_INVARIANTS.md` | §1 Bootstrap, §4 Single-Writer + disclosure boundary, §5 Universal CONFIDENTIAL, §6 Spec auth, §7 |
| ADRs | `docs/adr/0001-NNNN.md` | Framework architectural decisions; ADR 0012 is the batch testco cornerstone |
| Schema | `scripts/schema.sql` | Turso DB schema (company-scope) |
| Batch infra | `scripts/run-testco-batch.sh`, `scripts/validate-batch-fixture.sh`, `scripts/templates/v0-agent-tool-matrix.json`, `tests/fixtures/testco/` | E2E test automation |
| Hooks | `hooks/*.sh` | Track 1 (confirmation), Track 2 (deny-list), Track 3 (audit log) per handbook ADR 0004 |
| Helpers | `helpers/*.{sh,ts}` | Scheduled scripts that populate Turso queues per FEAT-007 |

## What does NOT ship to adopters

The following are framework-development-only and removed (or replaced)
at company init by `scripts/compile-templates.sh --rewrite-meta`:

- `CLAUDE.md` (this file) → **replaced** with 3-line per-company stub
  from `scripts/templates/CLAUDE.md.template`.
- `tests/integration/results-*.md` (manual testco reports) → removed.
- `tests/fixtures/testco/results/*` (batch run results) → removed; the
  directory itself is preserved so adopters can store their own
  batch results there.
- `docs/adr/0001-NNNN.md` (framework ADRs) → removed; replaced with
  company-scope stub at `docs/adr/README.md`.

The README, CHANGELOG, SECURITY, and `docs/adr/README.md` of the
upstream framework get rewritten with company-specific content via
the same pipeline (F-16, v0.6.5+).
