# ADR 0019 — Modeling `juvantlabs` as a project that develops the framework: source-of-truth, upstream-sync, and recursion mechanics

## Status

Accepted (2026-06-18). Framework-side design answering the downstream Juvant
Srls instance's Q1–Q5 handoff. The downstream **"what"** — model `juvantlabs`
as one multi-repo project inside the `juvant` instance (not a sub-company per
ADR 0017) — is taken as given and **not** relitigated here. This ADR fixes the
**"how"**: the mechanics that keep a single source of truth when one of the
project's repos is `juvant-os` itself.

## Context

`juvantlabs` is a permanent OSS department of Juvant Srls (same legal entity;
LICENSE holder "Juvant Srls"). It ships multiple OSS products — `juvant-os`
(the framework), `engram`, MCP servers, `labs-web` (`labs.juvant.io`). The
downstream has decided to model it as a single project (roster: PCA, Product
Lead, Design Lead, Eng Lead, eng-backend/ai/api/frontend), sharing the
company-scope agents.

Two facts shape the mechanics:

1. **Meta-recursion.** One repo in this project (`juvant-os`) is the framework
   the host instance itself runs on. Developing it "inside" the instance
   collapses the clean upstream/downstream split that the OSS template model
   relies on.

2. **Writer correction.** In this instance `eng-platform` has **never** written
   to `juvantlabs/*` repos — its only `juvant-os` interaction has been opening
   upstream PRs from the instance. This contradicts `agents/company/eng-platform.md`,
   which still claims `eng-platform` is the sole writer for "company-level repos
   (template fork)" and "npm canonical-helper publication." That description
   must be reconciled (see Consequences).

The single load-bearing idea this ADR introduces: **the canonical GitHub repo
`juvantlabs/juvant-os` is the one source of truth, and the `juvant` instance
holds two *separate* local working trees against it — an operational mirror it
*consumes*, and a project dev checkout it *produces* from. They are decoupled by
the release-tag boundary and must never be the same tree.**

## Decision

### Q1 — Source of truth for `juvant-os`

The canonical source of truth is **`juvantlabs/juvant-os` on GitHub** — not any
local copy. The `juvant` instance has **two distinct local working trees**, and
they are never the same directory:

| Tree | Role | Synced how | Branch state |
|---|---|---|---|
| **Operational mirror** (instance repo root) | What the instance *runs on* | `juv-upstream-sync` pulls **released tags** | pinned to a released tag |
| **Project dev checkout** (juvantlabs project `working_tree`, e.g. a sibling clone) | Where the Eng Lead *develops* `juvant-os` | `git` clone of canonical; pushes branches/PRs | `main` + feature branches |

Divergence is impossible because neither local tree is authoritative: the
operational mirror **consumes** released tags from canonical, the dev checkout
**produces** to canonical's `HEAD`. The instance is simultaneously a *consumer*
(mirror) and the *dev home* (project) of the same canonical repo, separated by
the release-tag boundary. **Never point the project `working_tree` at the
instance's own framework files** — that is the recursion hazard (Q4).

### Q2 — Upstream-sync flow under §4 single-writer

**Consumer side (`juv-upstream-sync`): unchanged.** The `juvant` instance — and
every other adopter — pulls released `juvant-os` tags into its operational
mirror exactly as today (fetch upstream tag → category-gated CEO approval →
apply whitelist). Mirror-push / sync to *other* per-company instances continues
to originate from canonical `juvantlabs/juvant-os` **unchanged**; Juvant's
dev-home status is invisible to other adopters, who see only canonical releases.

**Producer side: changes, but reuses existing mechanisms.** A framework-worthy
change discovered in company-scope operation now flows:

1. `eng-platform` (company scope) **proposes** — surfaces the finding via a
   `messages`/escalation to CoS. It does **not** author the change and does
   **not** open the PR.
2. The **juvantlabs project** (PCA / Eng Lead) **authors a `pr-spec`** in the
   `project-juvantlabs` DB. Authorship stays in the project scope — this
   preserves §4d (a company-scope agent must not author project-scoped rows).
3. The **juvantlabs Eng Lead** (sole §4 writer for `juvantlabs/*`) **implements
   and merges** into `juvant-os`, cuts a release.

Proposer ≠ writer across scopes is handled by the **existing** spec-routing
pattern; no new spec class is required. The `juvant` instance then becomes the
**first dogfood consumer** of its own release (dev → tag → `juv-upstream-sync`
into the operational mirror). `juv-upstream-sync` itself needs **no change**.

### Q3 — Program abstraction

**Do not build a first-class "program" abstraction now.** Per ADR 0016's
anti-speculative-generalization principle, build for the adopter in front of us:
today `juvantlabs` is one multi-repo project, which suffices.

Use a lightweight **convention**: a `program` field on project config entries
(`projects.<slug>.program = "juvantlabs"`). The **graduation path** uses the
existing project model — when `engram` earns its own cadence, run `project-init`
for `engram` and tag it `program: "juvantlabs"`. "juvantlabs" then remains both
a project (anchored by `labs-web`, Q5) and a program-label spanning the
graduated product-projects.

