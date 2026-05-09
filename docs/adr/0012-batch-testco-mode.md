# ADR 0012 — Batch testco mode + CI integration

## Status

Proposed (2026-05-09). Drives the v0.7.0 minor as the "automation"
release. Replaces manual testco runs as the primary integrity gate;
manual testco is retained as a quarterly UX-validation gate (see
§ Coverage hybrid below).

## Context

The framework's correctness has been validated to date by a sequence of
**manual testco runs**: a human operator drives `claude` in a separate
terminal through the JUVANT_OS Skill's company-init wizard, while the
orchestrator observes via session log + live SQL queries against the
test instance's `.juvant/state.db`. Six runs to date — Acme, Beta,
Gamma, Delta, Echo, Foxtrot, Golf — each surfacing 2–10 findings (F-1
through F-22) that flow into the next minor release.

This pattern is **a compromise**, not a product. It works because the
operator and orchestrator are the same person (or work-pair). It does
not scale, has three structural problems:

1. **Determinism**. The Skill is an LLM agent. Each run improvises
   slightly different prose for the same wizard step. The matrix
   self-correction at Step 8.5 (F-12) was masked across runs precisely
   because each run "fixed it" differently. We caught the masking only
   because the Golf run was instrumented to capture the pre/post matrix
   state — and even that capture path was a best-effort prompt added at
   session start, not a deterministic mechanism.

2. **Coverage**. Each manual run exercises one scenario (one DB
   provider, one bank choice, one CRO state, one CEO archetype). Other
   scenarios — multi-project at company init, multi-principal
   ratification (FEAT-022), Turso Cloud, CRO disabled, mailboxes
   disabled — are never exercised because each manual run costs ~30
   minutes of operator time. Six runs across seven minors is far below
   the actual scenario surface.

3. **Regression detection**. The "is the wizard producing the right
   `agent_tool_matrix`" question is checked once at run time by
   eyeballing SQL output. There is no reproducible artifact captured;
   no diff against a previous baseline; no fail-loud signal to CI when
   an upstream change quietly breaks Step 8 seeding (caught locally
   only by the v0.6.6 smoke test of `seed-matrix.sh`, which is itself
   a one-off bash script).

The Foxtrot run was the planned last manual run. Echo, Golf, and the
considered Hotel run are drift — each one was a 30-minute compromise
masking the absence of automation. v0.7.0 closes this drift.

## Decision

Introduce **batch mode** for the JUVANT_OS Skill: a deterministic,
scenario-driven activation path that replaces every interactive
prompt with a lookup into a pre-staged YAML fixture, captures
end-to-end state and diff, and runs as a GitHub Actions workflow on
every minor and major release tag.

### Activation

Batch mode activates when the Skill's invoking prompt cites a fixture
path with the literal phrase:

> *"Initialize Juvant OS using batch inputs from `<path>`"*

The Skill at SessionStart parses the prompt, sets `batch_mode=1` in
its session-local state, and reads the fixture at `<path>`. If the
file is missing, malformed, or fails schema validation, the Skill
refuses to proceed and exits with a structured error (no fallback
to interactive — fail-loud).

### Schema

`tests/fixtures/testco/<scenario>.yaml` — one file per scenario.
Schema covers all 12 wizard steps + an `expect:` block consumed by
the driver's post-run assertions. Top-level structure:

