# ADR 0012 — Batch testco mode + CI integration

## Status

Accepted (2026-05-09). Validated end-to-end on 2026-05-09 by the first
green batch run against the `solo-founder-local-sqlite` scenario;
results captured at `tests/fixtures/testco/results/2026-05-09-solo-founder-local-sqlite.{jsonl,md}`.
27 assertions across 8 classes (verdict, manifests, decisions, matrix
rows, audit findings, pending orphans, matrix row spot checks,
filesystem) all passed; cost $1.96, 226s wall duration, 44 assistant
turns, 50 hook events. Three iterations to land determinism (proper
[BATCH] event emission, correct yq syntax, MANDATORY matrix-seed
decision row); each iteration ≤ 8 min.

Drives the v0.7.0 minor as the "automation" release. **Manual testco
remains the primary validation mode**; batch is an additional test-
automation layer that runs on CI for regression detection and faster
iteration on framework changes. The two are parallel layers covering
different surfaces (see § Coverage hybrid below).

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

### Progress feedback (first-class requirement, maximally informative)

The Skill emits structured progress events to stdout at every step
boundary, at every state-change event, and at every meaningful
checkpoint. Eight event types — designed so the driver can render
both a high-level step board AND a low-level activity stream:

```jsonl
[BATCH] {"ts":"2026-05-09T19:00:00Z","event":"run_start","scenario":"solo-founder-local-sqlite","fixture_version":"0.7.0","skill_version":"<commit>"}
[BATCH] {"ts":"2026-05-09T19:00:00Z","event":"step_start","step":"1","phase":"identity","total_steps":13}
[BATCH] {"ts":"2026-05-09T19:00:01Z","event":"input_resolved","step":"1","field":"company_name","value_redacted":false,"source":"fixture"}
[BATCH] {"ts":"2026-05-09T19:00:03Z","event":"step_done","step":"1","phase":"identity","duration_s":3.2,"tokens_in":847,"tokens_out":312}
[BATCH] {"ts":"2026-05-09T19:00:03Z","event":"step_start","step":"1.5","phase":"doc_storage","total_steps":13}
[BATCH] {"ts":"2026-05-09T19:00:07Z","event":"step_done","step":"1.5","phase":"doc_storage","duration_s":4.1,"tokens_in":1240,"tokens_out":420}
...
[BATCH] {"ts":"2026-05-09T19:01:42Z","event":"checkpoint","step":"8","detail":"agent_tool_matrix seeded","rows":20,"sql_tx_duration_ms":18}
[BATCH] {"ts":"2026-05-09T19:01:48Z","event":"checkpoint","step":"8.5","detail":"cross-check complete","findings":{"p0":0,"p1":0,"p2":3,"info":13}}
[BATCH] {"ts":"2026-05-09T19:02:00Z","event":"subagent_spawn","step":"9.7","subagent":"cso","reason":"bootstrap_baseline_audit"}
[BATCH] {"ts":"2026-05-09T19:02:12Z","event":"checkpoint","step":"9","detail":"manifestos approved","approved":7,"total":10}
[BATCH] {"ts":"2026-05-09T19:02:14Z","event":"step_done","step":"9","phase":"bootstrap","duration_s":24.0,"manifests":10,"verdict":"WARN-WITH-CONDITIONS"}
[BATCH] {"ts":"2026-05-09T19:02:18Z","event":"hook_activity","step":"10","detail":"PreToolUse summary","allowed":42,"denied":0,"pending_orphans":0}
[BATCH] {"ts":"2026-05-09T19:02:20Z","event":"run_complete","total_duration_s":156.4,"verdict":"PASS","tokens_total":34281,"tool_calls":{"Bash":42,"Read":19,"Write":12,"AskUserQuestion":0,"Agent":1,"TaskUpdate":18}}
```

Event taxonomy (eight types):

| Event | When | Payload |
|---|---|---|
| `run_start` | Skill enters batch mode | scenario, fixture_version, skill_version |
| `step_start` | Step boundary entry | step id, phase, total_steps |
| `input_resolved` | Each fixture lookup | step, field, source (fixture\|default), value_redacted (true if secret) |
| `checkpoint` | Mid-step state change worth surfacing | step, detail, structured payload |
| `subagent_spawn` | Task() call to a subagent | step, subagent role, reason |
| `hook_activity` | Hook summary at step boundary | step, detail, allowed/denied/orphan counts |
| `step_done` | Step boundary exit | step, phase, duration_s, tokens_in, tokens_out |
| `run_complete` | All steps complete (or failed) | total_duration_s, verdict, tokens_total, tool_calls breakdown |

