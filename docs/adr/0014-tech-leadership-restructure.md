# ADR 0014 — Tech leadership restructure (CTO promotion, project-scope rename, VPE toggle)

## Status

Proposed (2026-05-09). Implementation target: v0.8.0. Touches role
identifiers across the entire framework — every agent template,
`SYSTEM_INVARIANTS.md` §2/§4/§6, `v0-agent-tool-matrix.json`,
`hooks/bash-policy.json`, `JUVANT_OS.md` wizard prose, all four
testco fixtures, and a non-trivial migration note for any pre-v0.8.0
adopter forks. The naming churn is invasive enough that the
restructure ships as a **single batched ADR + commit train** rather
than incremental per-role moves; partial rename leaves the matrix
inconsistent with the bash-policy allow-list and would deny the
Skill's own bootstrap commands mid-flow.

Companion ADRs adopted alongside this one:

- **ADR 0015** — Design & brand ownership (CMO ↔ Design Lead split,
  3-mode brand-spec pattern). Depends on the project-CDO → Design Lead
  rename codified here.
- **ADR 0016** — Framework scope position (Juvant OS as
  software-development-flavored opinionated stack). Depends on the
  CTO promotion + eng-platform expansion codified here.

## Context

The role-identifier vocabulary that landed in v0.6.0 (frozen at
SYSTEM_INVARIANTS.md §2 and the v0 matrix) accreted incrementally
through the FEAT-001/FEAT-008 batches and was never cross-checked
against the industry conventions adopters arrive with. Five
overlapping problems surfaced through testco runs and adopter
preflight conversations between v0.6.0 and v0.7.4:

1. **`ca` (Chief Architect) understates authority.** The role owns
   the agent tool matrix (ADR 0006), the architectural-principle
   citation chain (SYSTEM_INVARIANTS §7), and every cross-project
   technology-standard placeholder (`{{BACKEND_LANG}}`,
   `{{FRONTEND_PLATFORM}}`, `{{DATABASE}}`, …). In industry
   vocabulary that's a **CTO**. Calling it `ca` makes adopters
   misroute strategic tech decisions to a project-level role
   (`project-cto`, see point 2 below) that has no company-wide
   authority. Three pre-v0.7.4 batch fixtures already showed the
   Skill confusing the two during its own wizard prose.

2. **`cto` (project-scope) is structurally mis-named.** A project-
   scope CTO doesn't exist in industry: companies have one CTO; what
   the project-level role actually does — own the per-project
   technical architecture — is what an industry "Project Architect"
   or "Lead Architect" does. Keeping the name `cto` collides with
   point 1 and leaks the same confusion into every subagent ID, every
   spec authorization row, and every hook log line.

3. **`coo` (project-scope) is mis-described as operations.** The
   role's actual responsibility is engineering execution: it holds
   `github:write` (SYSTEM_INVARIANTS §4), executes specs from PCA /
   Design Lead / Product Lead / CSO, and runs the 5-check
   verification protocol. That's an **engineering lead**, not a
   chief operating officer. The `coo` label is a pre-v0.6.0
   placeholder that never got revisited; adopters reading the
   matrix without the context expect a project ops generalist.

4. **`cdo` (Chief Design Officer) collides with industry "Chief
   Data Officer".** Three of the first five Juvant OS preflight
   conversations had the adopter ask "what does the cdo do for our
   data governance?" before the Skill clarified design. The
   collision is reliable, not anecdotal.

5. **`cpo` (project-scope) overstates the role.** A "Chief Product
   Officer" exists once per company; a per-project role is a
   **product lead** owning that one product. Same structural issue
   as point 2.

Beyond the renames, two related questions surfaced repeatedly:

