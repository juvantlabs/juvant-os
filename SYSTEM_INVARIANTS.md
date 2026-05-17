# SYSTEM INVARIANTS

> Canonical source of truth for invariants that span all subagent templates.
>
> The subagent templates in `agents/**/*.md` (10 mandatory company-scope +
> up to 2 optional company-scope + 8 per-project) defer to this document
> for: bootstrap protocol, naming convention, disclosure fallback cascade,
> single-writer invariant, universal CONFIDENTIAL list, spec authorization
> matrix, and architectural principles.
>
> Future modifications to any of these invariants happen here, then propagate
> to subagent files via the standard versioning flow (CHRO proposes → CEO
> approves → CTO designs `pr-spec` → eng-platform executes at company
> scope; project Eng Lead executes at project scope).
>
> All written artifacts in English. No exceptions.

---

## §1 — Bootstrap Protocol

The CSO Manifesto Precondition Gate (cso.md) requires a passing CSO audit
≤30 days on file before any agent can enter Tier 1 manifesto review. This
creates a chicken-and-egg deadlock at day-1 fork initialization: CSO itself
needs an audit before its own manifesto can be approved.

The Bootstrap Protocol resolves this with a one-shot CEO-override mode for
the founding N agents (see "Founding agent count" below).

### Founding agent count

The founding manifesto count is **company-scope only** and parameterized
by the optional-role toggles set at company init in
`.juvant/config.json`'s `feature_toggles`:

```
N = 9 (mandatory company)
  + (1 if feature_toggles.eng_platform_enabled, default true)
  + (1 if feature_toggles.cro_enabled,           default false)
  + (1 if feature_toggles.vpe_enabled,           default false)
```

- **Default at v0.8.0**: `N = 10` (9 mandatory + eng-platform on).
- **Maximum**: `N = 12` (all three optional roles enabled).
- **Minimum**: `N = 9` (eng-platform disabled — only valid for
  non-software company-only adopters per ADR 0016).

Per-project agents (PCA, Product Lead, Design Lead, Eng Lead, eng-api,
eng-backend, eng-frontend, eng-ai = 8 per project) are **not** counted
in N. They bootstrap separately at project-init, after company
bootstrap completes; each goes through the same Tier-1-bootstrap +
Tier-2 review flow individually with the post-bootstrap CSO precondition
gate.

### Bootstrap entry conditions

A fork enters Bootstrap Mode when ALL of the following hold:

- The fork has just been initialized (`git push --mirror` from
  `juvantlabs/juvant-os` complete).
- `master_context.bootstrap_completed_at IS NULL`.
- `agent_tool_matrix` has been seeded with the v0 default matrix (CTO-owned
  template) but no `manifests` rows yet exist.
- The CEO has launched Claude Code in the fork directory and invoked
  `Initialize Juvant OS` (the JUVANT_OS.md skill orchestrator).

### Bootstrap procedure (CEO-only override)

1. The skill compiles all `{{PLACEHOLDER}}` values per the company init
   wizard and writes the compiled subagent files to `agents/**/*.md`.
2. The skill seeds the `manifests` table with one row per agent, each in
   `status='draft'` with the manifesto body authored from a default template.
3. CEO reviews each manifesto draft via the skill's interactive flow.
   The CEO may edit or accept verbatim.
4. For each accepted manifesto, the skill writes:
   - `manifests.tier1_ceo_approved_at = NOW()`,
   - `manifests.tier1_bootstrap = 1`,
   - `manifests.precondition_bypassed = 'bootstrap'`,
   - `manifests.status = 'operational_restricted'`,
   - `manifests.tier1_bootstrap_payload = <single CEO sign-off record>`.
5. The agent transitions to `OPERATIONAL_RESTRICTED` with the standard
   `[MANIFESTO PENDING]` flag visible on outputs.
6. Tier 2 async review (7-day window) follows the standard flow. CEthO,
   CHRO, CTO review during Tier 2 even though they themselves are also in
   bootstrap. Tier 2 reviews of bootstrap manifestos record
   `tier2_bootstrap = 1` for traceability.
