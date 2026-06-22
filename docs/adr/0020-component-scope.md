# ADR 0020 — Component-scope: a lightweight third tier for single-responsibility repos (library / MCP server / toolbox)

## Status

Proposed (2026-06-22). **Extends ADR 0019.** ADR 0019 modeled `juvantlabs`
as one full-roster project covering every OSS repo (`juvant-os`, `engram`,
the MCP servers, `labs-web`). In practice the 8-agent roster (PCA + Product +
Design + Eng Lead + 4×eng) + a per-project DB + a board is **over-structure**
for a single-responsibility repo. This ADR introduces a third, lighter scope —
**component-scope** — so the long tail of libraries, MCP servers, and toolboxes
can be maintained without that ceremony, while the big products stay full
projects.

## Context

The framework has exactly two scopes today (SYSTEM_INVARIANTS §4):
**company-scope** and **project-scope**. A project always carries a full
roster, its own `project-<slug>.db`, a board, and (per the juvantlabs pattern)
a `-pm` sibling repo.

A library / MCP server / toolbox has no "product" to manage and no "design"
surface: it is single-responsibility code that is touched **episodically**.
It needs only: someone who writes the code, an architectural eye, a
single-writer on GitHub, and a backlog. Everything else (Product, Design,
PCA, 4×eng, a project DB, a board, a `-pm` repo) is dead weight.

Two design facts shaped the decision:

1. **Roster entries are cheap.** A subagent is a static `*.agent.md` definition
   plus an allow-list row — not a running process. "N maintainers for N repos"
   is **not** a real runtime cost; the real cost of a project is the DB + board
   + multi-agent coordination. So the lever is to drop the *heavy* parts, not
   to collapse identities.

2. **A component's durable state belongs on GitHub, not the company DB.** The
   company DB is the company's *private* operating state. A component's
   backlog, decisions, and knowledge are **repo artifacts** — and this holds
   **regardless of visibility** (a private repo has Issues / Projects / labels
   too). Keeping state on the repo makes the component self-contained and
   portable (it can be forked and maintained without the host instance), and —
   critically — means the maintainer never needs company-DB write, so §4 stays
   intact (no new DB scope to authorize).

## Decision

Introduce **component-scope**, a third tier below project-scope.

### 1. What is a component

A single-responsibility `juvantlabs` repo of type **`library`**,
**`mcp-server`**, or **`toolbox`**. Big products that need product/design
coordination remain full **projects** (e.g. `juvant-os`). The cut:

- **Full project** — needs a roster that coordinates (Product/Design/Eng):
  e.g. `juvant-os`.
- **Component** — single-responsibility code, maintained episodically: e.g.
  `engram`, `m365-graph-mcp-server`, `aruba-fattura-mcp-server`, `juvant-tools`.

`juvant-os` graduates to its own full project (it has a backlog, an arch
surface, a `-pm`); the lib/MCP/toolbox repos become components.

### 2. The maintainer agent

Each component gets **one** `<slug>-maintainer` agent — a **principal /
staff-level full-stack engineer with first-class AI/LLM engineering ability**,
who owns the repo **end-to-end** (architecture, implementation, tests, docs,
security, releases) with no handoffs. The AI/LLM dimension is explicit and
load-bearing: several components *are* AI (e.g. `engram` has an LLM part; the
MCP servers orchestrate models), so the maintainer must do prompt/eval/agentic
design, LLM integration, context/token management, and model selection — not
just generic full-stack.

- **Model: `opus`** (the latest most-capable Opus). Rationale: the maintainer
  is **solo** (no PCA/eng-lead/reviewer safety net — it is architect +
  implementer + reviewer in one), it is the **single-writer** (errors are
  costly with no second pair of eyes), and usage is **episodic** so the cost
  premium is bounded (components are the long tail, not 24/7). Capability and
  autonomy outweigh per-invocation cost here.
- **Per-task downshift** (lever, not default): the `model-override` decision
  path may run a genuinely mechanical task (dep bump, typo) on Sonnet; baseline
  stays Opus.
- **Single-writer for its own repo** (see §5). The Track-2d gate authorizes the
  maintainer *role* to perform git/gh writes; binding the write to *only* the
  maintainer's own repo is by working-tree access + dispatch discipline today
  (the same property eng-lead had). Hard repo-scoped enforcement (for eng-lead
  and maintainer alike) is now in place — **FEAT-054** (v1.10.0): the Track-2d
  gate confines git/gh writes to the writer's owned repo/working-tree set
  (`components[].repo`/`working_tree` for a maintainer; a project's
  `github_repos[]` + `working_tree` + `additional_working_trees[]` for an
  eng-lead, N repos supported), failing open only when the target is
  undeterminable.
  It escalates to **Arch (CTO)** for cross-cutting architectural choices and to
  **eng-platform** for release / npm / CI / infra.

### 3. State lives on GitHub (visibility-agnostic)