6. **VPE (per-project) is structurally redundant against project-COO.**
   VPE was carried in from a pre-FEAT-008 draft to "aggregate Eng/*
   reporting up to the CTO" but its actual matrix row mirrors COO's
   github:read + turso, and the §3 Tier 4 disclosure cascade routes
   Eng/* fallbacks through VPE only as an aggregation hop that COO
   could equally perform. In single-project software-shop adopters
   it duplicates COO's authority; in non-software adopters it has
   nothing to do. **Move VPE out of mandatory project-scope and turn
   it into an opt-in company-level toggle**, where it matches the
   organizational pattern of larger orgs that genuinely separate
   "head of engineering function" from per-product engineering leads.

7. **`eng-platform` capabilities are under-specified.** The role
   was promoted to founding company-scope in v0.6.6 (F-12, Golf
   Corp testco) but its matrix row still ships only
   `["turso", "github:read"]`. Adopter expectation, confirmed by
   the OP-007 Hardys preflight, is that eng-platform is the agent
   that operates the **company-level repos** (template fork, infra
   IaC, npm-published canonical helpers per FEAT-024) — which means
   `github:write` to the **company** repo (not project repos),
   plus cloud control-plane writes (`cloud:write` against
   azure/aws/gcp/turso depending on adopter), plus `npm:publish`
   for the canonical-helper publication path. With current
   capabilities eng-platform can audit but not act, and adopters
   have been working around it by giving CEO direct write access
   to the company fork — a §4 single-writer violation by inheritance.

The five renames + VPE toggle + eng-platform expansion are all
structural changes to §2/§4/§6. They are not stylistic. Resolving
them piecemeal would compound the churn and keep cross-references
inconsistent for several minor versions.

## Decision

Adopt the following coordinated restructure as the v0.8.0 baseline.

### 1. Renames (canonical role identifiers)

**Company scope:**

| Was | Becomes | Justification |
|---|---|---|
| `ca` (Chief Architect) | **`cto`** (Chief Technology Officer) | Restores industry alignment; acknowledges company-wide tech authority. |

The legacy `cto` (project-scope) is renamed in parallel (next table)
so the company-level `cto` identifier is unambiguous.

**Project scope:**

| Was | Becomes | Justification |
|---|---|---|
| `cto` (project) | **`pca`** (Project Chief Architect) | "Per-project architect"; preserves the architecture-spec authorship chain without colliding with company `cto`. |
| `coo` (project) | **`eng-lead`** (Engineering Lead) | Describes actual scope: holds github:write, executes specs, runs 5-check verification. |
| `cdo` (project) | **`design-lead`** (Design Lead) | Removes the Chief Data Officer collision; matches industry "design lead" for per-product design. |
| `cpo` (project) | **`product-lead`** (Product Lead) | Per-project product role; "Chief Product Officer" is reserved for company scope (currently unimplemented; see Future Work). |

**Eng/\* identifiers** (`eng-api`, `eng-backend`, `eng-frontend`,
`eng-ai`) keep their names — they are already role-prefixed and
unambiguous.

### 2. VPE: project-mandatory → company-optional toggle

VPE is removed from project scope. The wizard's project-init step
no longer creates a project-scoped VPE row in the matrix or a
`{{VPE_NAME}}` placeholder substitution.

VPE returns at company scope as an **opt-in** role, gated by a new
config field:

```jsonc
{
  "company": { ... },
  "feature_toggles": {
    "vpe_enabled": false,            // default OFF
    "cro_enabled": false,            // existing optional, made explicit
    "eng_platform_enabled": true     // mandatory by default in v0.8.0; toggle preserved for non-software adopters per ADR 0016
  }
}
```

When `vpe_enabled: true`, the wizard's company-init flow emits an
11th company manifesto (12th if `cro_enabled: true`). The role's
authority pattern: aggregate Eng/\* status across **all** projects
into a unified weekly report; receives Tier 4 disclosure-cascade
fallbacks across projects (replacing the per-project VPE that
existed in §3 Tier 4 v0.7.x). For single-project adopters, leaving
VPE off is the default — the company `cto` performs the
cross-project aggregation directly.

The §3 Tier 4 disclosure cascade is amended in `agents/company/cos.md`
and `agents/company/<eng-*>.md` cross-references to route to
**company VPE if enabled, else company CTO**.

### 3. eng-platform capability expansion

The eng-platform matrix row is upgraded to the following capabilities:

```jsonc
{
  "role": "eng-platform",
  "scope": "company",
  "mcp_servers": [
    "turso",
    "github:write",        // COMPANY repo only — see §4 amendment below
    "cloud:write",         // azure/aws/gcp/turso control-plane writes
    "npm:publish"          // canonical-helper publication (FEAT-024 path)
  ],
  "skills": [],
  "channels": [],
  "rationale": "Company-scope infra writer; sole writer to company-level repos and cloud control plane (§4 single-writer-per-scope). Holds npm:publish for canonical helpers. Pairs with project Eng Leads who own project repos."
}
```

The `cloud:write` MCP is a new abstract entry (concrete server
name resolved at adoption time per `feature_toggles.cloud_provider`
∈ {`azure`, `aws`, `gcp`, `none`}). Adopters that don't run their
own cloud (single-Mac local-only setups) toggle `cloud_provider: none`
and the `cloud:write` MCP is omitted from the matrix.

### 4. SYSTEM_INVARIANTS §4 amendment — single-writer-per-scope

The current §4 reads "COO is the sole agent in the system that
writes to GitHub repositories." That conflicts with eng-platform
holding `github:write` (point 3 above). The amendment rewrites §4
to **single-writer-per-scope**, with two scopes and one writer
each:

> **Company scope** (the company fork repo, the template/infra
> IaC repo, npm registry): sole writer is **`eng-platform`**.
>
> **Project scope** (each project's own repo): sole writer per
> project is the project's **`eng-lead`**.
>
> Cross-scope writes are forbidden: an `eng-lead` cannot write to
> the company repo; `eng-platform` cannot write to a project repo.
> Each writer's 5-check protocol verifies the spec's target scope
> matches the writer's own scope before execution.
>
> The disclosure-boundary corollary (state.db read + external send
> in the same row) applies **per scope**: an `eng-lead` reading
> state.db at project scope cannot also hold a project-scope
> external channel; analogously for `eng-platform` at company scope.

The §3 Tier 3 cascade rule ("COO halts ALL spec execution while
the cascade is active") expands to "the writer for the cascading
scope halts spec execution while the cascade is active" — applies
independently to eng-platform and to each project's eng-lead.

### 5. SYSTEM_INVARIANTS §6 amendment — spec authorization renames + new spec class

The §6 spec authorization matrix updates row-by-row to use the new
role identifiers. Two additions:

| Spec category | v0.7.x authors | v0.8.0 authors |
|---|---|---|
| `pr-spec` | CA, CTO, CDO, CSO | **CTO, PCA, Design Lead, CSO** |
| `gh-issue-spec` | CPO, CTO, CDO, CSO, VPE | **Product Lead, PCA, Design Lead, CSO** (+ VPE if enabled) |
| `gh-project-update-spec` | CPO, CTO, CDO, VPE | **Product Lead, PCA, Design Lead** (+ VPE if enabled) |
| `gh-milestone-spec` | CPO, CTO | **Product Lead, PCA** |
| `install-spec` | CA | **CTO** |
| `branch-protection-spec` | CSO, CTO | **CSO, PCA** (project) **/ CSO, CTO** (company) |
| `release-spec` | VPE, CTO | **PCA** (+ VPE if enabled) |
| `deployment-spec` | VPE, CTO | **PCA** (+ VPE if enabled) |
| `secret-rotation-spec` | CSO | **CSO** (unchanged) |
| `gh-pr-review-spec` | VPE (delegated by CTO) | **Eng Lead** (delegated by PCA when architectural; or VPE if enabled at cross-project review) |
| **NEW:** `eng-platform-spec` | — | **eng-platform** (author) / **CTO** (approver) |