7. CSO performs the first system audit immediately after all N agents
   reach `OPERATIONAL_RESTRICTED`. The audit output goes to `decisions`
   category `system-audit` with `bootstrap_baseline = 1`.

   The audit is performed **by the CSO subagent**, invoked via
   `Task(subagent_type='cso', ...)`. The Skill orchestrating the
   bootstrap **MUST NOT** synthesize the audit verdict in-session and
   **MUST NOT** write `security_audit_log` rows with `auditor='cso'`
   directly. If `subagent_type='cso'` does not resolve (e.g.
   `.claude/agents/cso.md` symlink missing per ADR 0010), the bootstrap
   aborts with explicit error and `master_context.bootstrap_completed_at`
   stays NULL — there is no fallback path that bypasses the subagent.
   This rule closes the cover-up failure mode of handbook ADR 0004:
   a Skill that fabricates a CSO audit verdict is structurally
   indistinguishable from a malicious agent forging audit history. CSO
   Layer 5 detects orphan rows (see `agents/company/cso.md` § Layer 5).
8. When all N agents complete Tier 2 AND the first CSO audit returns
   PASS or WARN-WITH-CONDITIONS, the skill writes:
   - `master_context.bootstrap_completed_at = NOW()`,
   - all `manifests.status = 'operational'` (where Tier 2 cleared),
   - all `manifests.restricted = 0`.

### Bootstrap mode is one-shot

- `master_context.bootstrap_completed_at` is set exactly once. It does not
  reset.
- Any subsequent agent addition (e.g. enabling CRO or VPE post-bootstrap,
  or introducing a new role via tool-matrix extension) follows the
  standard manifesto lifecycle WITH the CSO precondition gate enforced.
- A corrupted bootstrap (interrupted compilation, partial state, mid-flow
  failure) is recovered by deleting the fork's `.juvant/` directory and
  re-running `Initialize Juvant OS`. There is no partial bootstrap recovery.
- The `precondition_bypassed = 'bootstrap'` flag persists on every founding
  manifesto record forever as audit history. CSO audits explicitly check
  for this flag and treat it as expected ONLY on rows with `tier1_bootstrap = 1`.

### Bootstrap CEO-only override authority

During Bootstrap Mode, the CEO holds combined authority that during normal
operation is split among CHRO + CTO + CSO + CEthO. The override is bounded:

- ONLY for the founding N agents (per "Founding agent count" above).
- ONLY during the bootstrap session(s) before
  `master_context.bootstrap_completed_at` is set.
- ONLY via the JUVANT_OS.md skill flow (no manual `manifests` table writes).
- All bootstrap actions are logged to `decisions` category `bootstrap-action`
  for permanent audit trail.

The CEO cannot bypass:
- The Universal CONFIDENTIAL list (§5) — even at bootstrap.
- The Universal Boundaries (single-writer-per-scope per §4 — no
  `github:write` to non-`eng-platform` at company scope, no
  `github:write` to non-`eng-lead` at project scope; no `bank:write`
  to non-treasury; etc.).
- Plus: the manifesto draft itself, even at bootstrap, must pass structural
  completeness checks (identity, scope, ethical commitments, anti-pattern
  absence) — the skill enforces these checks before recording approval.

### Post-bootstrap state

After `master_context.bootstrap_completed_at` is set:

- The CSO Manifesto Precondition Gate is structural and unbypassable.
- New agents (e.g. portal variants in v1.1, future CRM-integrated roles)
  follow the standard CTO → CSO audit → CHRO Tier 1 → Tier 2 → CEO
  approval flow.
- Bootstrap-marked manifestos remain auditable; CSO Layer 5 audits include
  a check that bootstrap manifestos have not been silently re-classified.

---

## §2 — Default Naming Convention

All subagent templates use `{{PLACEHOLDER}}` syntax. The JUVANT_OS.md skill
substitutes placeholders at company init from the values below.

### Agent name placeholders (defaults) — company scope

Mandatory (always bootstrapped):

