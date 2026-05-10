# ADR 0016 — Framework scope position (Juvant OS as software-development-flavored opinionated stack)

## Status

Proposed (2026-05-09). Implementation target: v0.8.0, batched with
ADR 0014 + ADR 0015. This ADR is **declarative** — it does not
mandate code changes; it codifies the framework's positioning so
adopter expectations align with what the framework actually delivers,
and so future contributors don't reflexively try to generalize
project-scope agents into industry-agnostic shells.

## Context

Juvant OS started life as the agent system for one specific company
(Juvant Srls — a venture studio building software products). As
the system was extracted into the open-source `juvantlabs/juvant-os`
framework through v0.5–v0.7, two pulls operated in tension:

1. **Generalization pull** — the OSS project should serve any
   adopter's company, not just Juvant Srls. Templates ship without
   fixed names; the OSS-genericity rule (per the user's standing
   feedback memory) prohibits hard-coded references in framework
   artifacts. Company-scope agents (CFO, CLO, CMO, CCO, CHRO, CSO,
   CEthO) generalize cleanly across industries — every business has
   finance, legal, marketing, sales, HR, security, ethics functions.

2. **Software-development pull** — the project-scope agents (CTO,
   CPO, CDO, COO, VPE, eng-api/backend/frontend/ai) and the
   default `{{BACKEND_LANG}}` / `{{FRONTEND_PLATFORM}}` /
   `{{DATABASE}}` placeholder set are unmistakably software-shaped.
   Eng/\* roles, github:write as the canonical project-writer
   capability, OpenTelemetry as a mandatory architectural
   principle (§7 #7), Turso/LibSQL as the default state store —
   none of these generalize to a non-software adopter (a law firm,
   a marketing agency, a clinical practice).

Through v0.6.x and v0.7.x the framework's prose tried to paper over
the tension: README and JUVANT_OS.md treated the agent system as
"any company that runs structured operations," while the actual
implementation (matrix, hooks, fixtures, ADRs) was visibly
software-flavored. Three concrete consequences:

- **Adopter onboarding friction.** Two of the first five preflight
  conversations had a non-software-adopter ask "do we need
  eng-api/backend/frontend/ai if we don't ship code?" The answer
  ("you can disable them but the rest of the framework expects
  them") didn't satisfy because the project-scope manifesto
  templates assumed engineering work as the dominant project
  shape.
- **Contributor confusion.** A v0.7.x PR proposal (closed without
  merge) tried to abstract the eng-\* agents into "domain
  experts" with the rationale "let's not assume software." The
  abstraction rippled into the matrix, the spec system, and the
  hook policy and was abandoned because it weakened the framework
  without serving any concrete adopter.
- **Doc inconsistency.** The README spoke generically ("AI agents
  for your company") while JUVANT_OS.md Step 5 mentioned `BACKEND_LANG`
  defaults pointing at FastAPI. Adopters reading both got mixed
  signals about who the framework is for.

The honest position — and the one this ADR codifies — is:
**Juvant OS is a software-development-flavored agent framework.**
It ships an opinionated project-shape (an engineering team building
a product) baked into the project-scope agents, the default tech
stack, and the spec authorization model. Company-scope agents
remain industry-agnostic; project-scope agents are not.

## Decision

Position the framework explicitly along the following layers.

### 1. Layer-by-layer scope position

| Layer | Audience | Genericity |
|---|---|---|
| **Company-scope agents** (10 default + optional CRO/VPE) | Any company building any product | Industry-agnostic. Names, capabilities, and spec semantics generalize across software / services / professional firms / consumer goods / etc. |
| **Project-scope agents** (8: PCA, Product Lead, Design Lead, Eng Lead, eng-api/backend/frontend/ai) | A software-product project | **Software-shaped by design.** Adopters whose projects aren't software-shaped use one of the escape hatches in section 3 below. |
| **Default placeholders** (`{{BACKEND_LANG}}`, `{{DATABASE}}`, `{{CICD}}`, …) | Software adopters | **Software-shaped.** Defaults assume Python/FastAPI/React/Next.js/LibSQL/GitHub Actions; non-software adopters override at company init. |
| **Hook policy** (bash-policy.json) | Software adopters | **Software-shaped.** The default `agent_allow` per role assumes git, npm, sqlite3, jq, etc. Non-software adopters customize. |
| **Spec system** (pr-spec, gh-issue-spec, release-spec, …) | Software adopters | **Software-shaped.** Specs assume GitHub repo + PR + release lifecycle. |

### 2. The framework's positioning statement

The README and JUVANT_OS.md update with the following positioning,
linkable as a single canonical reference:

> Juvant OS is an opinionated agent framework for **software-product
> companies** — companies whose primary deliverable is software, and
> whose projects are software products. It ships:
>
> - A 10-agent industry-agnostic **company management layer** (CoS,
>   CFO, CLO, CMO, CCO, CHRO, CSO, CEthO, CTO, eng-platform — plus
>   optional CRO/VPE).
> - An 8-agent **project engineering layer** opinionated on a default
>   technology stack (Python + FastAPI / React Native + Expo / Next.js
>   / LibSQL via Turso / GitHub Actions / OpenTelemetry).
>
> Adopters whose company is not software-shaped — a law firm, a
> consulting practice, a manufacturer — can adopt the company layer
> standalone (see section 3 below); the project layer is unlikely to
> fit without significant adaptation.

This is a positioning change, not a capability change. The framework
already operates this way. The ADR makes it explicit.

### 3. Escape hatches for non-software adopters

Three documented paths for adopters whose projects don't fit the
default software shape:

#### 3a. **Company-only adoption** (recommended for non-software adopters)

The 10 company-scope agents work standalone. Run the company-init
wizard, skip project-init entirely. The company manages itself
(CoS routes; CFO handles finance; CLO handles contracts; CMO owns
brand; CCO runs sales; CHRO runs HR; CSO audits; CEthO validates
ethics; CTO owns the (limited) tech surface; eng-platform handles
the company's own infra needs).

This is the canonical path for: law firms, accounting firms,
medical practices, consultancies, real estate agencies, marketing
agencies that don't ship software, family offices, etc.

JUVANT_OS.md Step (company init) gains a "skip project init" branch
for adopters who declare no software projects. The wizard prose at
Step (project init entry) explicitly asks "are you running software
projects? If no, you're done — see ADR 0016 for company-only
adoption."

#### 3b. **Fork-and-adapt** (for non-software project shapes)

Adopters whose projects aren't software but who want a project layer
(e.g. a law firm running per-matter projects, a consultancy running
per-engagement projects, a venture studio running per-portfolio-co
projects) fork the project-scope templates and customize. The
framework provides the structure (PCA / Product Lead / Design Lead /
Eng Lead / Eng/\* roles, scope-flag pattern per ADR 0013, spec
authorization per §6) and the adopter substitutes their own
project-shape semantics.

Fork-and-adapt is **not supported by the framework** in the sense
that we don't ship templates for non-software project shapes. It's
documented as a known path so adopters who choose it know they're
on the customization side of the OSS contract.

#### 3c. **Project-shape templating** (v1.x scope)

A future capability — out of scope for v0.8.0, listed as the
canonical path forward for non-software project shapes that
multiple adopters want — is **project-shape templates**: a
catalog of alternative project-scope agent sets keyed on
project type (`software-product` (default), `legal-matter`,
`consulting-engagement`, `clinical-case`, `portfolio-company`,
…). The wizard's project-init step would prompt "what project
shape?" and load the corresponding template set.

Project-shape templating is on the v1.x roadmap once at least
two non-software adopters have run fork-and-adapt successfully
and produced converging templates. Pre-emptively building
templates without an adopter asking is the kind of speculative
generalization that bloated the v0.7.x ARCH-009 #42 thread.

### 4. Boundary against scope creep

The framework explicitly does NOT aim to:

- Generalize project-scope agents into industry-agnostic shells
  before adopter signal demands it.
- Ship "domain expert" abstractions in place of concrete eng-\*
  roles.
- Hide the software flavor of the default placeholders behind
  generic vocabulary.
- Treat non-software adoption as a first-class equivalent path —
  it is supported via escape hatches, not the default.

The boundary protects two properties: **clarity of fit** (adopters
can tell quickly whether the framework is for them) and **density
of opinion** (the project-scope agents are deeply opinionated about
software practice, which is what makes them useful; diluting that
to be industry-neutral makes them useless).

### 5. Relation to ADR 0014's eng-platform default-mandatory

ADR 0014 makes `eng-platform` mandatory at company init by default
(N=10 founding manifestos including eng-platform). This ADR
articulates *why*: because the framework targets software adopters,
and software adopters need a company-level infra writer (template
fork management, npm publication, cloud control plane). For
adopters who toggle `eng_platform_enabled: false` (the rare
non-software company-only adopter who wants none of the
eng-platform's capabilities), the toggle is preserved per ADR 0014
section 7 — but the default is on.

Without this ADR's positioning, the question "why is eng-platform
default-mandatory if the framework is industry-agnostic?" has no
clean answer. With this ADR, the answer is: "the framework targets
software adopters by design; eng-platform is part of the default
software-shaped configuration."

## Consequences

**Positive**:

- Adopter expectations align with what the framework actually
  delivers. No more "we tried to use it for our law firm and the
  project agents made no sense" feedback that would otherwise
  arrive after adoption.
- Contributors have a clear principle to cite when rejecting
  premature generalization PRs ("the framework is software-shaped
  by design — see ADR 0016").
- Company-only adoption is explicitly supported and signposted,
  expanding the addressable adopter base without diluting the
  framework's core opinion.
- The v1.x project-shape templating roadmap has a concrete
  adopter-signal-driven trigger condition (≥2 non-software
  adopters running fork-and-adapt with converging templates),
  rather than being an open-ended "should we maybe support
  other industries someday?" question.

**Negative**:

- Some prospective adopters who would have tried Juvant OS for
  non-software companies will read the positioning and decide
  not to. This is the right outcome — the framework wouldn't
  serve them well — but it narrows the apparent funnel.
- The README needs a visible positioning statement up-front,
  which is a tone shift from the previous more-generic prose.

**Neutral**:

- This ADR is declarative, not prescriptive. No code changes are
  mandated by this ADR alone (the code changes referenced here
  — eng-platform default-mandatory, project-init "skip" branch
  — land via ADR 0014 and the v0.8.0 wizard prose update
  respectively).
- Future framework forks targeting specific non-software
  industries (a hypothetical `juvant-legal-os` fork) become a
  legitimate downstream path rather than a mainline framework
  responsibility. The OSS license permits this; this ADR
  acknowledges it as the expected pattern.

## Cross-references

- ADR 0014 (tech leadership restructure) — codifies the role
  inventory this ADR positions; eng-platform default-mandatory
  is justified here.
- ADR 0015 (design & brand ownership) — orthogonal; brand
  ownership pattern is industry-agnostic and works for both
  company-only and full-stack adopters.
- ADR 0006 (CA owns agent_tool_matrix) — the matrix is per-company;
  non-software adopters who go company-only still use the matrix
  (with the project-scope rows omitted via empty `.projects.{}`
  config).
- ADR 0013 (script scope-flag uniformity) — `--project=<slug>`
  pattern continues to work for company-only adopters by being
  a no-op (no projects = no flag passes).
- README.md — gains the canonical positioning statement (section 2
  above) at the top, replacing the previous more-generic
  description. Update batched with v0.8.0.
- JUVANT_OS.md — Step (company init) closing prompt branches on
  "do you have software projects?" (skip project init if no).
  Update batched with v0.8.0.
- `juvantlabs/handbook` — ADR 0016 is a framework-level ADR,
  not a handbook ADR; the handbook covers org-level governance,
  the framework covers what this codebase ships. Cross-link from
  the handbook README is sufficient.
- Future v1.x ADR (TBD) — if/when project-shape templating
  graduates from "v1.x roadmap" to "actively designed," the
  resulting ADR amends section 3c here.