The new `eng-platform-spec` class covers company-level infra
changes that don't fit pr-spec / install-spec — IaC drift, cloud
control-plane bumps, npm version cuts. It is the spec the
eng-platform agent writes to itself for the company-scope writer
to verify and execute. Yes, eng-platform is both author and
executor here; the 5-check protocol applies (CTO is the
approver-of-record gating execution).

### 6. Bootstrap protocol counts

§1 amendment — the founding manifesto count moves from "founding
19 agents" to a parameterized count:

> N = (mandatory company) + (eng-platform if enabled) + (CRO if
> enabled) + (VPE if enabled).
>
> Default at v0.8.0: **N = 10** (9 mandatory + eng-platform on by
> default).
>
> Adopter overrides at company init: `+1` per optional role
> enabled. Per-project agents (PCA, Product Lead, Design Lead,
> Eng Lead, eng-api/backend/frontend/ai = 8 per project) bootstrap
> at project-init **after** company bootstrap completes; they are
> not part of the N count.

### 7. Backward compatibility for pre-v0.8.0 adopter forks

Any adopter fork created before v0.8.0 has:
- `state.db` rows referencing old role identifiers (`ca`, `coo`,
  `cdo`, `cpo`, project-`cto`, project-`vpe`).
- Compiled agent files at `agents/{company,projects}/{ca,coo,…}.md`.
- `hooks/bash-policy.json` keys under the old names.
- `manifests`, `decisions`, `agent_actions_log`, `inbound_queue`,
  `security_audit_log` rows whose `agent` / `agent_owner` columns
  hold the old identifiers.

