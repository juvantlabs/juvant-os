# ADR 0010 — Compiled agent templates must register in `.claude/agents/`

## Status

Accepted (2026-05-08). Surfaced by the Acme Corp testco bootstrap
documented in `tests/integration/results-2026-05-08-acme-testco.md`
(finding #6, severity CRITICAL); validated end-to-end by the Beta Corp
testco re-run on the same date, where `Task(subagent_type='cso', ...)`
resolved through the canonical path and the CSO bootstrap_baseline audit
returned PASS without any inline-briefing fallback.

## Context

The framework keeps agent templates under `agents/company/*.md` (10
founding company-scope agents) and `agents/projects/*.md` (5 project-
scope leadership + 4 Eng/* agents). This layout is documented in the
top-level README and is load-bearing for human navigation: adopters
exploring the repository expect to find agent definitions there.

Claude Code's Task tool, however, resolves the `subagent_type`
parameter by reading agent definitions from `.claude/agents/<role>.md`.
Definitions outside that directory are invisible to the Task runtime.

The `JUVANT_OS.md` company-init wizard at Step 7 substitutes
`{{PLACEHOLDER}}` tokens in `agents/company/*.md` and never writes to
`.claude/agents/`. As a consequence, a freshly initialized adopter
cannot spawn any framework subagent through the canonical contract:

```python
Task(subagent_type="cso", prompt="Run bootstrap_baseline=1 audit...")
```

The runtime returns "no such subagent registered" and the Skill must
either fall back to `subagent_type="general-purpose"` with the compiled
agent's body pasted as inline briefing, or refuse to proceed.

The Acme Corp testco run hit this gap immediately at Step 9 (Bootstrap
Protocol §1 step 7 — first CSO audit). The inner Claude session
recognized the missing registration and routed around it with an inline
briefing. That graceful degradation kept the testco moving but masks a
structural break: every subsequent SPawn — CSO audits, CFO drafts, CLO
compliance reviews, CoS Morning Brief, project-init `Task(cto, ...)` —
is in the same broken state on every adopter.

The framework's contract that `subagent_type='<role>'` resolves to the
compiled role-specific template is not honored by the layout.

## Decision

The wizard's compilation step writes each compiled agent template to
**two locations**:

1. `agents/company/<role>.md` — the documented home, source of truth
   for human navigation, version control, and PR review.
2. `.claude/agents/<role>.md` — the runtime registration that Claude
   Code's Task tool resolves.

The two locations stay in sync via a **symlink** from
`.claude/agents/<role>.md` → `../../agents/company/<role>.md` (relative
symlink). The OSS template ships with the symlinks already present;
the wizard's substitution writes to `agents/company/<role>.md`, and the
symlink ensures `.claude/agents/<role>.md` reflects the substituted
content automatically. Project-scope agents follow the same pattern via
`.claude/agents/<project>-<role>.md` symlinking to
`agents/projects/<role>.md` after project-init.

Symlinks are chosen over post-substitution copy because:

- Single source of truth at write time eliminates the drift risk a
  copy-based approach introduces.
- Symlinks are first-class in git (mode 120000) and work on the
  framework's macOS target (per ADR 0001).
- The substitution helper specified in the v1.1 follow-up
  (`scripts/compile-templates.sh`) writes to one path per agent
  instead of two, simplifying the script's contract.

Adopters needing to support a non-symlink-friendly environment may
override with the `--copy-mode` flag on the substitution helper, which
materializes `.claude/agents/<role>.md` as a regular file. This is an
escape hatch; the documented default is symlink-based.

## Consequences

Positive:

- The canonical contract `Task(subagent_type='<role>', ...)` resolves
  on every adopter without manual setup. The Skill no longer needs the
  inline-briefing workaround applied during the testco run.
- Source of truth stays at `agents/<scope>/<role>.md`, preserving the
  documented repository layout and the navigation experience for
  adopters.
- Future architecture work that depends on Task spawn (FEAT-008 layer 3
  scenarios, the FEAT-022 multi-principal coordination work) inherits a
  working subagent surface.

Negative:

- Symlinks committed to the OSS template add one layer of indirection
  for adopters auditing what `.claude/agents/<role>.md` resolves to.
  The README must call this out.
- A future Claude Code change to subagent-registration semantics could
  break the indirection. Mitigation: the symlink contract is local to
  the framework's repo and easy to refactor (move the substitution
  output, drop the symlinks).
- Copy-mode escape hatch creates a second supported configuration that
  the substitution helper must keep correct. Test coverage for both
  modes belongs in the helper's unit tests.

## Implementation

The fix lands in the `release/v0.6.0-close-v1.0` branch as a v1.0
blocker:

1. Add `.claude/agents/<role>.md` symlinks for the 10 founding
   company-scope agents (CoS, CFO, CLO, CMO, CCO, CHRO, CSO, CEthO, CA,
   CRO) targeting `../../agents/company/<role>.md`. The
   `eng-platform`-style optional agent registers when bootstrapped.
2. Update `JUVANT_OS.md` Step 7 to note that substitution is written
   only to `agents/company/<role>.md`; runtime registration is implicit
   via the shipped symlinks. Project-scope analog at the project-init
   procedure.
3. Update `README.md` to document the symlink layer alongside the
   `agents/` and `.claude/` summaries.
4. Re-run the Acme Corp testco bootstrap to verify
   `Task(subagent_type='cso', ...)` resolves end-to-end without inline
   briefing. Confirm via the CSO bootstrap_baseline audit completing
   through the canonical path.

The substitution helper (`scripts/compile-templates.sh`, deferred to
v1.1 per finding #5) implements the `--copy-mode` escape hatch as part
of its first version.

## References

- `tests/integration/results-2026-05-08-acme-testco.md` — finding #6.
- `JUVANT_OS.md` § Company setup, Step 7 — substitution scope.
- `SYSTEM_INVARIANTS.md` §1 — Bootstrap Protocol step 7 (CSO audit
  spawn).
- ADR 0001 — Skill-first architecture (macOS target context).
- ADR 0006 — CA owns the agent tool matrix; matrix is compiled into
  subagent frontmatter (related compilation contract).