| Concern | Home |
|---|---|
| Backlog | GitHub **Issues + Projects** on the repo (no `-pm` sibling) |
| Decisions | In-repo **ADRs** (`docs/adr/*.md`) and/or Issues labeled `juvant:decision` |
| Knowledge | In-repo **docs / README + Discussions** |
| Audit of maintainer actions | `agent_actions_log` (hook-written, automatic) |

There is **no** component DB and **no** `-pm` repo, and the component's
**ongoing** decisions / knowledge are **not** kept in the company
`decisions` / `knowledge_base` tables — they live on the repo. The single
exception is a **one-time `bootstrap-action` registration row** in the company
`decisions` table recording that the company adopted the component (the
company's own act, not component state) — an audit-trail entry, not a place
where component decisions accrue. State is on the repo whether public or private.

### 4. Registry + CEO ratification

- **Registry**: `.juvant/config.json` `components: [{slug, repo, visibility,
  maintainer, type, maturity}]`. No DB table, no migration; enumerable with
  `jq`; consistent with other config-like, slow-changing lists.
- **CEO ratification preserved via a label.** An open Issue labeled
  **`juvant:decision`** is the GitHub-native equivalent of a `decisions` row
  with `status='proposed'`: maintainer opens it (proposed) → CEO approves
  (comment / ✅) → maintainer executes and closes it with the artifact ref
  (executed). The "CEO ratifies decisions" invariant is unchanged — only its
  storage moves from a DB `status` to a GitHub label. (`juvant:decision` reuses
  the existing FEAT-039 reconciliation label rather than introducing a second
  convention.)
- **Boot / wrap-up surfacing**: one timeout-wrapped, best-effort call per unique
  org in `components[].repo` (the label's colon must be quoted, else `gh search`
  mis-parses it) —

  ```bash
  # for each <org> in (components[].repo | split("/")[0] | unique):
  bash helpers/with-timeout.sh 30 \
    gh search issues --owner <org> 'label:"juvant:decision"' 'state:open' \
    --json repository,number,title
  ```

  CoS cross-references the registry and surfaces pending decisions for CEO
  ratification at SessionStart and at wrap-up. `with-timeout` is mandatory
  (gh can hang — FEAT-052); if GitHub is unreachable the session simply does
  not see them (best-effort, never blocks boot). Routine Issues / PRs are **not**
  pulled — they are the maintainer's operational domain.

### 5. §4 single-writer, intact

The maintainer is a **pure repo-writer**: it writes git/gh (its own repo by
working-tree + dispatch, repo-scoped-enforced via FEAT-054) and never the
company DB. The Track-2d single-writer gate adds `*-maintainer`
to its writer set (alongside `*-eng-lead`, `eng-lead`, `eng-platform`), so a
`<slug>-maintainer` may perform git/gh **writes** while every other agent is
denied. No company-DB write scope is granted, so the §4b/§4c scope-boundary
checks need **no** change — there is no new DB-writing scope to reconcile.
Audit is preserved: the maintainer's `gh`/`git` actions are recorded in
`agent_actions_log` by the hooks, while decision **content** lives on GitHub
(itself an immutable public/repo trail).

### 6. `juv-add-component`

A dedicated command (not a `juv-add-project --profile` flag — the lifecycle is
genuinely different: no DB creation/migrate, no 8-agent roster, no board, no
branch-protection-spec). It:

1. Appends the component to `.juvant/config.json` `components[]`.
2. Compiles one `<slug>-maintainer` agent (`model: opus`) into
   `agents/components/`.
3. Records the conventions (backlog = GH Issues/Projects; decisions =
   `juvant:decision` issues + in-repo ADRs; KB = in-repo docs).
4. Names Arch (CTO) and eng-platform as the shared arch-review / release gates.

## Consequences

**Positive**
- Minimal overhead for the long tail; no per-repo DB / board / `-pm`.
- OSS-native and **portable** — a component is fully self-contained on its repo.
- One model for all components regardless of visibility (public/private).
- §4 stays intact; the work in FEAT-052 (gh + `with-timeout`, gh write-gating)
  is exactly the infrastructure this needs.

**Negative / trade-offs**
- **No SQL aggregation** of component state — boot/wrap-up depends on `gh`
  (network). Mitigated by timeout-wrapping + best-effort; if GitHub is down the
  session does not see pending decisions that run.
- **Asymmetry** with the project model (projects use DB + table + `-pm`;
  components use GitHub + config). This is intentional — components are
  deliberately lighter.
- **Component decisions leave the `decisions` table** — the internal
  tamper-evident cross-check on decision *content* is traded for the public
  GitHub trail; the *actions* remain audit-logged.

## Relationship to ADR 0019

Refines, does not overturn, 0019. `juvantlabs` remains a permanent OSS
department of Juvant Srls. 0019's full-roster project model now applies to the
**big products** (`juvant-os`); the **library / MCP-server / toolbox** repos
move to **component-scope** per this ADR. `labs-web` (the marketing site) is
classified at import time (project if it grows a product/design surface;
component otherwise).
