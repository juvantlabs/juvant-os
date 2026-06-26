# ADR 0027 — Separate the framework agent **template** from the compiled **output**; propagate canon by `{{INCLUDE}}` transclusion + an instance overlay

## Status

Proposed (2026-06-27). The **structural** end-state for agent-template
propagation. The **near-term** fix (apply only the canonical delta, using the
`version:` stamp as the merge base — no whole-file checkout) is FEAT-058 and
ships first; this ADR is the refactor that removes the underlying conflation so
the problem stops recurring. Significant change to the compile model + a
migration for existing instances — Proposed, to be refined before implementation.

## Context

An instance's agent files (`agents/company/*.md`,
`agents/components/<slug>/maintainer.md`, `agents/projects/<slug>/*`) are a
**conflation of three different kinds of content in one file at one path**:

1. **Framework-canonical content** — role duties, protocol sections, cross-cutting
   rules (e.g. the ADR-0026 authorization clause). Owned by the framework; should
   propagate to every instance.
2. **Instance-compiled content** — placeholder substitutions (real agent/company
   names) plus instance-era wiring (the `Refer to MANIFESTO.md` identity block,
   the `version:` stamp). Generated; instance-specific.
3. **Instance hand-customizations** — anything the operator edited. Must survive.

Because the same file at the same path is **both the framework template and the
compiled output**, the framework cannot update (1) without clobbering (2)/(3).
The current policy resolves this by marking these files **NEVER-touched** by
upstream-sync — which protects (2)/(3) but means (1) **never reaches an existing
instance**. Consequences observed live:

- A blind `git checkout upstream/main -- <file>` (the naive adoption) **deletes
  the MANIFESTO block + version stamp**, jumps the file forward N versions
  wholesale, and de-syncs the touched files from the untouched ones.
- Instances **drift**: a real instance's company templates were frozen at
  **v1.2.0** while the framework was at **v1.10.0** — 8 versions behind.
- ADR-0026 also showed that moving canon to a *referenced* synced file is not
  enough: agents do **not** reliably defer to referenced canon (`eng-platform`
  kept deadlocking until the clause was inlined in *its own* prompt). So canon
  must end up **inlined in the prompt**, yet live in a single synced source.

FEAT-058 (delta-apply) stops the bleeding without a refactor. This ADR removes
the conflation that makes the bleeding possible.

## Decision

Split the one conflated file into **three explicit layers**:

1. **Framework template** (`agents/.../*.md` upstream — **synced**, no longer
   never-touched): placeholders + `{{INCLUDE: <canon-fragment>}}` directives.
   Pure framework content; carries **no** instance data.
2. **Compiled output** (instance-owned, **generated** — the runtime prompt that
   Claude Code loads): produced by `compile-templates` from the template + the
   instance overlay + the included canon fragments, with placeholders
   substituted. Regenerable; never hand-edited.
3. **Instance overlay** (**never-touched**): the instance-era content — the
   MANIFESTO/identity wiring, the `version:` stamp, and any operator
   customizations — expressed at the **template/fragment level** and applied at
   compile time.

Two mechanisms make this work:

- **Canon via `{{INCLUDE}}` transclusion.** Framework-canonical behavior shared
  across agents (operating rules, the ADR-0026 clause, protocol sections) lives
  in **synced canon fragments** (or `SYSTEM_INVARIANTS` sections); templates
  `{{INCLUDE}}` them; `compile-templates` **inlines the current synced canon**
  into the compiled prompt. → the agent gets the canon **in-prompt** (solving the
  don't-defer problem of ADR-0026) from **one** synced source.
- **Sync + recompile is the propagation path.** `upstream-sync` updates the
  templates and canon fragments **freely** (they hold no instance data to
  clobber); a `compile-templates` pass regenerates the compiled agents from the
  fresh templates + the overlay → current canon **and** preserved
  customizations, **zero drift, zero whole-file checkout**.

The NEVER-touched list shrinks to the **overlay** only; templates and canon
fragments become first-class synced framework artifacts.

## Consequences

**Positive**
- Framework-canonical changes propagate to every instance through the normal
  sync + recompile, with no clobber and no drift.
- Canon is inlined in the prompt (agents actually obey it) but sourced once.
- The never-touched surface is minimized to genuine instance state.

**Negative / trade-offs**
- A real refactor of the compile model and the output/symlink structure.
- **Migration for existing instances is the hard part:** their customizations
  currently live *inside* the compiled files (post-substitution). Migrating means
  extracting those into overlays and re-pointing the compiled output —
  effectively a guided de-compile. This is also where the accumulated 8-version
  drift gets paid down (the "modernization") — structurally, once.

## Open questions (to resolve before implementation)

- Where the compiled output lives (a gitignored generated dir vs committed
  `.claude/agents/` as real files instead of symlinks-to-`agents/`).
- `{{INCLUDE}}` granularity — per-section canon fragments vs whole shared blocks;
  fragment registry + versioning.
- How to auto-extract existing instance customizations into overlays (the
  migration's hard part) — likely a guided/semi-manual pass, not fully automatic.
- The **manifesto** is itself an instance governance artifact — is it part of the
  overlay, or a separate layer the compile references?
- Interaction with ADR 0010 (compiled agent registration) and the symlink model.

## References

- [ADR 0026](0026-authorization-is-a-record-not-a-message.md) — agents don't
  reliably defer to *referenced* canon → canon must be inlined (motivates the
  `{{INCLUDE}}` transclusion).
- [ADR 0010](0010-compiled-agent-registration.md) — the compiled-agent
  registration model this refactors.
- [ADR 0001](0001-skill-first-architecture.md) — skill-first; the template/skill
  surface.
- [ADR 0019](0019-juvantlabs-as-self-developing-project.md) — harvest model.
- FEAT-058 — the near-term delta-apply fix that ships first.
- `scripts/compile-templates.sh`, `JUVANT_OS.md` § "Upstream sync" (the
  whitelist + NEVER-touched list this changes).