| Placeholder | Default name | Role | Scope |
|---|---|---|---|
| `{{COS_NAME}}` | Atlas | Chief of Staff | Company |
| `{{CFO_NAME}}` | Theos | Chief Financial Officer | Company |
| `{{CLO_NAME}}` | Lex | Chief Legal Officer | Company |
| `{{CMO_NAME}}` | Mira | Chief Marketing Officer | Company |
| `{{CCO_NAME}}` | Clio | Chief Commercial Officer | Company |
| `{{CHRO_NAME}}` | Sage | Chief Human Resources Officer | Company |
| `{{CSO_NAME}}` | Shield | Chief Security Officer | Company |
| `{{CETHO_NAME}}` | Vera | Chief Ethics Officer | Company |
| `{{CTO_NAME}}` | Arch | Chief Technology Officer | Company |

Optional, gated by `feature_toggles` in `.juvant/config.json`:

| Placeholder | Default name | Role | Toggle | Default |
|---|---|---|---|---|
| `{{ENG_PLATFORM_NAME}}` | Hephaestus | Platform Engineer | `eng_platform_enabled` | **true** |
| `{{CRO_NAME}}` | Lumen | Chief Research Officer | `cro_enabled` | false |
| `{{VPE_NAME}}` | Helm | VP of Engineering (cross-project aggregator) | `vpe_enabled` | false |

`eng-platform` is mandatory by default for software adopters (per
ADR 0016 framework positioning); the toggle is preserved for
non-software company-only adopters who don't need a company-scope
infra writer. CRO ships off-by-default for adopters without active
research-synthesis needs. VPE (renamed from project-scope per
ADR 0014) ships off-by-default and is intended for multi-project
software adopters who want a cross-project engineering aggregator
distinct from the company CTO.

Optional roles are introduced post-bootstrap via the standard Hire
flow (CHRO opens `hiring_log` row, CTO authors `pr-spec`, CEO
approves, eng-platform installs the templated
`agents/company/<role>.md` file at company scope). The eng-platform
template (`agents/company/eng-platform.md`) ships an opinionated
Azure-first default starter set of 14 Hard Conventions; the hire
pr-spec is where the CEO ratifies, amends, or removes them per
adoption.

### Project-scope agent name placeholders

Project-scope agents are instantiated per project. The placeholder resolves
to a project-suffixed default unless the project init flow specifies otherwise.

| Placeholder | Default pattern | Role |
|---|---|---|
| `{{PCA_NAME}}` | `<project_id>-pca` | Project Chief Architect |
| `{{PRODUCT_LEAD_NAME}}` | `<project_id>-product-lead` | Product Lead for the project |
| `{{DESIGN_LEAD_NAME}}` | `<project_id>-design-lead` | Design Lead for the project |
| `{{ENG_LEAD_NAME}}` | `<project_id>-eng-lead` | Engineering Lead for the project (sole project-scope `github:write`) |

