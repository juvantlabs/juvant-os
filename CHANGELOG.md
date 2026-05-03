# Changelog

All notable changes to Juvant OS will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

All written artifacts in English. No exceptions.

---

## [Unreleased]

### Pending — Phase 6+
- `plugins/m365-mail/` (TypeScript Channel plugin via `defineChannel`) — Phase 6 / Beta.
- Desktop Scheduled Tasks (Morning Brief, Finom poll, fiscal deadlines) — Phase 7 / Beta.
- Test scenarios (`tests/scenarios/`) — Phase 9 / v1.0.
- External Portals (Service + Demo) — Phase 8 / v1.1.
- `juvantlabs/finom-mcp-server` — FEAT-011 (Beta).
- `juvantlabs/aruba-fattura-mcp-server` — FEAT-012 (Beta).
- `juvantlabs/m365-graph-mcp-server` — FEAT-014 (Beta), re-implement from scratch
  per audit FAIL on `ftaricano/mcp-onedrive-sharepoint`
  (gist: https://gist.github.com/juvantlabs/a9fe0a76a23b0c1260b1e0ad3194a6da).
- Webhook Services cloud receiver — FEAT-015 (Beta), multi-cloud (Azure/AWS/GCP)
  per-company webhook → Turso pipeline.

---

## [0.5.0] — 2026-05-03 — OSS template shipping defaults (FEAT-013)

First minor bump after Alpha. Closes FEAT-013 (`juvantlabs/juvant-os-pm#27`):
the six CSO baseline-audit Tier-2 follow-ups that previously surfaced in
every fresh `Initialize Juvant OS` run are now resolved at the OSS template
level. New per-company instances boot with **zero** Tier-2 follow-ups
(target — to be re-validated on the next dogfood run).

### Added — `.github/CODEOWNERS` template

Path-to-role ownership map with `{{*_GITHUB}}` placeholders rendered at
company-init Step 7.5 from `github_user_map` (Step 1.6). Solo-founder
instances collapse all placeholders to the CEO's GitHub handle; multi-human
teams get per-role overrides. Covers: orchestrator + invariants (CEO + CA),
ADRs (CA), agent templates (CHRO + CA), hooks + schema (CSO + CA),
plugins (CA), infra (CSO + CA), CI (CSO + CA), default fallback (CEO).

### Added — `.github/workflows/lint.yml`

CI workflow runs on PR + push to `main`. Five checks:

1. Markdownlint (relaxed, adopters tighten via `.markdownlint.yaml` in fork).
2. YAML frontmatter parse on every `agents/**/*.md`.
3. `scripts/schema.sql` syntax check via `sqlite3 :memory:` dry-run.
4. `.claude/settings.json` JSON.parse validation.
5. Tracked-secret detector (`BEGIN PRIVATE KEY`, `ghp_*`, `github_pat_*`,
   `sk-*`, `xox[abrs]-*`) — CSO Layer 2 mirror; per-company instances are
   expected to add tighter scanners (gitleaks / trufflehog) post-init.

### Added — `docs/branch-protection-spec.md`

Normative spec for branch protection on `main`. Six rules (PR required, ≥1
reviewer, status checks required, linear history, no force-push, no
deletion, include admins where plan supports). Documents the
Free-org-plan caveat: rules ship in `disabled` state per CSO Layer 4
convention — audit returns `WARN` not `FAIL` when plan limits enforcement.

### Added — `docs/MCP_INVENTORY.md`

Normative manifest of every MCP server the template references. Eight rows
covering `turso`, `ms-graph`, `m365-graph` (FEAT-014), `github:read/write`,
`bank` (FEAT-011), `fattura_elettronica` (FEAT-012), `buffer`. Includes the
abstract-role-vs-concrete-server pattern (`bank`, `fattura_elettronica`,
`buffer` are abstract qualifiers bound to provider-specific MCPs at company
init), the Universal Boundaries from `SYSTEM_INVARIANTS.md` §4, and the
process for adding new MCP servers (CA + CSO joint review).

### Added — `plugins/README.md` proper Channel-plugin pattern doc

Replaces the previous minimal placeholder. Documents the convention for
new Channel plugins (TypeScript, polling cadence, sender-confidence,
dead-letter, auth env vars, registration, **stdout discipline** —
explicit reference to the 2026-05-03 ftaricano audit C6 finding for what
happens when stdout is contaminated). Distinguishes Channel plugins (this
directory) from MCP servers (separate repos under `juvantlabs/*-mcp-server`).

### Added — JUVANT_OS.md wizard steps 1.6, 7.5, 8.5, 10.5

- **Step 1.6 — GitHub user mapping**: collects `github_user_map`. Default
  mapping = all roles → CEO. Per-role overrides for multi-human teams.
- **Step 7.5 — Render infrastructure files**: substitutes `{{*_GITHUB}}` in
  `.github/CODEOWNERS`. Other infra files ship as-is.
- **Step 8.5 — MCP inventory cross-check**: validates each
  `agent_tool_matrix` v0 row against `docs/MCP_INVENTORY.md`. Build-fails
  on Universal Boundary violations or unlisted servers.
- **Step 10.5 — Branch-protection spec**: authors a `branch-protection-spec`
  decision queued for COO execution. Free-plan-aware (records `disabled`
  state where enforcement is plan-limited).

### Updated — `.gitignore` extensions

Six new pattern groups (six-from-FEAT-013 anti-pattern checklist):

- Key material — `*.pem`, `*.key`, `id_rsa*`, `*.p12`, `*.pfx`
- Yarn / pnpm logs (consistent with existing Node patterns)
- Local SQLite artifacts — `*.sqlite`, `*.sqlite-shm`, `*.sqlite-wal`,
  `*.db-shm`, `*.db-wal` (relevant for `provider=local` doc_storage and
  dev databases)
- Turso CLI cache — `.turso/`
- Editor noise — `.idea/`, `.vscode/local-settings/`, `*.swp`, `*~`
- Test artifacts — `coverage/`, `.nyc_output/` (relevant once FEAT-008
  lands at Phase 9)

### Notes

- Closes `juvantlabs/juvant-os-pm#27` (FEAT-013).
- Six CSO baseline-audit Tier-2 follow-ups (CODEOWNERS, CI, branch
  protection, MCP inventory, plugin reference, `.gitignore` extensions)
  resolved at template level — fresh instances bootstrapping after this
  release should hit zero Tier-2 follow-ups (target — re-validation on
  next dogfood).
- The scheduled cleanup agent on `juvantio/juvant` (firing 2026-05-16)
  will still run for the existing instance (which was bootstrapped at
  v0.4.0). After upstream-sync of v0.5.0 lands in the instance, the
  cleanup PR may be redundant — confirmed at fire time.
- No SYSTEM_INVARIANTS.md changes (avoided system-wide manifesto
  re-validation per Appendix B). All policy lives in `JUVANT_OS.md` and
  the new `docs/*.md` files.

---

## [0.4.2] — 2026-05-03 — Document storage folder mapping + null-binding policy

---

## [0.4.2] — 2026-05-03 — Document storage folder mapping + null-binding policy

Second post-Alpha patch. Closes the five spec/template gaps surfaced during the
2026-05-03 dogfood OneDrive folder-mapping discussion (`juvantio/juvant`
instance) — all wizard / template gaps, no functional regression.

### Added — `JUVANT_OS.md` Step 1.5: Document storage folder mapping

New wizard step inserted between Step 1 (Identity) and Step 2 (Database setup).
Captures the agent-actionable doc-storage state that Step 1's abstract provider
choice (OneDrive / Google Drive) does not:

- **Discover-via-tool path** (preferred when M365 / Google Drive connector is
  loaded in the Claude Code session): wizard calls connector list / search
  tools, walks the discovered structure with the CEO, captures resource IDs
  (`drive_id`, `site_id`, `tenant_id`) for direct API resolution. Anti-pattern:
  the wizard MUST NOT ask the CEO to type folder paths when a connector is
  loaded (Bug #7b — first surfaced in the dogfood; CEO directly questioned
  "where are you looking?" when the wizard tried to type-it-blind).
- **Type-it path** (fallback when no connector available).
- **Three folder-organization models** documented as supported: function-centric,
  product-centric, hybrid. The schema is identical across all three; what varies
  is which `folders.<role>` keys are bound vs. set to `null` with a fallback
  chain.

New `.juvant/config.json` shape:

```json
{
  "doc_storage": {
    "provider": "onedrive",
    "mcp_server": "ms-graph",
    "resource_ids": { "tenant_id": "...", "site_id": "...", "drive_id": "b!..." },
    "folders": { "root": "/Co", "legal": "/Co/Legal", "research": null, ... },
    "fallback_chain": { "press": ["gtm", "root"], "research": [], ... }
  }
}
```

### Added — folder resolution algorithm + null-binding semantics

Documented in `JUVANT_OS.md` Step 1.5 and referenced from each affected agent
template's identity reference box. `resolve_folder(role)` consults
`folders.<role>` first; on `null` walks `fallback_chain.<role>` in order; on
exhaustion returns `None` and the agent surfaces `[<ROLE> SOURCE UNBOUND]` in
its response, offering the CEO three choices: bind now, confirm intentional
(logged as `decisions` cat `binding-confirmation`, `intentional_null=true`),
or use a one-time path.

### Added — write capability check

Distinct from folder resolution: write capability requires a write-capable MCP
bound (today: `juvantlabs/m365-graph-mcp-server`, FEAT-014, shipping in beta).
Until FEAT-014 ships, write paths are limited to (a) explicit local path
provided by the CEO turn-by-turn, or (b) waiting. Agents surface
`[<ROLE> WRITE UNAVAILABLE]` when capability is missing.

### Added — Project setup Step 1 auto-discovery

When the M365 / Google Drive connector is loaded and `doc_storage.folders.products`
is bound at company-level, the project-init wizard scans for existing subfolders
not yet mapped to a Juvant OS project and proposes them as project candidates.
Avoids forcing the CEO to type project folder paths when the structure already
exists. Per-project `doc_folder` recorded under `projects.<slug>.doc_folder` in
`.juvant/config.json`.

### Updated — agent templates

The six agent templates that read or write documents (`agents/company/cro.md`,
`cmo.md`, `cco.md`, `cfo.md`, `clo.md` and `agents/projects/cdo.md`) now
reference the `JUVANT_OS.md` Step 1.5 policy in their identity box and
document role-specific surface flags (`[CRO SOURCE UNBOUND]`, `[CMO WRITE
UNAVAILABLE]`, `[CFO BANK SOURCE UNAVAILABLE]`, etc.). The CFO template also
documents the bank-source-unbinding case for the FEAT-011 deferred-shipping
period.

### Fixed — bugs from the 2026-05-03 dogfood

- **Bug #7** — Wizard at company-init never asked for OneDrive folder mapping
  even after capturing the abstract provider, leaving every doc-handling agent
  to surface "source unbound" on first call. Resolved by Step 1.5.
- **Bug #8** — Templates assumed function-centric folder organization
  (dedicated `Research`, `Press`, `Sales` at company root). Real companies are
  often product-centric or hybrid. Resolved by `null` + fallback-chain schema
  flexibility.
- **Bug #10** — Wizard captured paths but not provider-specific resource IDs
  (`drive_id`, `site_id`, `tenant_id`), forcing every MCP call to do a path-
  resolution roundtrip. Resolved by `resource_ids` block populated during
  discover-via-tool.
- **Bug #11** — Project-init wizard asked for typed folder paths instead of
  exploring `doc_storage.folders.products` for existing candidates. Resolved
  by Project setup Step 1 auto-discovery.
- **Bug #12** — Agent templates' fail-mode for null / missing bindings was
  unspecified, risking silent failures or hard errors. Resolved by the
  `[<ROLE> SOURCE UNBOUND]` / `[<ROLE> WRITE UNAVAILABLE]` surfacing pattern
  + `decisions` cat `binding-confirmation` audit trail.

### Notes

- All five bugs fixed at the OSS-template level (`juvantlabs/juvant-os`).
  Per-company instances at `v0.4.0` / `v0.4.1` (e.g. `juvantio/juvant`)
  receive the fixes via the next CHRO upstream-sync proposal (CHRO drift
  detection → CA `pr-spec` → COO PR).
- No SYSTEM_INVARIANTS.md changes (would have triggered system-wide
  manifesto re-validation per Appendix B). The doc-storage policy is
  expressed in `JUVANT_OS.md` and referenced from individual templates;
  promotion to SYSTEM_INVARIANTS.md §8 is deferred until / if multiple
  Juvant OS adopters need provider-agnostic policy enforcement.

---

## [0.4.1] — 2026-05-02 — Dogfood patch

---

## [0.4.1] — 2026-05-02 — Dogfood patch

First post-Alpha patch. All bugs surfaced during the **first real dogfood run**
of `Initialize Juvant OS for Juvant Srls` on 2026-05-02 (17 minutes 50 seconds,
end-to-end Bootstrap Protocol §1 completed successfully).

### Fixed — pre-dogfood corrections (Teams setup)

- **Teams channel naming**: Teams uses bare channel names (no `#` prefix; that is
  Slack convention). All references to `#approvals`,
  `#{{ACTIVE_PROJECT}}-alerts`, `#{{COMPANY_NAME_SLUG}}-ops`, `#system` updated
  to `Approvals`, `{{ACTIVE_PROJECT}}-alerts`, `{{COMPANY_NAME_SLUG}}-ops`,
  `System`. Affects `JUVANT_OS.md` (Step 4 Notifications + CoS Communication Map)
  and `agents/company/cos.md` (Message Priority Rules + Channel use).
- **Wizard Step 4 schema**: company-setup wizard now collects **four** Teams
  Adaptive Cards webhook URLs (one per canonical channel) instead of a single
  webhook. New `.juvant/config.json` schema:
  `teams_webhooks: { approvals, ops, system, alerts }`. The wizard description
  table spells out each channel's purpose; alerts is optional at company-init.
- **`{{COMPANY_NAME}}-ops` → `{{COMPANY_NAME_SLUG}}-ops`** in `cos.md` Channel
  use — `COMPANY_NAME` may contain spaces (e.g. "Acme Corp"); only `_SLUG` form
  is a valid Teams channel name.
- **Telegram `chat_id` collection**: Step 4 now also collects the CEO's numeric
  Telegram `chat_id` (the bot needs it to send Critical alerts; the bot token
  alone is insufficient).
- **`hooks/notification.sh`**: rewritten to read `teams_webhooks.<channel-key>`
  using `jq --arg`. Channel selection is driven by the `JUVANT_NOTIFY_CHANNEL`
  env var (default `approvals`). Empty / unset URLs gracefully skip Teams and
  fall through to Telegram.

### Fixed — dogfood (Step 2 — Database setup)

- **`scripts/schema.sql` PRAGMA WAL rejected by Turso.** Removed the
  `PRAGMA journal_mode=WAL;` statement; Turso (LibSQL) uses WAL by default and
  rejects the PRAGMA when applied via `turso db shell`. Added a comment
  documenting that the local SQLite path (provider=local) sets WAL via the
  wizard at runtime instead of via the schema.
- **`scripts/migrate.sh` flat keys vs. spec schema.** Migration script now
  reads `db.url` and `db.auth_token` from `.juvant/config.json` (matching
  the JUVANT_OS.md Step 2 nested schema), instead of the legacy flat
  `turso_url` / `turso_token` keys.

### Fixed — dogfood (Step 6 — Agent names)

- **`JUVANT_OS.md` Agent naming table incorrectly listed COO under company-scope.**
  Per `SYSTEM_INVARIANTS.md` §2, COO is project-scope (default
  `<project_id>-coo`); the file lives in `agents/projects/coo.md`. The
  Agent naming reference table is split into a Company-scope table (10 agents)
  and a Project-scope table (5 leadership + 4 Eng/*) to match the canonical §2
  definition. Each project gets its own COO; there is no company-wide COO.

### Fixed — dogfood (Step 7 — Compile templates)

- **`agents/company/cso.md` self-reference.** Layer 5 audit check #9 contained
  the literal token `{{PLACEHOLDER}}` inside backticks while describing its
  own substitution-failure rule, which would fail its own audit on first run.
  Reworded to prose: "any surviving `{{NAME}}`-style placeholder is a
  substitution failure (`FAIL`)" with explicit reference to the §2 allowlist.
- **Project-scope name placeholders inside company-scope templates.** Eight
  company-scope files (`cos.md`, `cco.md`, `cmo.md`, `clo.md`, `chro.md`,
  `cso.md`, `ca.md`) referenced `{{CTO_NAME}}` / `{{CPO_NAME}}` /
  `{{CDO_NAME}}` / `{{COO_NAME}}` / `{{VPE_NAME}}` in role-routing tables and
  cross-references. At company-init no project exists yet, so these tokens
  could not be substituted with real names. Replaced all occurrences with
  generic phrasing (`the project's CTO`, `the project's COO`, etc.) since
  company-scope agents address project-scope agents abstractly across all
  active projects, not as a single named person.
- **Substitution-failure rule conflicted with `{{ACTIVE_PROJECT}}`
  runtime-bound exception.** `SYSTEM_INVARIANTS.md` §2 stated both that any
  surviving `{{...}}` triggers a CSO Layer 5 finding AND that
  `{{ACTIVE_PROJECT}}` binds at SessionStart and survives compilation —
  contradiction. Resolution: §2 now defines an explicit **runtime-bound
  allowlist** (today: `{{ACTIVE_PROJECT}}` only); CSO Layer 5 audits skip
  allowlisted placeholders. All four "refuse to write any surviving
  `{{...}}`" assertions in `JUVANT_OS.md` (Wizard Step 7, project-init Step 4,
  Agent naming section, Appendix A) updated to reference the §2 allowlist.

### Build process — dogfood validation

- First end-to-end `Initialize Juvant OS` on `juvantio/juvant` succeeded:
  - 10/10 founding company-scope manifestos `operational` after Bootstrap
    Protocol §1 with `tier1_bootstrap=1` + `precondition_bypassed='bootstrap'`.
  - CSO `bootstrap_baseline=1` audit returned `WARN-WITH-CONDITIONS`
    (treated as PASS per §1.8); promoted manifestos to `operational`.
  - `master_context.bootstrap_completed_at` set at `2026-05-02T21:26:01Z`.
  - 6 Tier-2 follow-ups authored as `decisions` rows (CODEOWNERS, CI,
    branch protection, MCP inventory, plugin reference, `.gitignore`
    extensions); these are tracked as **FEAT-013 OSS template shipping
    defaults** to address the underlying gaps in the OSS template, so future
    fresh instances start cleaner.

---

## [0.4.0] — 2026-05-02 — JUVANT_OS.md Skill orchestrator

Phase 4 of Juvant OS. Closes the Alpha milestone. The Skill orchestrator is the only entry
point for all Juvant OS operations — natural language replaces the CLI that never existed.

### Added

- **`JUVANT_OS.md`** — Skill orchestrator at the repo root (1,249 lines). Read at every
  Claude Code SessionStart; defers to `SYSTEM_INVARIANTS.md` (§1–§7) for cross-cutting
  invariants. Contains:
  - **§ When to use this skill** — intent → procedure mapping table for every CEO trigger
    phrase.
  - **§ How this skill works** — Turso = canonical memory; context window = temporary;
    `.juvant/config.json` = local-only secrets (gitignored).
  - **§ Company setup** — 10-step wizard: identity → database (CLI or Manual; Local /
    Turso / Azure / AWS / GCP) → bank provider binding (`bank` abstract → Finom / Mercury /
    Revolut / Wise) → notifications (Telegram + Teams + Morning Brief) → counterparties →
    name resolution (§2 defaults) → template compilation (whole-token substitution; refuse
    surviving `{{...}}`) → `agent_tool_matrix` v0 seed → **Bootstrap Protocol §1**
    (CEO-only one-shot override, `tier1_bootstrap=1`, `precondition_bypassed='bootstrap'`,
    structural-completeness check, CSO `bootstrap_baseline=1` audit, `master_context.
    bootstrap_completed_at`) → initial commit.
  - **§ Project setup** — 6-step wizard with project-bootstrap analog
    (`precondition_bypassed='project-bootstrap'`); CTO Tier-1 sole approver after CHRO + CA
    bootstrap the project CTO.
  - **§ Starting agents** — boot sequence with bootstrap-state check, 3-level session
    continuity, parallel pending-state reads, disclosure-fallback gate, always-on first
    triad (CoS / CFO / CLO), Boot Mode resolution (Single / All).
  - **§ Status check** — unified dashboard reads + format with `[MANIFESTO PENDING]` and
    `[DISCLOSURE FALLBACK ACTIVE]` flags.
  - **§ Manifesto review flow** — Tier 1 (blocking; company = CHRO + CA, project = CTO
    sole) and Tier 2 (async, 7-day); CSO precondition (passing 5-layer audit ≤30 days,
    bypassed only during bootstrap); restricted-mode behaviour by role.
  - **§ Agent naming** — §2 defaults, project-prefix pattern, whole-token substitution.
  - **§ Memory commit protocol** — SQL templates per exchange type (`counterparty_history`,
    `messages`, `inbound_queue`, `decisions`); enumerated `category` values matching the
    schema.
  - **§ Context resume** — 3-level redundancy: Agent SDK `session_id` → `session_snapshots`
    → structured Turso memory.
  - **§ CoS proxy model** — default proxy with disclosure validation, direct-1:1 exception
    flow, Eng/* delegated through VPE, Teams channel routing (#approvals,
    #{{ACTIVE_PROJECT}}-alerts, #{{COMPANY_NAME_SLUG}}-ops, #system).
  - **§ Spec-driven single-writer model (§4 + §6)** — all 9 spec classes (`pr-spec`,
    `gh-issue-spec`, `gh-project-update-spec`, `gh-milestone-spec`, `install-spec`,
    `branch-protection-spec`, `release-spec`, `deployment-spec`, `secret-rotation-spec`)
    plus `gh-pr-review-spec`; COO 5-check verification (author authorization, approval
    state, format completeness, Universal CONFIDENTIAL invariant, linked artifact
    integrity); no partial execution; Universal Boundaries (no `bank:write`, no
    `m365-mail` send except portals, no `github:write` to non-COO, no `state.db` read +
    external-channel send in same row, no unrestricted `Bash` to portal/demo agents).
  - **§ Disclosure fallback cascade (§3)** — detection (Turso unreachable OR
    zero active rows); Tier 1 universal `inbound_queue` + `security_audit_log` writes;
    Tier 2 CoS T+5min Telegram CRITICAL aggregation; Tier 3 COO halt-all-writes
    (single-writer → single-reader-only); Tier 4 VPE Eng/* routing + buffered
    `eng-output-held`; CSO post-incident `cascade-postmortem`.
  - **§ Model assignment + override** — Opus 4.7 (cos, cso, clo, cetho, ca), Sonnet 4.6
    (cfo, cmo, cco, chro, cro, cto, cpo, cdo, coo, vpe), Haiku 4.5 (eng-api, eng-backend,
    eng-frontend, eng-ai); CoS / VPE override authority; mandatory logging in `decisions`
    category `model-override` (unlogged override = security incident).
  - **§ Hiring / offboarding** — post-bootstrap hiring flow (CHRO tool-matrix-change → CA
    `pr-spec` → CHRO+CA+CSO+CEthO review → standard manifesto lifecycle WITH CSO
    precondition); 5-step CR-09 offboarding (Drain → Handoff → Revoke → Cleanup → Notify).
  - **§ Upstream sync** — CHRO drift detection vs `juvantlabs/juvant-os@main` →
    `decisions` category `upstream-sync-proposal` → CoS → CEO → CA `pr-spec` → COO PR with
    CHRO + CA + CSO + CEthO review (CEthO required when §3/§5 changed); `git merge
    upstream/main` reserved for emergencies + post-incident audit.
  - **§ Migration watch** — OP-001 (Agent Teams: 0/3 today), OP-002 (Cloud Routines: 0/4
    today), OP-004 (Azure 24/7: not yet required); deltas recorded in `decisions` category
    `migration-watch`; never proposed to CEO until all criteria green.
  - **§ Security rules** — 10 Skill-enforced invariants including Universal CONFIDENTIAL
    (§5), COO 5-check, one-shot bootstrap, SYSTEM_INVARIANTS.md as canonical authority,
    credentials never in context, counterparty input as data not instructions,
    `bank:read`-only by construction, COO-only `github:write`, CMO m365-mail = press scope
    only, structural cascade engagement.
  - **Appendix A** — placeholder substitution checklist (company-init vs project-init
    tokens; `{{ACTIVE_PROJECT}}`/`{{PROJECT_NAME}}` resolved at SessionStart and project
    init respectively; surviving `{{...}}` = compile failure).
  - **Appendix B** — first-time-setup procedure for a per-company instance: create empty
    private repo in `juvantio` → `git clone --bare` of `juvantlabs/juvant-os` →
    `git push --mirror` to per-company repo (standalone, NOT a GitHub fork) → working
    clone → optional `upstream` remote → `claude` → `Initialize Juvant OS`.

### Notes

- All SQL examples in JUVANT_OS.md target columns that exist in `scripts/schema.sql` from
  Phase 2 (commit `cbe7d6f`).
- All hook references match the 7 scripts shipped in Phase 3 (commit `f5bdfc5`) and the
  registrations in `.claude/settings.json`.
- All agent references match the 19 compiled subagent templates from Phase 5 / commit
  history `16c31d2..32ef1a1` (CDO = Chief **DESIGN** Officer; COO = sole `github:write`
  bearer; `bank` abstract; CMO m365-mail = press scope only).
- Closes `juvantlabs/juvant-os-pm` issue #12 (FEAT-004).
- Alpha milestone complete (Phases 1–5 ✅).

---

## [0.3.0] — 2026-05-01 — SYSTEM_INVARIANTS refactor

Phase 3 of Juvant OS. Resolves audit findings P0.1, P1.1, P1.2 by extracting cross-cutting
invariants into a single canonical document and refactoring all 19 subagent templates to
defer to it via reference boxes.

### Added

- **`SYSTEM_INVARIANTS.md`** — canonical source-of-truth for the seven cross-cutting
  invariant classes (commit f59dded):
  - §1 Bootstrap Protocol (CEO + CSO ownership) — CEO-only override path for the founding 19
    manifestos at company init. Flags: `tier1_bootstrap=1`, `precondition_bypassed='bootstrap'`,
    `master_context.bootstrap_completed_at`. One-shot, no re-entry. CSO performs
    `bootstrap_baseline=1` audit immediately after all 19 reach OPERATIONAL_RESTRICTED.
  - §2 Default Naming Convention (CHRO ownership) — populated `{{*_NAME}}` placeholders with
    defaults: Atlas (CoS), Theos (CFO), Lex (CLO), Mira (CMO), Clio (CCO), Sage (CHRO),
    Shield (CSO), Vera (CEthO), Arch (CA), Lumen (CRO), Coo (COO).
  - §3 Unified Disclosure Fallback Cascade (CSO ownership) — 4 tiers: Universal (every agent)
    → CoS-side aggregation (T+5min Telegram CEO Critical) → COO halt-all-writes →
    VPE-routing extension for Eng/*. Per-agent extensions documented inline.
  - §4 Single-Writer Invariant (COO canonical executor) — COO is the sole GitHub writer
    system-wide; cross-ref to `coo.md`.
  - §5 Universal CONFIDENTIAL List — 10 items, amendable only by CEO + CSO + CLO + CEthO
    joint approval.
  - §6 Spec Authorization Matrix (COO canonical source) — the matrix in `coo.md` is the
    source-of-truth; SYSTEM_INVARIANTS.md cross-refs to it.
  - §7 Architectural Principles (CA ownership) — 11 principles; cross-ref to `ca.md`.

- **Project-bootstrap analog** in `cto.md` — when a new project is added to an existing
  company post-bootstrap, `precondition_bypassed='project-bootstrap'` is permitted for the
  initial Tier 1 wave of the new project's agents. Sequencing: CHRO + CA approve the new
  project CTO's manifesto first; once OPERATIONAL_RESTRICTED, CTO performs Tier 1 on the
  remaining project-scope agents; CSO performs `bootstrap_baseline=1` audit immediately after.

- **Tier-3 cascade specification** in `coo.md` — full halt-all-writes spec: all `*-spec` rows
  freeze with `status='deferred-fallback'`; single-writer → single-reader-only invariant;
  emergency carve-out requires CEO direct authorization with
  `disclosure_fallback_emergency_override=1`; CSO notified for post-incident audit; resume
  protocol with re-validation of any disclosure-tagged specs.

- **Tier-4 cascade specification** in `vpe.md` — full Eng/*-routing spec: VPE-side hold buffer
  for Eng/* outputs (`decisions` category `eng-output-held`, `held_for_fallback=1`); internal
  engineering work continues; external-facing artifacts paused; resume replay verification.

- **Dual-surface invariant codification** in `cpo.md` — explicit Backlog Protocol stating
  Turso is canonical (CPO writes), GitHub Projects is the operational projection (COO writes
  per CPO-authored specs); canonical wins on drift.

- **Design-system canonical assertion** in `cdo.md` — explicit reference box stating the
  design system is canonical in `knowledge_base WHERE tags LIKE '%design-system%'` (Turso);
  repo implementation is verified against canonical, not the other way around.

### Changed

- **All 19 subagent templates** refactored to defer to `SYSTEM_INVARIANTS.md`:
  - Reference box added at the top of each template citing relevant sections.
  - Disclosure Fallback rules collapsed to "Apply Universal Cascade SYSTEM_INVARIANTS.md §3"
    plus per-agent extensions where applicable.
  - Universal CONFIDENTIAL references replaced with §5 cross-refs.
  - Single-Writer Invariant references replaced with §4 cross-refs.
  - Peer-agent name references substituted with `{{*_NAME}}` placeholders per §2.

  Per-template commits on `juvantlabs/juvant-os` `main`:

  | Template | Commit | Notes |
  |---|---|---|
  | `cos.md` | 16c31d2 | Tier-2 cascade aggregation owner; bootstrap awareness |
  | `cfo.md` | 1953ca2 | Bank MCP unavailable handling |
  | `clo.md` | 4859af8 | CLO is policy lifecycle owner; structural alarm |
  | `cmo.md` | ab96e50 | CRO "if enabled" fallback |
  | `cco.md` | 9615f1a | CRO "if enabled" fallback |
  | `chro.md` | 7ef18e8 | Manifests row schema clarified (P1.9); bootstrap exception |
  | `cso.md` | 7ca9c45 | Layer 5 expanded (SYSTEM_INVARIANTS check); bootstrap baseline |
  | `cetho.md` + `ca.md` + `cro.md` | 25a2271 | CEthO co-custodian §5; CA canonical §4+§7; CRO OPTIONAL |
  | `coo.md` | 06ae526 | Canonical executor §4 + canonical source §6; full Tier-3 spec |
  | `cto.md` | 4d9f23e | Project bootstrap analog; project-scope Tier 1 sole approver |
  | `cpo.md` | 5d5cab9 | Dual-surface invariant codified |
  | `cdo.md` | dcee304 | Design-system canonical assertion; CDO is NOT data role |
  | `vpe.md` | 2962f63 | Full Tier-4 cascade Eng/* routing spec |
  | `eng-api.md` | 6e5e009 | Subordinate to VPE Tier-4; held_for_fallback buffer |
  | `eng-backend.md` | 41a89e3 | Data-deletion gate preserved through fallback |
  | `eng-frontend.md` | c0a0171 | Design-system consumer; accessibility floor |
  | `eng-ai.md` | 32ef1a1 | User-facing AI work HALTS during fallback; CEthO notified |

### Fixed

- **P0.1 (CRITICAL) — bootstrap chicken-and-egg.** Tier 1 manifesto approval required
  CHRO/CA/CTO evaluators and a CSO precondition (passing audit ≤30 days). At company init,
  none of the 19 founding agents had a manifesto yet, so the gate could not open. Resolution:
  §1 Bootstrap Protocol with CEO-only override (one-shot), `bootstrap_baseline` CSO audit
  immediately after. Project-bootstrap analog handles the same problem for new projects added
  to an existing company.

- **P1.1 — Disclosure Fallback inconsistency.** Templates carried inconsistent fallback
  behavior, ranging from "halt all work" to "treat as CONFIDENTIAL but continue." Resolution:
  §3 Unified 4-Tier Cascade with explicit per-agent extensions (CHRO structural alarm, CTO
  project-scope manifesto pause, CDO external-facing pause, CSO post-incident audit, CEthO
  joint acknowledgment on resume, eng-ai user-facing AI halt).

- **P1.2 — Placeholder naming inconsistency.** Templates referenced peer agents by literal
  default names in some places and by `{{PLACEHOLDER}}` form in others, with no canonical
  list. Resolution: §2 Default Naming Convention with all `{{*_NAME}}` placeholders enumerated
  and populated defaults (Atlas, Theos, Lex, Mira, Clio, Sage, Shield, Vera, Arch, Lumen, Coo);
  templates substituted accordingly.

### Documentation

- **`docs/session-commit-p1.md`** in `juvantlabs/juvant-os-pm` updated with a dedicated
  SYSTEM_INVARIANTS.md section (commit `juvantlabs/juvant-os-pm@6b40804`):
  - Section table of the 7 invariant classes with owners and notes.
  - Bootstrap Protocol full explanation with project-bootstrap analog.
  - Disclosure Fallback Cascade 4-tier table with per-agent specifics.
  - Architecture, Initialize-the-system, Upstream sync, Org structure, Matrix, Universal
    Boundaries, and Spec authorization sections updated with §-cross-refs.
  - "Refactor history" section appended listing all 20 commits (1 SYSTEM_INVARIANTS.md +
    19 templates).

---

## [0.2.0] — 2026-04-23 — Initial 19-template build

Phase 2 of Juvant OS. All 33 CRs from Chat 19+20 design phase resolved. 19 subagent templates
built. Org separation `juvantlabs` (OSS) ↔ `juvantio` (product). Single-writer model
(COO sole `github:write` bearer) and CDO=Design (not Data) established. Bank MCP abstracted
to per-company binding. Repository model: per-company instances are mirror-pushed standalone
repos, not formal GitHub forks.

(Pre-CHANGELOG history; see `juvantlabs/juvant-os-pm/docs/session-commit-p1.md` and
`session-commit-p2.md` for the full design rationale and chat-by-chat trace.)

---

## [0.1.0] — pre-2026-04-23 — Architecture phase

Skill-first orchestration model selected (no CLI). Two-org structure decided. Model
Assignment Policy locked (Opus 4.7 / Sonnet 4.6 / Haiku 4.5). State Architecture established
(Turso shared persistent memory; context window temporary; OneDrive/GDrive for sensitive
documents). Agent Tool Matrix v0 default seed authored.

(Pre-CHANGELOG history; design rationale in `juvantlabs/juvant-os-pm/docs/`.)

[Unreleased]: https://github.com/juvantlabs/juvant-os/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/juvantlabs/juvant-os/releases/tag/v0.5.0
[0.4.2]: https://github.com/juvantlabs/juvant-os/releases/tag/v0.4.2
[0.4.1]: https://github.com/juvantlabs/juvant-os/releases/tag/v0.4.1
[0.4.0]: https://github.com/juvantlabs/juvant-os/releases/tag/v0.4.0
[0.3.0]: https://github.com/juvantlabs/juvant-os/releases/tag/v0.3.0
[0.2.0]: https://github.com/juvantlabs/juvant-os/releases/tag/v0.2.0
[0.1.0]: https://github.com/juvantlabs/juvant-os/releases/tag/v0.1.0
