# ADR 0037 — Manifesto sign-offs in `decisions`, Upstream sync as the only agent upgrade path

## Status

**Accepted** — 2026-11-05 (CEO-approved). Origin: BUG-079. **Amends** ADR 0008
(manifesto fast-start). Corrected the same day by BUG-101: v1.21.1 had made Tier 2
blocking with three required signers, against ADR 0008. Tier 2 is async again.

## Context

`agents/company/chro.md` described a `manifests` row of about 25 columns, which
`scripts/schema.sql` never had. Three things could not run: the versioning
procedure, Tier 1 sign-offs and the `restricted` flag. The status vocabularies
also disagreed: the setup wrote `pending` and the reviewers looked for `draft`.

Versioning had no data source. Nothing populated `upstream_*` or `installed_*`,
and agent templates carry no version. It also assumed upgrades agent by agent,
while the Upstream sync applies the framework in one step.

## Decision

1. **A sign-off is a `decisions` row written by the signer**, in category
   `manifesto-tier1` or `manifesto-tier2`, pointing at the manifest through
   `source_ref`. Tier 1 sign-offs are required. At Tier 2 a `rejected` row is an
   objection, and silence after 7 days is a pass, as in ADR 0008. `operational`
   is the CEO's transition and takes the window closed with no objection.
2. **Each review cycle is a new `manifests` row.** The previous row becomes
   `superseded`. Sign-offs point at a row id, so they can't carry over to a later
   cycle.
3. **`manifests` gains no columns.** `pending` is the single initial status, and
   `[MANIFESTO PENDING]` derives from `status`.
4. **Upstream sync is the only agent upgrade path.** It lists agents with a
   frontmatter change, and CEthO is consulted on them before the CEO decides.
   After the merge, CHRO updates `manifests.version` and starts a new review
   cycle for those agents.

The mechanics are in `SYSTEM_INVARIANTS.md` §1.

## Consequences

- Sign-offs inherit the immutability of `decisions`, and the writer rules don't
  change: every signer already writes its own decisions.
- A company-scope reviewer can't write to a project DB after bootstrap, so its
  sign-offs on project manifestos live in the company DB. PCA reads them there to
  make the transition.
- A sync no longer reviews every changed template. Only frontmatter changes start
  a review cycle, otherwise each release would reopen Tier 1 for most agents. A
  change to a template's body is reviewed only as part of the sync itself.
- CEO approval can't replace Tier 1. It can force activation over a Tier 2
  objection, and that leaves a `decisions` row.

## Alternatives considered

- **Sign-off columns on `manifests`.** Rejected: a mutable row lets a sign-off be
  overwritten, and CTO would need a write right on the table.
- **Version columns or a version table, with a helper reading upstream.** Rejected:
  a large build for a per-agent flow that conflicts with the single sync.