```yaml
scenario: <slug>                    # e.g. solo-founder-local-sqlite
juvant_os_version: <semver>         # version this fixture targets
inputs:
  identity: { ... }
  doc_storage: { ... }
  github_user_map: { ... }
  database: { provider, ... }
  bank: { ... }
  notifications: { ... }
  guardrails: { ... }
  counterparties: { ... }
  agent_names: { ... }
  cro_enabled: <bool>
expect:
  bootstrap_verdict: <PASS|WARN-WITH-CONDITIONS|FAIL>
  manifests_count: 10
  decisions_count: <int>
  matrix_rows_count: 20
  audit_findings_p0_p1: 0
  audit_findings_p2_max: 3
  matrix_row_assertions:
    - { role: cos, channels_includes: telegram:send-ceo-only }
    - { role: eng-platform, scope: company }
    - { role: cfo, mcp_servers_includes: [m365-graph, fattura_elettronica] }
  filesystem_assertions:
    - { path: README.md, must_contain: "<company_name>" }
    - { path: docs/adr/0001-*.md, must_not_exist: true }
    - { path: .github/CODEOWNERS, must_contain: "@<github_user_map.ceo>" }
```

Schema is versioned (`juvant_os_version`) so fixtures stay coherent
across minor bumps; mismatches between fixture target and current
repo version produce a warning (not a fail) so old fixtures stay
readable.

### Skill modifications

`JUVANT_OS.md` gains a **Batch Mode** section before the wizard
preamble:

> **Batch Mode (HARD-REQUIRED behavior when `batch_mode=1`)**:
>
> 1. Replace every `AskUserQuestion` call with a lookup into
>    `inputs.<step_id>.<field>` from the loaded fixture. If the
>    field is missing, **fail loud** — do not improvise, do not
>    fall back to defaults.
> 2. Skip every "wait for user confirmation" pause. Tool approval
>    is handled by the driver via `--permission-mode bypassPermissions`.
> 3. Emit a structured progress event at every step boundary
>    (see § Progress feedback below).
> 4. Skip every collection-collapse menu — directly walk
>    `inputs.<collection>.<list>` deterministically.
> 5. Refuse to write any file outside `<repo>/`, `/tmp/<batch-slug>/`,
>    or `.juvant/` — the batch driver mounts no other surfaces.

Each step in the wizard prose retains its interactive description but
gets a `**Batch lookup**:` line specifying the fixture key. This is
the dual-path pattern: same Skill code, two activation modes, no
duplicated logic.

### Progress feedback (first-class requirement)

The Skill emits structured progress events to stdout at every step
boundary and at every state-change event:

```
[BATCH] {"ts":"2026-05-09T19:00:00Z","event":"step_start","step":"1","phase":"identity"}
[BATCH] {"ts":"2026-05-09T19:00:03Z","event":"step_done","step":"1","phase":"identity","duration_s":3.2}
[BATCH] {"ts":"2026-05-09T19:00:03Z","event":"step_start","step":"1.5","phase":"doc_storage"}
[BATCH] {"ts":"2026-05-09T19:00:07Z","event":"step_done","step":"1.5","phase":"doc_storage","duration_s":4.1}
...
[BATCH] {"ts":"2026-05-09T19:01:42Z","event":"checkpoint","step":"8","detail":"agent_tool_matrix seeded","rows":20}
[BATCH] {"ts":"2026-05-09T19:01:48Z","event":"checkpoint","step":"8.5","detail":"cross-check","findings_p1":0,"findings_p2":3}
[BATCH] {"ts":"2026-05-09T19:02:14Z","event":"step_done","step":"9","phase":"bootstrap","duration_s":24.0,"manifests":10,"verdict":"WARN-WITH-CONDITIONS"}
[BATCH] {"ts":"2026-05-09T19:02:20Z","event":"complete","total_duration_s":156.4,"verdict":"PASS"}
```

The driver `scripts/run-testco-batch.sh` parses these lines and
renders a live progress board to a controlling terminal:

```
Juvant OS testco batch — scenario: solo-founder-local-sqlite

  ✓ Step 1     Identity            (3.2s)
  ✓ Step 1.5   Doc storage         (4.1s)
  ✓ Step 1.5b  Mailboxes           (1.8s)
  ✓ Step 1.6   GitHub user map     (0.9s)
  ✓ Step 2     Database            (12.4s)
  ✓ Step 3     Bank                (5.3s)
  ✓ Step 4     Notifications       (3.7s)
  ✓ Step 4.5   Guardrails          (2.1s)
  ✓ Step 5     Counterparties      (1.2s)
  ✓ Step 6     Agent names + CRO   (4.8s)
  ✓ Step 7     Compile templates   (8.3s)
  ✓ Step 7.5/6 Render infra        (3.4s)
  ✓ Step 8     Seed matrix         (1.1s)
  ✓ Step 8.5   Cross-check         (0.8s)   findings: 0 P1, 3 P2 (status-pending)
  ▶ Step 9     Bootstrap protocol  (running... 18.3s, 7/10 manifestos)
    Step 10    Initial commit      (pending)
    Step 10.5  Branch protection   (pending)
```

Rendering:
- ANSI colors on TTY (`✓` green, `▶` yellow, `✗` red); plain on
  non-TTY.
- Live update on `[BATCH] step_*` events. The driver tails the
  Skill's stdout stream in real time.
- On CI the driver wraps each step in a `::group::` directive so
  GitHub Actions renders collapsible step output.

The structured progress stream is also persisted as
`tests/fixtures/testco/results/<date>-<scenario>.jsonl` for
post-hoc analysis (per-step durations as a regression signal).

### Driver

`scripts/run-testco-batch.sh <scenario.yaml> [--db local|turso] [--keep-tmp]`:

1. Validate fixture schema (jq + a small validator script).
2. Stage `/tmp/testco-batch-<slug>/` with bare origin + cloned repo
   at current HEAD.
3. Render `.juvant/batch-inputs.yaml` from fixture (strip the
   `expect:` block, the Skill never sees expectations).
4. Run database migration (`scripts/migrate.sh`).
5. Spawn `claude --print --permission-mode bypassPermissions
   "Initialize Juvant OS using batch inputs from .juvant/batch-inputs.yaml"`.
6. Tail stdout, parse `[BATCH]` events, render progress board.
7. On `event: complete`, run post-run assertions against `expect:`.
8. Exit non-zero if any assertion fails. Print a structured failure
   summary (which assertion, expected, actual).
9. Optionally clean up `/tmp/testco-batch-<slug>/` (default yes;
   `--keep-tmp` retains for debugging).

### CI workflow

`.github/workflows/testco-batch.yml`:

```yaml
on:
  push:
    tags: ['v[0-9]+.[0-9]+.0']      # every minor (X.Y.0) including majors (X.0.0)
  workflow_dispatch:
  pull_request:
    types: [labeled]
    # fires when label "run:batch" added; opt-in for pre-release validation
jobs:
  batch:
    if: github.event_name != 'pull_request' || contains(github.event.pull_request.labels.*.name, 'run:batch')
    strategy:
      fail-fast: false
      matrix:
        scenario:
          - solo-founder-local-sqlite
          - solo-founder-turso-cloud
          - multi-project-local-sqlite
          # multi-principal: FEAT-022, lands in v0.7.x
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: bash scripts/run-testco-batch.sh tests/fixtures/testco/${{ matrix.scenario }}.yaml
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
      - if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: batch-${{ matrix.scenario }}-failure
          path: |
            /tmp/testco-batch-*/
            tests/fixtures/testco/results/
```

Tag-pinned: tags are immutable, so a release CI run is reproducible
against the exact tagged commit. PR-label opt-in lets us run batch
validation on any PR that touches Skill flow files (JUVANT_OS.md,
scripts/, hooks/, agents/company/) before merge.

### Coverage hybrid

Batch is the **integrity gate**, not a replacement for the manual
testco. Distinction:

| Surface | Gate | Frequency | Catches |
|---|---|---|---|
| Schema, matrix correctness, hooks, ADRs, audit verdict | Batch CI | Every release tag + opt-in PR | Determinism regressions |
| Wizard wording, collection-collapse readability, prompt fatigue, first-impression UX | Manual testco | Quarterly or when CEO drives | F-4/F-5/F-15-class UX issues |

