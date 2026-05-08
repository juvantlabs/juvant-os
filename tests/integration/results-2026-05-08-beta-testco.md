# Integration result: 2026-05-08 — Beta Corp testco re-validation

Re-run of the FEAT-008 layer 4 dogfood after the v0.6.0 fix batch
(commits `a34a02f` ADR 0009 + symlinks; `d12fe10` trivial fixes batch).
Purpose: validate that the six findings shipped in those commits hold
end-to-end against a fresh bootstrap, and surface any further drift.

Acme Corp run is the antecedent record:
[`results-2026-05-08-acme-testco.md`](results-2026-05-08-acme-testco.md).

## Scope and method

| Field | Value |
|---|---|
| Test instance | `Beta Corp` (`beta-corp`), domain `beta.test`, CEO `John Smith` |
| Working tree | `/tmp/testco` (cloned from local `juvant-os` working copy on `release/v0.6.0-close-v1.0`) |
| Origin | `/tmp/testco-origin.git` (bare local repo) |
| Database | Local SQLite at `.juvant/state.db` |
| Channels / bank / backup | All stubbed |
| Doc storage | OneDrive declared, type-it path with `/Beta/<role>` placeholders |
| Wizard driver | Fresh Claude Code session, prompt `Initialize Juvant OS` |
| Outcome | **Bootstrap completed**; CSO audit PASS (vs Acme WARN-WITH-CONDITIONS); commit `d6d2a9c` pushed to bare origin |
| Teardown | `rm -rf /tmp/testco /tmp/testco-origin.git` |

## Validation matrix — Acme findings

| Finding | Severity | Acme outcome | Beta outcome | Notes |
|---|---|---|---|---|
| #1 `migrate.sh` local SQLite path | HIGH | ✗ blocked, manual `sqlite3` workaround | ✅ PASS | Step 2 completed via shipped script; no fallback needed |
| #2 "Common Juvant default" leak | MEDIUM | leaked at runtime | ✅ PASS | Bank options rendered with neutral one-line descriptions; "Juvant" absent from prompt |
| #4 `cso.md` self-referential `{{NAME}}` | HIGH | ✗ blocked Step 7 abort | ✅ PASS | Audit scan completed clean; only allowlisted `{{ACTIVE_PROJECT}}` survived in 2 templates (cos.md, eng-platform.md) |
| #6 Compiled agents not registered | CRITICAL | ✗ inline-briefing fallback | ✅ PASS — load-bearing | `Task(subagent_type='cso', ...)` resolved canonically; CSO bootstrap_baseline audit returned PASS |
| #7 `.gitignore` missing state.db | MEDIUM | manual patch by wizard | ✅ PASS | `.juvant/state.db` ignored from the start; not present in commit |
| #8 Step 10 git-add list incomplete | MEDIUM | `.github/CODEOWNERS` + `.gitignore` missed | ✅ PASS | Wizard staged the canonical extended list; working tree clean post-commit |

All six fixes held. No regressions observed in steps that previously
passed in the Acme run.

## New findings surfaced by the Beta run

The fixes uncovered three further gaps that the Acme run did not fully
expose. All are scoped MEDIUM–HIGH but **non-blocking for v1.0** — they
target adopter onboarding UX and wizard determinism, which the v1.0
release intentionally accepts as rough. Targeted to v1.1.

### #11 — Wizard prompt-format inconsistency across runs · MEDIUM

Same wizard step renders with different option shapes between Claude
sessions because `JUVANT_OS.md` describes WHAT to collect but not HOW
to render. Concrete divergences:

- **Step 1.5 (Folders)** — Beta run rendered "Skip / Discover / Type
  manually". Discover branch leaks the connector's tenant on cross-
  tenant setups; type-it became visible only because the CEO already
  knew to ask for it. Acme run handled this better because the Skill
  noticed the cross-tenant mismatch and offered an explicit bypass.
- **Step 3 (Bank)** — Wizard's own `[5] Other` affordance was not
  rendered as a menu choice; the CEO had to use the harness's generic
  `Type something` escape hatch. The wizard-domain "Other" path was
  invisible.