Eng/* agents (eng-api, eng-backend, eng-frontend, eng-ai) do not have a
human-name placeholder; they are referenced by their role identifier.

VPE has been removed from project scope per ADR 0014; cross-project
engineering aggregation, when needed, is handled at company scope by
the optional VPE role (toggle above) or by the company CTO directly
when no VPE is enabled.

### System placeholders

| Placeholder | Default value | Used in |
|---|---|---|
| `{{COMPANY_NAME}}` | (set at company init) | All templates |
| `{{COMPANY_DOMAIN}}` | (set at company init) | CMO, CCO, CFO, CLO press/legal/sales mailbox routing |
| `{{CEO_NAME}}` | (set at company init) | All templates — the human authority |
| `{{ACTIVE_PROJECT}}` | (set at session boot per Boot Mode) | CoS Teams card channels |
| `{{PROJECT_NAME}}` | (set at project init) | All project-scope templates |
| `{{AGENT_NAME}}` | resolved per agent (above) | All templates |
| `{{AGENT_DESCRIPTION}}` | resolved per company init | All templates — short 1-line elaboration |

### Per-template tunables (defaults shipped in templates)

| Placeholder | Default | Used by |
|---|---|---|
| `{{HIGH_VALUE_THRESHOLD}}` | €10,000 | CFO Security Rule #7 |
| `{{SPRINT_LENGTH}}` | 2 weeks | Eng Lead Sprint Coordination Protocol |
| `{{ACCESSIBILITY_FLOOR}}` | WCAG 2.2 AA | Design Lead Accessibility Protocol |
| `{{RUNBOOK_DRILL_CADENCE}}` | 90 days | Eng Lead Runbook drill cadence |
| `{{POSTS_PER_CHANNEL_PER_WEEK}}` | 3 | CMO Buffer cadence |
| `{{TIER_STRATEGIC}}` | Strategic | CCO Partnership tiers |
| `{{TIER_COMMERCIAL}}` | Commercial | CCO Partnership tiers |
| `{{TIER_TECHNICAL}}` | Technical | CCO Partnership tiers |
| `{{VOICE_LONGFORM}}` | considered, evidence-led | CMO voice modes |
| `{{VOICE_TWITTER}}` | concise, builder, no hype | CMO voice modes |
| `{{VOICE_LINKEDIN}}` | professional, grounded, no slogans | CMO voice modes |
| `{{VOICE_PRESS}}` | factual, attributable, AP-style | CMO voice modes |
| `{{VOICE_BLOG}}` | conversational expert, examples-first | CMO voice modes |
| `{{VOICE_CRISIS}}` | calm, factual, accountable, no hedging | CMO voice modes |
| `{{W_COMPLETION}}` | 0.30 | CHRO ranking weight |
| `{{W_EFFICIENCY}}` | 0.20 | CHRO ranking weight |
| `{{W_ESCALATION}}` | 0.30 | CHRO ranking weight |
| `{{W_QUALITY}}` | 0.20 | CHRO ranking weight |
| `{{BACKEND_LANG}}` | Python | CTO tech standards |
| `{{BACKEND_FRAMEWORK}}` | FastAPI | CTO tech standards |
| `{{FRONTEND_PLATFORM}}` | React Native + Expo | CTO tech standards |
| `{{WEB_FRAMEWORK}}` | Next.js | CTO tech standards |
| `{{MONOREPO_TOOL}}` | Turborepo | CTO tech standards |
| `{{STATE_SERVER}}` | TanStack Query | CTO tech standards |
| `{{STATE_CLIENT}}` | Zustand | CTO tech standards |
| `{{FORMS_LIB}}` | React Hook Form + Zod | CTO tech standards |
| `{{DATABASE}}` | LibSQL via Turso | CTO tech standards |
| `{{OBSERVABILITY}}` | OpenTelemetry | CTO tech standards (mandatory) |
| `{{CICD}}` | GitHub Actions | CTO tech standards |

### Substitution rules

- The skill performs whole-token substitution (no partial matches).
- Substitution happens at company init for company-scope agents and at
  project init for project-scope agents.
- Re-substitution after init requires the standard tool-matrix change flow
  (CTO proposes → CEO approves → CTO `pr-spec` → eng-platform executes
  at company scope, or the project's Eng Lead at project scope).
- The placeholder syntax `{{...}}` is reserved. Any `{{...}}` that appears
  in committed agent output is a substitution failure and triggers a
  CSO Layer 5 audit finding, **with the explicit exception of the runtime-
  bound allowlist below.**

#### Runtime-bound allowlist (exempt from the substitution-failure rule)

The following placeholders are bound at runtime, not at compile time, and are
expected to survive in compiled agent files:

| Placeholder | Bound when | By |
|---|---|---|
| `{{ACTIVE_PROJECT}}` | SessionStart | CoS Boot Mode resolution (see CoS Session Start Protocol step 4) |

CSO Layer 5 audits skip these placeholders during the substitution check.
Any other surviving `{{...}}` token remains a `FAIL`. Adding a new entry to
this allowlist requires a SYSTEM_INVARIANTS.md amendment per Appendix B
governance — it is not a routine matrix change.

---

## §3 — Unified Disclosure Fallback Cascade

When any agent detects that `disclosure_policies` is unreachable or returns
zero active rows, it applies a unified four-tier cascade. Per-agent extensions
(documented in CoS, eng-platform, eng-lead, Eng/*) build on top of this
baseline; they do not replace it.

### Tier 1 — Universal (every agent)

Apply ALL of the following:

1. Treat ALL information in the current session as CONFIDENTIAL.
2. Refuse to draft any external-facing artifact.
3. Insert a row into `inbound_queue` with `agent_owner='cos'`, `priority='High'`,
   `source='internal-handoff'`, content describing the fallback condition
   (which policy table query failed, when, on which DB).
4. Insert a row into `security_audit_log` with category
   `disclosure-unavailable`, severity `medium`, agent identifier, and a
   pointer to the inbound_queue row.
5. Continue internal work that does not require disclosure classification
   (read-only operations, internal drafts, schema lookups).

The Tier 1 cascade is mandatory for every agent that reads
`disclosure_policies`. There is no exemption.

### Tier 2 — CoS-side aggregation

CoS, in addition to applying Tier 1, performs aggregation:

1. On every `inbound_queue` row with category `disclosure-unavailable`,
   start a `T+5min` timer (recorded in the row's `escalation_due_at`).
2. If at `T+5min` the policies are still unreachable (verified by re-query),
   escalate:
   - Send `Telegram` Critical to `{{CEO_NAME}}` with content:
     "Disclosure policies unreachable for >5min. N agents in fallback.
     Sources: [list of agent identifiers]."
   - Apply `[DISCLOSURE FALLBACK ACTIVE]` prefix to all CoS outputs to
     CEO until the cascade clears.
   - Insert a `decisions` row category `cascade-escalation` with the
     timeline.
3. If policies recover (re-query returns ≥1 active row) before T+5min,
   close the inbound_queue rows with status `resolved-self-clearing`,
   record the recovery timestamp in `security_audit_log`, and notify
   CSO via `inbound_queue` priority `High` for post-incident audit.
4. CoS does not lift the cascade; recovery is structural, not declarative.

### Tier 3 — Per-scope writer single-writer extension

The writer for each affected scope (eng-platform at company scope; the
project's eng-lead at project scope), in addition to applying Tier 1,
halts ALL spec execution **for its scope** while the cascade is active.
Cascades are scope-local: an active project-scope cascade does not halt
eng-platform; an active company-scope cascade does not halt project
eng-leads.

For each affected writer:

1. Reject every spec in `inbound_queue WHERE agent_owner=<writer-role>
   AND status='pending'` with reason `cascade-active`. The author
   re-submits after recovery.
2. Refuse new GitHub writes (or cloud/npm writes for eng-platform) of
   any kind for the affected scope. The single-writer property inverts
   to single-reader-only during cascade.
3. Active-but-uncompleted multi-step specs (e.g. a release-spec
   mid-execution) pause at the next step boundary; the partial state
   is recorded in a `decisions` row category `spec-paused-cascade`.
4. Resume happens automatically when CoS records cascade recovery
   for the affected scope.

### Tier 4 — Eng/* aggregation routing

Eng/* agents, in addition to applying Tier 1, route their fallback
notification to the project's **Eng Lead** for project-scope
aggregation (replacing the per-project VPE that existed pre-v0.8.0):

1. The `inbound_queue` Tier 1 insert uses `agent_owner='eng-lead'`
   (project-scoped) rather than `agent_owner='cos'`.
2. The project's Eng Lead aggregates Eng/* fallbacks and forwards
   to CoS as a single `inbound_queue` row priority `High` with
   content "Eng/* fallback cascade: <count> agents, project
   <project_name>".
3. When `feature_toggles.vpe_enabled = true` AND multiple projects
   are concurrently affected, CoS performs a second-level aggregation
   under VPE (cross-project rollup) — VPE receives a single forwarded
   row "Cross-project Eng/* cascade: <count> projects". When
   VPE is disabled (default) OR only one project is affected, the
   Eng Lead → CoS path is the only routing.
4. CoS treats the aggregated row as a single Tier 1 trigger
   (not <count> triggers), simplifying the cascade aggregation.

### CSO post-incident audit

After cascade recovery, CSO automatically opens an investigation:

1. Read `security_audit_log WHERE category='disclosure-unavailable'` for
   the cascade window.
2. Determine root cause: Turso outage, query bug, network partition,
   credential lapse, etc.
3. Author a `decisions` row category `cascade-postmortem` with: trigger,
   duration, agents affected, recovery mechanism, structural recommendations.
4. If the root cause is reproducible structural (e.g. credential expiration
   without rotation runbook), generate `branch-protection-spec` or
   `secret-rotation-spec` for the affected scope's writer (eng-platform
   at company scope; the project's Eng Lead at project scope).

### What the cascade does NOT do

- It does not stop internal work (read-only operations, internal drafts).
- It does not pause CHRO ranking computation, CSO scheduled audits, CRO
  research synthesis (these are internal artifacts).
- It does not affect agents whose tool matrix does not include disclosure-
  policy access (e.g. eng-* during purely internal refactors).

---

## §4 — Single-Writer Invariant (per-scope)

> Authoritative references: `agents/projects/eng-lead.md`,
> `agents/company/eng-platform.md`, and `agents/company/cto.md`
> (Architectural Principle #4). Restructured per ADR 0014.

The single-writer property holds **per scope**, not system-wide. The
system has two write scopes; each has exactly one writer.

### Company-scope writer: `eng-platform`

The company fork repo (`<adopter>/<adopter-os>` or equivalent), the
template/IaC repo, the cloud control plane, and the npm registry are
written **only** by `eng-platform`. Capabilities: `github:write`
(company repo only), `cloud:write` (azure/aws/gcp/turso per
`feature_toggles.cloud_provider`), `npm:publish`.

### Project-scope writer: `eng-lead` (per project)

Each project's repo (`<adopter>/<project-slug>`) is written **only**
by that project's `eng-lead`. Capabilities: `github:write` (that
project's repo only). One `eng-lead` per project; cross-project
writes are not permitted.

### Universal rules

- All other agents that need a write at either scope produce a spec
  (one of the spec classes in §6) in the `decisions` table. The
  scope's writer reads, verifies (5-check protocol), and executes.
- **Cross-scope writes are forbidden.** An `eng-lead` cannot write
  to the company repo under any spec or rationale; `eng-platform`
  cannot write to a project repo under any spec or rationale. Each
  writer's 5-check protocol verifies the spec's target scope matches
  its own scope before execution.
- This single-writer-per-scope property is a security invariant,
  not a preference. CTO cannot grant `github:write` to any other
  agent under any rationale.

**Disclosure-boundary corollary** — `state.db` read AND external-channel
send in the same matrix row collapses the disclosure boundary and is
forbidden. The corollary applies **per scope**: the company-scope writer
cannot also hold a company-scope external channel; the project-scope
writer cannot also hold a project-scope external channel. The operational
enumeration, plus the `<channel>:send-ceo-only` carve-out for
operator-direct notifications, lives in `docs/MCP_INVENTORY.md`
§ Universal Boundaries. See
[ADR 0011](docs/adr/0011-ceo-direct-channel-class.md) for the
channel-class definition and the wizard's Step 4 confirmation gate
that enforces the operator-recipient contract.

**Tier 3 disclosure cascade extension** — when the §3 cascade activates,
the writer for the affected scope halts spec execution at the next
step boundary (independently per scope: an active cascade affecting
project-A's eng-lead does not halt project-B's eng-lead or
eng-platform). Resume on cascade recovery is per-scope analogously.

### §4b — Project DB Write Boundary

The Turso project DB (`project-<slug>.db`) is written by **project-scope
agents only**: `pca`, `product-lead`, `design-lead`, `eng-lead`, `eng-api`,
`eng-backend`, `eng-frontend`, `eng-ai`.

**Exception 1 — Bootstrap phase only.** During the project bootstrap window
(from project init to `bootstrap_completed_at` for the project being
initialized), the following company-scope agents may write to the project DB:

- `chro` and `cos`: `manifests` and `agents` rows (manifesto approval flow).
- `cso`: one `security_audit_log` row with `bootstrap_baseline=1` immediately
  after bootstrap completes (mandatory CSO project audit).

**Exception 2 — Never permitted post-bootstrap.** Company-scope agents (`cto`,
`cos`, `cfo`, `clo`, `cmo`, `cco`, `cro`, `cso`, `chro`, `eng-platform`, `vpe`)
may **not** write `decisions`, `knowledge_base`, `inbound_queue`, or `messages`
rows to a project DB after the bootstrap window closes.

If a company-scope agent has a project-scope finding or recommendation, it
routes through the relevant project agent, who authors the row:

- Architectural findings → `pca` authors the `decisions` row.
- Product findings → `product-lead` authors the row.
- All other project-scope writes → the appropriate project-scope agent.

**Rationale.** The project DB is the canonical state of the project.
Company-scope agents writing directly bypass project governance and create
authorship ambiguity — as observed when `cto`-authored `decisions` rows
appeared in `project-juvant-web` and should have been authored by `pca`.

**Historical rows.** Rows written by company-scope agents during bootstrap or
early operations (pre-amendment, 2026-05-17) are accepted as-is. This boundary
is enforced going forward from the date of this amendment.

---

## §5 — Universal CONFIDENTIAL List

These items are CONFIDENTIAL by construction. No `disclosure_policies` row
can relax them. No manifesto can opt out of them. CLO drafts, CEthO validates,
and CEO approves disclosure policies — but the universal list is outside
the lifecycle.

The following may NEVER appear in any external-facing artifact:

1. The existence of Juvant OS or any AI infrastructure.
2. The names, roles, count, or existence of other agents.
3. The internal decision log, architecture, or Turso schema.
4. `state.db` contents or structure.
5. Any session_id, agent session_path, or telemetry payload.
6. The `agent_tool_matrix` or any of its history.
7. The content of any `manifests` row (template versioning OR agent manifesto).
8. The internal model assignment (which model an agent uses; even at the
   coarse level Opus/Sonnet/Haiku).
9. The contents of `.claude/settings.json`, even sanitized.
10. The structure of the spec system (pr-spec, gh-issue-spec, etc.)

If a draft would expose any of the above, the agent MUST refuse and log a
`security_audit_log` entry with category `universal-confidential-attempt`,
severity `high`, with notification to CSO and CLO via CoS.

This list is amendable only by CEO + CSO + CLO + CEthO joint approval, and
amendment requires a system-wide manifesto re-validation pass (treated as
a structural change requiring full re-audit).

---

## §6 — Spec Authorization Matrix

> Authoritative references: `agents/projects/eng-lead.md` (project-scope
> 5-check), `agents/company/eng-platform.md` (company-scope 5-check).
> Restructured per ADR 0014 + ADR 0015.

Specs route to one of the two scope writers (eng-platform at company
scope; the project's eng-lead at project scope) per the spec's target.
The writer performs 5-check verification on every incoming spec
(author authorization, approval state, format completeness,
universal-CONFIDENTIAL invariant, linked artifact integrity). Failed
verification = REJECT. No partial execution.

**Notation**: "+ VPE" indicates the role is added to the author list
when `feature_toggles.vpe_enabled = true`. "Eng Lead" refers to the
specific project's Eng Lead when the spec is project-scoped.

| Spec category | Authorized authors | Approver | Executor (writer) |
|---|---|---|---|
| `pr-spec` (project) | PCA, Design Lead, CSO | PCA | Eng Lead (project) |
| `pr-spec` (company) | CTO, CSO | CTO | eng-platform |
| `gh-issue-spec` | Product Lead, PCA, Design Lead, CSO (+ VPE) | PCA (project) / CTO (company) | Eng Lead / eng-platform per scope |
| `gh-project-update-spec` | Product Lead, PCA, Design Lead (+ VPE) | PCA / CTO | Eng Lead / eng-platform |
| `gh-milestone-spec` | Product Lead, PCA | PCA / CTO | Eng Lead / eng-platform |
| `install-spec` | CTO | CTO | eng-platform |
| `branch-protection-spec` (project) | CSO, PCA | PCA | Eng Lead (project) |
| `branch-protection-spec` (company) | CSO, CTO | CTO | eng-platform |
| `release-spec` | PCA (+ VPE) | PCA / CTO | Eng Lead / eng-platform |
| `deployment-spec` | PCA (+ VPE) | PCA / CTO | Eng Lead / eng-platform |
| `secret-rotation-spec` | CSO | CSO | eng-platform (company) / Eng Lead (project) |
| `gh-pr-review-spec` | Eng Lead (delegated by PCA when architectural; or VPE at cross-project review when enabled) | PCA / CTO | Eng Lead / eng-platform |
| `eng-platform-spec` | eng-platform | CTO | eng-platform |
| `brand-spec` (mode: inherit / extend) | Design Lead (project), CMO (company) | CMO | Design Lead / CMO |
| `brand-spec` (mode: independent) | Design Lead (project) | CEO (mode ratification) + Design Lead executes; CMO advisory in parallel (NOT validator against company brand book — see ADR 0015) | Design Lead |
| `brand-mode-ratification` | n/a (system-emitted from first independent brand-spec) | CEO | n/a (records mode for project) |

The `eng-platform-spec` class covers company-scope infra changes that
don't fit `pr-spec` / `install-spec` (IaC drift, cloud control-plane
bumps, npm version cuts). The eng-platform agent is both author and
executor; the 5-check protocol still runs and CTO is the
approver-of-record gating execution.

The `brand-spec` class lifecycle, mode semantics, and CMO
advisory-vs-validator boundary are codified in
[ADR 0015](docs/adr/0015-design-brand-ownership.md).

---

## §7 — Architectural Principles

> Authoritative reference: `agents/company/cto.md`.

Summary (cited when CTO APPROVE/REJECT/DEFER any change):

1. Composition over modification.
2. Boundary enforcement.
3. Read-before-write.
4. Single-writer where possible.
5. Schema as source of truth.
6. Versioning everything.
7. Observability mandate (OpenTelemetry).
8. Locality of authority.
9. Reversibility favoritism.
10. Boring tech wins.
11. English everywhere.

---

## §8 — CoS dispatcher constraint (Claude Code structural limit)

The `Task` tool is available **only to the main thread**. Sub-agents cannot
spawn nested sub-agents — Claude Code structurally prevents it regardless of
what a sub-agent's `tools:` frontmatter declares.

Consequence for the CoS dispatcher pattern:

- **CoS as main thread (correct):** The operator opens `claude` in the company
  directory. CoS is the session identity. `Task(subagent_type='<role>', ...)`
  works; CoS fans out to specialists normally.
- **CoS as sub-agent (broken fan-out):** An outer orchestrator calls
  `Task(subagent_type='cos', ...)` expecting CoS to dispatch further.
  CoS runs but has no `Task` tool; any attempt to fan-out is silently a
  no-op. There is no error — CoS simply cannot dispatch.

**Rule:** Never invoke `Task(subagent_type='cos', ...)` from an outer
orchestrator and expect nested dispatch. CoS MUST be the main thread
to exercise its dispatcher role. The `Task` declaration was removed from
`agents/company/cos.md` `tools:` to eliminate the dead-code signal (closes
issue #21).

---

## Appendix A — Cross-references in subagent files

Subagent files reference this document at their identity section via a
standard pointer:

```
> Refer to `SYSTEM_INVARIANTS.md` for: Bootstrap Protocol (§1),
> Default Naming Convention (§2), Unified Disclosure Fallback Cascade (§3),
> Single-Writer Invariant (§4), Universal CONFIDENTIAL List (§5),
> Spec Authorization Matrix (§6), Architectural Principles (§7).
> This template defers to those invariants where applicable.
```

Per-template extensions to invariants (e.g. CoS's Tier-2 aggregation
logic, the per-scope writer's Tier-3 single-writer halt, Eng/*'s
Tier-4 routing through the project Eng Lead with optional VPE
cross-project rollup) remain in the respective subagent files as they
encode role-specific behavior on top of the canonical baseline.

---

## Appendix B — Modification governance

Changes to this document follow the standard versioning flow:

1. Proposer drafts a change (CHRO if discovered via drift; CTO if
   discovered via tool-matrix interaction; any agent in principle).
2. CoS routes the proposal to CEO.
3. CEO approves.
4. CTO designs `pr-spec` (company-scope; SYSTEM_INVARIANTS.md is a
   company-scope artifact).
5. eng-platform opens PR; review involves CHRO + CTO + CSO + CEthO.
6. After merge, CHRO triggers a system-wide manifesto re-validation pass
   if the change touches §1, §3, §4, §5, or §6. Changes touching only §2
   (naming) or §7 (principles citation) are non-structural and do not
   require re-validation.

---

End of SYSTEM_INVARIANTS.md.