Manual testco reports stay at `tests/integration/results-<date>-<company>-testco.md`;
batch reports land at `tests/fixtures/testco/results/<date>-<scenario>.jsonl`.

## Consequences

**Positive**:

- Determinism. Same input, same output across runs and machines.
  Regression detection is mechanical.
- Coverage. Multiple scenarios per release at zero operator cost.
  Multi-principal, multi-project, alternative DB providers all
  exercised.
- Velocity. Findings get caught at PR review time (opt-in label) or
  at release time (tag push), not at next manual run several days
  later.
- Reproducibility. Batch fixtures are versioned; the bug that broke
  Echo's seed-matrix path can be replayed forever from `tests/fixtures/`.
- Documentation. Each scenario's YAML is the canonical
  declarative description of "this is what a Local SQLite solo founder
  bootstrap looks like" — better than prose.

**Negative**:

- Skill complexity. The Skill gains a dual path (interactive vs
  batch). Mitigated by surfacing the lookup table at each step
  (one source of truth) and the fail-loud rule (any missing
  fixture entry breaks the run loudly, not silently).
- Initial implementation cost. Per § Scope below: 1-2 days of
  focused work before the first scenario runs end-to-end on CI.
  The first 2-3 batch runs will fail because the Skill improvises
  somewhere unexpected; iteration loop is unavoidable.
- Anthropic API cost on CI. Each batch run consumes ~30k tokens
  on the Skill's bootstrap walk. Per release at 4 scenarios,
  ~120k tokens × pricing. Tracked as ops cost; revisit if
  release cadence accelerates.

**Neutral**:

- Manual testco is not deprecated. UX validation is structurally
  out of scope for a deterministic LLM-driven test (LLM is
  *deciding* the wording; we cannot assert the wording is good).
- Batch fixtures live in the repo; no external test framework
  dependency. Bash + jq + sqlite3 + curl-to-Anthropic-API are
  the only runtime requirements.

## Scope (v0.7.0)

Phase 0 — this ADR (Proposed → Accepted on first batch run green).

Phase 1 — Skill plumbing:
- `JUVANT_OS.md` Batch Mode preamble + per-step batch lookup lines.
- Schema validator (`scripts/validate-batch-fixture.sh`).
- Driver (`scripts/run-testco-batch.sh`) with progress board.
- First fixture (`tests/fixtures/testco/solo-founder-local-sqlite.yaml`).
- CI workflow (`.github/workflows/testco-batch.yml`).
- Iterate on the first scenario until determinism holds.

Phase 2 — coverage scenarios:
- `multi-project-local-sqlite.yaml` (project-scope agents exercised).
- `solo-founder-turso-cloud.yaml` (cloud DB provider path).
- Backfill: each prior `tests/integration/results-*-testco.md` gets a
  matching `tests/fixtures/testco/<company>.yaml` so old runs are
  reproducible from fixtures.

Phase 3 (v0.7.1+) — multi-principal scenario per FEAT-022.

## Cross-references

- Drift narrative: `tests/integration/results-2026-05-09-golf-testco.md`
  conclusion paragraph + the v0.6.6 cumulative-plan section.
- Manual testco invariants this batch must reproduce:
  `SYSTEM_INVARIANTS.md` §1 Bootstrap Protocol; §4 Single-Writer +
  disclosure-boundary corollary; ADR 0010 (subagent canonical spawn);
  ADR 0011 (`<channel>:send-ceo-only` carve-out); F-7/F-8/F-12/F-16/F-17/F-19/F-20/F-21/F-22.
- Test fixture provenance:
  `tests/fixtures/matrix/2026-05-09-golf-corrected.json` is the seed
  for the first batch fixture's `expect.matrix_row_assertions:` block.
- v0.7.0 release notes (TBD): batch mode is the headline.