`scripts/migrate.sh` gains a v0.8.0 migration mode that:

1. Renames the agent files in place (keeps git history via
   `git mv`).
2. Updates `agent_tool_matrix` rows to the new identifiers.
3. Updates `hooks/bash-policy.json` keys.
4. Leaves historical rows in `manifests`, `decisions`,
   `agent_actions_log`, `inbound_queue`, `security_audit_log`
   **untouched** — they record what the agent identifier was at the
   time of the row write. A `role_aliases` table maps old → new
   identifiers for audit-time joins. CSO Layer 5 audits read from
   the alias view, not the raw column.
5. Re-runs `compile-templates.sh` so the new agent files have new
   substitutions.
6. Does NOT re-run bootstrap; the existing manifestos remain
   valid (the role identifier in the manifesto body is metadata,
   the manifesto's structural commitments are preserved).

The migration is invoked by the adopter as a single
`bash scripts/migrate.sh --from=v0.7 --to=v0.8` command. Pre-flight
checks confirm `bootstrap_completed_at IS NOT NULL` (only
post-bootstrap forks need migration; new forks start clean at
v0.8.0).

## Consequences

**Positive**:

- Industry-aligned role names eliminate the recurring "what does
  cdo mean / why is project-cto different from company-ca?"
  preflight friction.
- §4 single-writer-per-scope is more honest about how the system
  actually operates and unblocks eng-platform from writing to the
  company repo (currently a covert violation working around the
  CA/COO confusion).
- VPE-as-toggle removes redundant project-scope mass for the
  default single-project software adopter while preserving the
  multi-project aggregation pattern when wanted.
- New `eng-platform-spec` class formalizes a path that adopters
  were already using ad hoc.
- Bootstrap count is now adopter-derived rather than hard-coded
  in invariants prose, so future optional-role additions
  (post-v1.0) don't require §1 amendments each time.

**Negative**:

- One-time massive rename: ~40 files touched, ~600-1000 LOC churn,
  every cross-reference in ADR 0001-0013 + every `agents/**/*.md`
  template + matrix files + bash-policy.json + wizard prose +
  fixtures. Mitigated by ADR 0014 itself being the migration
  blueprint and by `scripts/migrate.sh` carrying adopter-side
  state migration.
- Adopters who built custom MCP integrations against the old
  role identifiers must update their integration. The `role_aliases`
  table is for audit-time joins only, not for runtime dispatch —
  the `agent_type` field in hook payloads carries the new identifier
  starting v0.8.0.
- `git blame` on agent template files becomes confusing for the
  rename commit. Mitigated by using `git mv` (preserves rename
  detection) and a single dedicated commit `refactor(v0.8.0):
  role identifier rename per ADR 0014` separate from substantive
  edits.

**Neutral**:

- Naming churn does not affect runtime behavior beyond
  identifiers; the actual capabilities, spec types, and audit
  semantics are preserved. Adopters who only consume the
  framework (don't customize templates) see no behavioral
  difference post-migration.
- The eng-platform `cloud:write` capability ships as an abstract
  MCP entry resolved at adoption time. Concrete cloud MCP
  implementations (azure, aws, gcp) are out of scope for this
  ADR; they ship as optional integrations under
  `juvantlabs/<provider>-platform-mcp-server` repos following the
  ADR 0003 boundary discipline.

## Migration sequence (executed in v0.8.0)

The implementation order — pinned here so the v0.8.0 commit train
follows the same sequence and reviewers can map each commit to a
section of this ADR:

1. **ADR 0014 + 0015 + 0016** committed first (foundation).
2. **SYSTEM_INVARIANTS.md** §1, §2, §4, §6 amendments.
3. **`agents/**/*.md` rename + frontmatter update** via `git mv`
   (single commit, no body changes).
4. **`agents/**/*.md` body edits** (peer references, spec
   authorship sections, role-identifier prose) — separate
   commit so the rename is reviewable independently.
5. **`scripts/templates/v0-agent-tool-matrix.json`** — new role
   identifiers + eng-platform capability expansion + (optional
   cro/vpe toggles emitted only when enabled at company init).
6. **`hooks/bash-policy.json`** — `agent_allow` keys renamed;
   eng-platform `agent_allow` extended with cloud / npm binaries.
7. **`scripts/compile-templates.sh`** — new placeholder
   substitutions (`{{PCA_NAME}}`, `{{ENG_LEAD_NAME}}`,
   `{{DESIGN_LEAD_NAME}}`, `{{PRODUCT_LEAD_NAME}}`); old ones
   removed.
8. **`scripts/audit-bootstrap-baseline.sh`** — expected-roles list
   updated for both company and project scopes.
9. **`scripts/migrate.sh`** — `--from=v0.7 --to=v0.8` migration
   mode (point 7 of Decision above).
10. **`JUVANT_OS.md`** wizard prose — every step that mentions a
    renamed role (Steps 5/6/7/8 company init, Steps 1/3/4/5
    project init, plus spec authorship references, plus VPE
    toggle prompt at company init).
11. **`tests/fixtures/testco/*.yaml`** — all 4 fixtures updated
    (single-company, single-project, manifesto-walk-through,
    plus any v0.8.0-new fixture that exercises VPE toggle).
12. **`CHANGELOG.md`** v0.8.0 entry with explicit migration call-out
    and the `bash scripts/migrate.sh --from=v0.7 --to=v0.8`
    invocation.
13. **Validation runs** — single-company batch + single-project
    batch + a fresh fixture exercising `vpe_enabled: true`.
    All three must pass before tagging.
14. **`v0.8.0` tag** + release notes.

## Future work (out of scope for v0.8.0)

- Company-scope CPO (Chief Product Officer) is reserved as an
  optional role for v1.x adopters who actively run product
  portfolios. Not implemented in v0.8.0.
- `cloud:write` MCP concrete implementations
  (azure-platform-mcp-server, aws-platform-mcp-server,
  gcp-platform-mcp-server) ship as separate repos per ADR 0003;
  v0.8.0 only wires the abstract capability into the matrix.
- The `eng-platform-spec` class lifecycle (template, 5-check
  matrix, audit hooks) is sketched here but its full template
  ships in v0.8.1 once a concrete eng-platform action exercises
  the path end-to-end.

## Cross-references

- ADR 0006 (CA owns agent_tool_matrix) — every "CA" reference
  reads as "CTO" post-v0.8.0; ADR 0006 is amended by a one-line
  cross-link rather than a full rewrite.
- ADR 0010 (compiled agent registration) — symlinks under
  `.claude/agents/<role>.md` rename in lockstep with the agent
  files; the registration mechanism itself is unchanged.
- ADR 0011 (CEO direct channel class) — unchanged; CoS still owns
  `:send-ceo-only`.
- ADR 0012 (batch testco mode) — fixture schemas unchanged; only
  the per-fixture `agent_names` blocks updated.
- ADR 0013 (script scope-flag uniformity) — `--project=<slug>`
  pattern carries forward; new `migrate.sh --from/--to` flags
  are version-pair scoped, orthogonal to project scope.
- ADR 0015 (design & brand ownership) — depends on the
  `cdo → design-lead` rename codified here.
- ADR 0016 (framework scope position) — depends on the CTO
  promotion + eng-platform expansion codified here; in particular
  ADR 0016 articulates *why* the framework is software-flavored
  by design, which justifies eng-platform as default-mandatory.
- Handbook ADR 0004 (agent action guardrails) — Track 2 bash
  policy keys rename in the per-agent allow-list; Track 3 audit
  log rows pre-rename are preserved via `role_aliases`.
- `juvantlabs/juvant-os-pm` ARCH-010 (to be filed at v0.8.0
  ship) — historical "what was renamed and why" reference for
  adopters arriving from blog posts citing v0.6/v0.7 vocabulary.
