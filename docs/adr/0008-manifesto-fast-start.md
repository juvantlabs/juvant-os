# ADR 0008 — Manifesto fast-start: Tier 1 blocking, Tier 2 async 7-day

## Status

Accepted (2026-04-23). Promoted from `juvantlabs/juvant-os-pm#8` (ARCH-008) on
2026-05-02. Augmented 2026-05-01 by `SYSTEM_INVARIANTS.md` §1 (Bootstrap
Protocol) for the chicken-and-egg problem at company / project init.

## Context

Every agent operates under a manifesto — a declaration of identity, scope,
ethical commitments, and anti-patterns, approved by the relevant authorities
before the agent acquires domain authority. Requiring full manifesto approval
across all agents before *any* agent can operate would push company
operationalization past a useful cadence.

At the same time, manifestos are not a formality — they encode the decisions
the agent will defer to and the boundaries it will not cross. They have to be
reviewed.

## Decision

Two-tier manifesto approval:

### Tier 1 — Blocking

The agent cannot enter `OPERATIONAL` until Tier 1 approval is on file.

- **Company-scope agents** — joint approval by CHRO + CA.
- **Project-scope agents** — sole approval by the project's CTO.

### Tier 2 — Async (7-day window)

Other agents review and may flag concerns; silence after 7 days = pass.

- **Company-scope Tier 2 reviewers** — CSO, CEthO, CMO, CCO, CFO, CLO, CRO.
- **Project-scope Tier 2 reviewers** — CPO, CDO, COO, VPE.

### Restricted mode

Between Tier 1 approval and Tier 2 clearance, the agent is `OPERATIONAL_RESTRICTED`.
It executes routine tasks but cannot make domain decisions. All outputs carry
a `[MANIFESTO PENDING]` prefix. Per-role restrictions are enumerated in each
template (e.g. CFO restricted cannot authorize transactions above
`{{HIGH_VALUE_THRESHOLD}}`; CLO restricted cannot finalize disclosure-policy
edits; CTO restricted cannot approve project-scope Tier 1 manifestos).

### Bootstrap Protocol (chicken-and-egg)

At company / project init, no Tier 1 reviewer has a manifesto yet — the
standard flow cannot start. SYSTEM_INVARIANTS.md §1 resolves this:

- A one-shot CEO-only override approves the founding 19 manifestos at company
  init (`tier1_bootstrap=1`, `precondition_bypassed='bootstrap'`).
- CSO performs a `bootstrap_baseline=1` audit immediately after.
- A project-scope analog (`precondition_bypassed='project-bootstrap'`) handles
  new projects added to an established company.

## Consequences

Positive:

- A new company is operational in roughly 10 minutes, a new project in 5.
- Tier 1 is small (two reviewers for company, one for project) — review is
  tractable.
- Tier 2 is async — broad participation without serial blocking.
- Restricted mode preserves safety: an unreviewed agent does not silently
  acquire domain authority.

Negative:

- Tier 2 silence-equals-pass shifts review responsibility to the reviewers. CSO
  Layer 5 audits include sampling of Tier-2-passed manifestos to detect
  rubber-stamping.
- Bootstrap Protocol is one-shot per company; recovery from a corrupted
  bootstrap is `rm -rf .juvant/` plus re-running the wizard. There is no
  partial-bootstrap recovery path.

## Timing targets

- Company operational in ~10 minutes from `Initialize Juvant OS`.
- Project operational in ~5 minutes from `Initialize project <slug>`.

## Implementation

- `JUVANT_OS.md` § "Manifesto review flow" — Tier 1 / Tier 2, restricted mode,
  CSO precondition (bypassed at bootstrap).
- `JUVANT_OS.md` § "Company setup" Step 9 — Bootstrap Protocol §1 wizard.
- `JUVANT_OS.md` § "Project setup" Step 5 — project-bootstrap analog.
- `scripts/schema.sql` — `manifests` table with `tier1_bootstrap`,
  `precondition_bypassed`, `bootstrap_baseline` flags.
- `agents/company/chro.md`, `ca.md`, `cso.md` — Tier 1 evaluators and
  precondition gate.
- `agents/projects/cto.md` — project-scope Tier 1 sole approver and project-
  bootstrap analog.

## References

- `SYSTEM_INVARIANTS.md` §1 (Bootstrap Protocol).
- `juvantlabs/juvant-os-pm/docs/session-commit-p1.md` — Manifesto Approval — Fast Start.