- **Step 5 (Counterparties)** — Acme run rendered a 4-option menu
  (Skip / Sample / Walk-through / Type). Beta run rendered a pipe-
  delimited freeform format `id | type | owner | email | name | role`
  with no menu and no per-record sub-flow. Hostile UX.

**Fix:** pin canonical option-menu blocks per wizard input step inside
`JUVANT_OS.md`. Each block specifies the standard affordances (Skip if
applicable, Recommended canonical, Alternative canned options,
Other/specify, harness-Chat) and the Skill renders verbatim — no
synthesis. Multi-row collection enters a per-record sub-flow, never
single-shot pipe-delimited.

### #12 — Wizard heredocs improvise; UX + correctness costs · HIGH

Wizard runs ~20 ad-hoc bash / python / sqlite3 heredoc operations per
bootstrap. Two costs:

- **UX**: each anonymous heredoc triggers a fresh Claude Code permission
  prompt. The conversational onboarding feel evaporates.
- **Correctness**: improvised SQL drifts from the actual schema. The
  Beta run's Step 8 `decisions` INSERT used columns
  `(category, summary, decided_by, content)` — none of these exist in
  `scripts/schema.sql:115`, which actually defines
  `(agent, title, category, rationale, status, approved_by,
  approved_at, ...)`. Different sessions guess differently: Acme run
  used the correct columns; Beta run failed at runtime. The inner
  Python helper that drafts manifestos also tripped a bash-heredoc
  escape error on the first attempt and required a `sed` rewrite.

Same root cause as #5 (substitution mechanics) and #11 (prompt
rendering): improvisation in place of shipped, named tooling.

**Fix:** ship the wizard's deterministic operations as named scripts
under `scripts/` (`compile-templates.sh`, `seed-matrix.sh`,
`cross-check-mcp.sh`, `draft-manifestos.sh`,
`audit-placeholders.sh`, `append-decision.sh`), update `JUVANT_OS.md`
to call them by name, and pre-allow them in `.claude/settings.json`.
Approval prompts per bootstrap should drop from ~20 to 0–3.

### #13 — `eng-platform` founding vs deferred-to-first-project · MEDIUM

Inconsistent treatment across artifacts:

- **ADR 0009** ships `.claude/agents/<role>.md` symlinks for **10**
  founding company-scope agents (excludes `eng-platform` as
  "cross-project infra, not Tier-1 founding").
- **Wizard Step 8 v0 matrix** (Beta run) seeded **11**
  `agent_tool_matrix` rows at company-init, INCLUDING `eng-platform`.
  The canonical v0 matrix as written in `coo.md` /
  `session-commit-p1.md` includes it.
- **Wizard Step 9 manifestos** (Beta run) drafted **11** manifestos
  including `eng-platform`. Acme run drafted **10** (founding only)
  and noted `eng-platform` as "optional".

So the same wizard, run twice on the same template, treated
`eng-platform` differently. The matrix says founding; the symlink
contract says optional; two runs split the difference.

**Fix (policy decision needed):**

(A) **`eng-platform` is fully founding** — ship its symlink, draft its
    manifesto at Step 9 unconditionally, count 11 founding. Update
    ADR 0009.

(B) **`eng-platform` is deferred** — remove from v0 matrix at company-
    init; matrix row + manifesto + symlink all materialize at first
    project bootstrap. ADR 0009 stays at 10 founding; `coo.md`
    canonical matrix needs updating.

Endpoint (B) aligns with the "cross-project infra" framing already in
ADR 0009. Endpoint (A) aligns with the v0 matrix as currently written.

## Recommendation for v1.0 PR

The six v1.0-blocking findings from the Acme run are validated closed.
ADR 0009 promoted from `Proposed` to `Accepted` on the strength of the
canonical `subagent_type='cso'` resolution observed in this run.

The release branch `release/v0.6.0-close-v1.0` is ready to PR toward
`main`. Open follow-ups (#11, #12, #13, plus the previously-deferred
#3, #5, #9, #10) become the v1.1 backlog.

The CSO bootstrap_baseline=1 audit returning PASS in the Beta run
(vs Acme WARN-WITH-CONDITIONS) provides additional evidence that the
fixes haven't introduced regressions in the manifesto / matrix /
audit pipeline.