Live progress board rendered by `scripts/run-testco-batch.sh`:

```
Juvant OS testco batch — scenario: solo-founder-local-sqlite
Skill version: 7e67302 (v0.6.6 + batch-mode)   Run: 2026-05-09T19:00:00Z

  ✓ Step 1     Identity            (3.2s)    847→312 tok
  ✓ Step 1.5   Doc storage         (4.1s)   1240→420 tok
  ✓ Step 1.5b  Mailboxes           (1.8s)    520→180 tok
  ✓ Step 1.6   GitHub user map     (0.9s)    320→ 95 tok
  ✓ Step 2     Database            (12.4s)  2840→610 tok
  ✓ Step 3     Bank                (5.3s)   1450→380 tok
  ✓ Step 4     Notifications       (3.7s)   1120→290 tok
  ✓ Step 4.5   Guardrails          (2.1s)    720→180 tok
  ✓ Step 5     Counterparties      (1.2s)    480→140 tok
  ✓ Step 6     Agent names + CRO   (4.8s)   1380→340 tok
  ✓ Step 7     Compile templates   (8.3s)   2210→520 tok       Bash: 4 ok
  ✓ Step 7.5/6 Render infra        (3.4s)    980→210 tok       Bash: 2 ok
  ✓ Step 8     Seed matrix         (1.1s)    410→ 95 tok       Bash: 1 ok, 20 rows seeded
  ✓ Step 8.5   Cross-check         (0.8s)    320→160 tok       findings: 0 P0, 0 P1, 3 P2 (status-pending), 13 info
  ▶ Step 9     Bootstrap protocol  (running 18.3s)              CSO subagent active, 7/10 manifestos approved
    Step 10    Initial commit      (pending)
    Step 10.5  Branch protection   (pending)

Cumulative: 53.2s · 14831→3932 tok · 9 Bash · 1 Agent · 0 denials · 0 orphans
```

Rendering:
- ANSI colors on TTY (`✓` green, `▶` yellow, `✗` red, dimmed for
  pending); plain on non-TTY.
- Live update on every `[BATCH]` event. The driver tails the
  Skill's stdout stream in real time and re-renders the board.
- Per-step the right-most column shows the most-recent
  `checkpoint` payload (matrix rows seeded, manifestos approved,
  audit findings count, etc.) — the operator can see *what* is
  happening, not just *that* something is happening.
- On CI the driver wraps each step in a `::group::` directive so
  GitHub Actions renders collapsible step output AND emits a
  job-summary table at completion (`$GITHUB_STEP_SUMMARY`) with
  per-step duration / token / tool-call breakdowns.
- Footer line shows cumulative budget consumption (duration,
  tokens in/out, tool-call counts, hook denials, orphan rows)
  for fast-glance regression detection.

The structured progress stream is persisted as
`tests/fixtures/testco/results/<date>-<scenario>.jsonl` (canonical)
plus a rendered Markdown summary at
`tests/fixtures/testco/results/<date>-<scenario>.md` (per-step
durations + total budget) for post-hoc diff against prior runs.
A regression that doubles a step's token usage or duration is now
visibly diff-able without re-deriving from raw logs.

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

> **Updated 2026-05-10**: this section originally proposed scenario
> tiering on tag pushes (major → full sweep, minor → primary). After
> the v0.7.0 baseline run on 2026-05-09, the CI workflow was
> simplified to **`workflow_dispatch` only** — no auto-trigger on
> tag push, no PR-label trigger. The canonical pre-release gate is
> the local run of `bash scripts/run-testco-batch.sh ...` on the
> operator's machine. The CI workflow remains as an opt-in re-run
> for cases where a GitHub-side audit artifact is wanted (adopter
> enterprises with their own credentials, occasional verification).
> See § Rationale for opt-in CI below.

`.github/workflows/testco-batch.yml` is `workflow_dispatch` only:

- Operator clicks "Run workflow" in the Actions tab.
- Inputs: `scenarios` (comma-separated list, or `"all"`; default
  `solo-founder-local-sqlite`).
- Three jobs: `resolve-matrix`, `validate-fixtures`, `batch`
  (one job per scenario in the resolved matrix).
- Cost: $0 by default; only the run-button click consumes tokens.

#### Rationale for opt-in CI

The framework has no platform-divergence surface — pure
bash/jq/sqlite3/yq, validated equally on Mac and Linux. CI re-running
on Linux would catch nothing that doesn't already fail in `lint.yml`
(already platform-tested via shellcheck). LLM-driven E2E tests are
slow (3-4 min) and per-run cost is non-trivial (~$2 at Opus). Auto-
firing on every minor tag adds latency to release cadence and cost
without proportional value. Solo-founder repository: forced gating
is autodiscipline via convention, not via tooling. Adopter enterprises
that want CI-gated releases fork the workflow and configure their
own auth + triggers.