Promote "program" to a first-class grouping only on evidence — when ≥2 programs
exist with real cross-project grouping needs (same evidence-gate discipline as
ADR 0016 §3c project-shape templating).

### Q4 — Bootstrapping recursion: hazards and safe dev/test pattern

The hazard — a breaking framework change developed in the project breaking the
very instance developing it — is neutralized by **four boundaries that already
exist**, plus the Q1 separation:

1. **Dev checkout ≠ operational mirror** (Q1). A breaking change in the dev tree
   does not touch the files the instance runs on.
2. **Release-tag boundary.** The instance adopts only **tagged** releases, never
   the dev `HEAD`.
3. **testco before tag.** Breaking changes are validated by the batch testco
   against `/tmp` fixtures (release ceremony §2) — never against the live
   instance.
4. **Opt-in, category-gated sync.** `juv-upstream-sync` is HARD-REQUIRED to get
   explicit per-category CEO approval; silence = skip. A tagged breaking change
   cannot reach the operational instance silently.

**Recommended loop:** develop in the project checkout → run the batch testco →
tag → `juv-upstream-sync` into the operational mirror with category review → if
the instance breaks, revert the sync commit (it is git) while the dev checkout
keeps moving. Keep the instance pinned to a known-good framework tag; upgrade
deliberately, never auto-track `HEAD`.

### Q5 — `labs.juvant.io`

**Confirmed: a repo *within* the juvantlabs project, not its own project.** The
`juvant-web` parallel is a **contrast**, not a match:

- `juvant.io` (`juvant-web`) is the company's **commercial product** → its own
  project, own roster, own cadence, own brand.
- `labs.juvant.io` (`labs-web`) is the **OSS department's own site**, tightly
  coupled to and showcasing the juvantlabs OSS products. It shares the
  juvantlabs roster (eng-frontend + Design Lead are already in it). A separate
  project would fragment the OSS roster for no benefit.

`labs-web` also **anchors** the juvantlabs project after products graduate out
(Q3): when `engram` leaves, `labs-web` keeps the `juvantlabs` project (and
program label) populated. Do not give it its own project.

## Consequences

**Positive**

- One source of truth (`juvantlabs/juvant-os`), zero new sync machinery; the
  consumer path and other adopters are untouched.
- The producer path reuses `pr-spec` + §4d authorship; the recursion is made
  safe by boundaries that already exist.
- Juvant dogfoods its own framework releases as the first consumer — fast
  feedback on real adopter pain.

**Negative / required follow-up**

- **`agents/company/eng-platform.md` must be reconciled** (and recompiled). The
  canonical `juvantlabs/*` OSS repos — `juvant-os`, `engram`, MCP servers,
  canonical-helper **source** repos, and **npm publication** of those packages —
  move to the **juvantlabs project Eng Lead** (sole §4 writer for `juvantlabs/*`).
  `eng-platform` remains sole writer for the **company instance's own** infra,
  cloud control plane, and the **operational framework mirror** (the consuming
  fork). "template fork" in its description = the instance's operational fork,
  **not** canonical upstream. This narrows eng-platform's GitHub/npm write scope.
- `JUVANT_OS.md` project-setup gains a note on the dual working-tree rule (Q1)
  and the `program` convention field (Q3).

**Neutral**

- No change to ADR 0017 (sub-company) — explicitly rejected upstream for this
  case; remains available for genuinely separate legal entities.
- "program" stays a convention; a future ADR may promote it on evidence.

## Implementation checklist (for the framework)

- [ ] Edit `agents/company/eng-platform.md`: narrow GitHub/npm write scope to
      the instance's own infra + operational mirror; canonical `juvantlabs/*`
      and npm publication → juvantlabs project Eng Lead. Recompile.
- [ ] `JUVANT_OS.md` project-setup: document the dual working-tree rule and the
      `program` field convention.
- [ ] Optionally surface `program` in the project config schema doc.

The downstream CTO can execute `project-init` for `juvantlabs` immediately on
the strength of Q1/Q4/Q5; the producer-path wiring (Q2) and the eng-platform
reconciliation are framework-side and tracked above.

## Cross-references

- ADR 0017 (sub-company model) — the rejected alternative; `company_type` stays
  `master` with no sub.
- ADR 0014 (tech leadership restructure) — defines `eng-platform`; this ADR
  narrows its writer scope re: canonical `juvantlabs/*`.
- ADR 0016 (framework scope position) — the anti-speculative-generalization
  principle applied to Q3.
- `SYSTEM_INVARIANTS.md` §4 (single-writer-per-scope) + §4d (project-scoped
  decision authorship) — the producer-path handoff (Q2) is bounded by these.
- `JUVANT_OS.md` § Upstream sync — the consumer procedure, unchanged.