```yaml
on:
  workflow_dispatch:
    inputs:
      scenarios:
        description: 'Comma-separated scenario list, or "all"'
        default: 'solo-founder-local-sqlite'
jobs:
  resolve-matrix:
    runs-on: ubuntu-latest
    outputs:
      scenarios: ${{ steps.set.outputs.scenarios }}
    steps:
      - id: set
        run: |
          # Pick scenarios from dispatch input; "all" expands to the
          # full list under tests/fixtures/testco/.
          ...
  validate-fixtures: ...
  batch:
    needs: [resolve-matrix, validate-fixtures]
    strategy:
      fail-fast: false
      matrix:
        scenario: ${{ fromJSON(needs.resolve-matrix.outputs.scenarios) }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install dependencies
        run: |
          sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
          sudo chmod +x /usr/local/bin/yq
      - name: Install Claude Code CLI
        run: npm install -g @anthropic-ai/claude-code
      - name: Run batch testco
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        run: bash scripts/run-testco-batch.sh tests/fixtures/testco/${{ matrix.scenario }}.yaml --no-render
      - if: always()
        uses: actions/upload-artifact@v4
        with:
          name: batch-${{ matrix.scenario }}-${{ github.run_id }}
          path: |
            tests/fixtures/testco/results/
            /tmp/testco-batch-*/.juvant/state.db
            /tmp/testco-batch-*/session.log
            /tmp/testco-batch-*/events.jsonl
```

Cost discipline: zero by default. Only fires when an operator
explicitly clicks "Run workflow" with a scenario list.

#### Auth path

The shipped workflow uses `ANTHROPIC_API_KEY` repo secret as the
default auth path. Adopters can swap to one of the supported
Claude Code backends without touching the driver:

- **Microsoft Foundry** (`CLAUDE_CODE_USE_FOUNDRY=1` +
  `ANTHROPIC_FOUNDRY_RESOURCE` + `azure/login@v2` OIDC step) —
  Azure billing path, Entra ID federated credentials, no static
  API key. Recommended for adopters with existing Azure / EA contracts.
- **AWS Bedrock** (`CLAUDE_CODE_USE_BEDROCK=1` + AWS creds via
  `aws-actions/configure-aws-credentials@v4` OIDC) — AWS billing,
  IAM federated credentials.
- **Google Vertex AI** (`CLAUDE_CODE_USE_VERTEX=1` + GCP creds via
  `google-github-actions/auth@v2` workload identity) — GCP billing.
- **Anthropic direct** (`ANTHROPIC_API_KEY` static repo secret) —
  simplest, what the shipped workflow uses.

Auth path is a fork-time decision per adopter; we don't bake any
single path into the upstream workflow.

### Coverage hybrid

**Manual testco is the primary validation mode.** A human operator
driving `claude` end-to-end remains the load-bearing exercise of the
framework — it catches what an LLM-driven test cannot evaluate:
prose quality, prompt fatigue, first-impression friction, the gap
between "the wizard works" and "a new CEO can actually use this".

**Batch is a CI test-automation layer.** It runs in addition to
manual testco, not instead of it. The two cover different surfaces:

| Surface | Gate | Frequency | Catches |
|---|---|---|---|
| Schema integrity, matrix correctness, hooks routing, ADR compliance, audit verdict, regression in step durations / token budget | Batch (local pre-release; CI on-demand opt-in) | Pre-release on operator's machine; CI when GitHub-side audit artifact is wanted | Determinism regressions, structural drift, performance degradation |
| Wizard wording, collection-collapse readability, prompt fatigue, first-impression UX, Skill judgment quality | Manual testco | When CEO drives a real or shadow company-init | F-4/F-5/F-15-class UX issues that batch is structurally blind to |

Manual testco reports stay at `tests/integration/results-<date>-<company>-testco.md`
(narrative-style write-ups). Batch reports land at
`tests/fixtures/testco/results/<date>-<scenario>.{jsonl,md}` (mechanical,
diff-friendly artifacts).

Manual remains primary because:

1. The wizard is meant to be used by humans. The only test that
   answers "is this usable?" is a human using it.
2. New findings classes (F-21 doc/script schema drift; F-22 hook
   orphan tracking) routinely surface from manual runs in ways batch
   would not have caught — the human notices "this seems wrong" in
   places the assertion language doesn't cover.
3. Batch can lock in determinism for *known* surfaces. It cannot
   discover *new* surfaces. Manual is the discovery channel.

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
