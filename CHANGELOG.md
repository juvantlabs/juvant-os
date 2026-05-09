# Changelog

All notable changes to Juvant OS will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

All written artifacts in English. No exceptions.

---

## [Unreleased]

### Fixed — Local SQLite hooks silently fail when wizard writes `db.url=file:...` (HIGH; F-20)

Surfaced by the Foxtrot Corp testco run on 2026-05-09. The wizard
sometimes writes `db.url = "file:.juvant/state.db"` (libsql URI form)
into `.juvant/config.json` for local provider — this is libsql-syntax
valid but our `hooks/lib/db.sh` and `scripts/migrate.sh` (v0.6.3)
passed the value verbatim to `sqlite3`, which interpreted it as a
literal path `<repo>/file:.juvant/state.db`. Result: silent
INSERT/UPDATE failures swallowed by `2>/dev/null`. Track 3 (audit log)
non-functional whenever the wizard chose the `file:` prefix variant.

Echo Corp run wrote `.juvant/state.sqlite` (no prefix) and worked;
Foxtrot wrote `file:.juvant/state.db` (with prefix) and silently
failed. Skill-side variation surfaced again — non-deterministic
config generation for the same `provider=local` choice.

Fix: `hooks/lib/db.sh` and `scripts/migrate.sh` strip the `file:`
prefix when resolving the local-provider filesystem path. Verified
post-hoc against the Foxtrot `state.db`: an `agent_actions_log`
INSERT that previously failed silently now writes the row.

### Fixed — Step 3 [5] Other branch must collect provider name + MCP URL (F-19 + F-18)

Surfaced by the Foxtrot Corp testco run on 2026-05-09: the CEO chose
`[5] Other` at Step 3 (Bank provider binding), and the Skill recorded
`bank.provider = null, bank.mcp_server = null` and advanced — without
prompting for the provider slug or MCP server URL. The doc said
*"Other (specify name + MCP server URL)"* but the Skill collapsed
the branch into a "skip" path.

Fix in `JUVANT_OS.md` Step 3:

- Menu now exposes both `[5] Other` AND `[6] Skip` as distinct paths.
- `[5] Other` HARD-REQUIRES two sub-prompts: provider slug, then MCP
  server URL/package. The Skill MUST NOT collapse these to null.
- `[6] Skip` is the explicit defer path; sets `bank.provider = null`,
  `bank.mcp_server = null` cleanly.
- Validation rule: any selection that ends with both fields null AND
  was NOT explicitly `[6] Skip` must re-prompt with the same options.

This closes F-18 (no input validation / no re-prompt on invalid bank
input) by folding it into the same Step 3 amendment.

### Added — Per-company file rewrites at bootstrap (F-16)

The OSS template at `juvantlabs/juvant-os` ships with framework-facing
`README.md` / `CHANGELOG.md` / `SECURITY.md` / `docs/adr/*.md` —
appropriate **upstream**, but wrong inside a per-company instance.
Pre-v0.6.5, every adopter who looked at their own private repo saw
"Juvant OS — The OSS multi-agent operating system" instead of their
own brand. Same for `docs/adr/`: framework-architecture decisions
(Skill-first, ADR 0010 symlinks, etc.) leaked into the per-company
namespace, blocking adopters from numbering their own ADRs from 0001.

Fix: new wizard Step 7.6 invokes `scripts/compile-templates.sh
--rewrite-meta`, which:

- Renders `README.md` from `scripts/templates/README.md.template` —
  company-specific landing page with name, domain, CEO, bootstrap
  date, audit verdict, "Powered by Juvant OS" footer, and an
  AUTO-GENERATED `Active projects` section (maintained by future
  Skill operations on project-init / maturity transition).
- Renders `CHANGELOG.md` from `scripts/templates/CHANGELOG.md.template`
  — empty `[Unreleased]` + `[0.0.1] — <bootstrap-date> — Bootstrap`
  initial entry. Tracks **company-specific** changes only; framework
  CHANGELOG stays at upstream.
- Renders `SECURITY.md` from `scripts/templates/SECURITY.md.template`
  — `security@<domain>` disclosure policy + 48h SLA + scope
  declaration. Framework-level SECURITY policy at upstream.
- Renders `docs/adr/README.md` from
  `scripts/templates/docs-adr-README.md.template` — company-scope
  ADR stub (numbering, Nygard form, authorship flow, examples).
- **Removes** all framework ADRs (`docs/adr/0001-*.md` through
  `docs/adr/NNNN-*.md`) from the per-company repo. Adopters read
  framework ADRs at upstream when they need to.

Bootstrap metadata (`bootstrap_completed_at`, `bootstrap_audit_verdict`)
is read from `state.db` `master_context`. Framework version is read
from a new repo-root `VERSION` file (`0.6.5`).

`JUVANT_OS.md` Step 10 git-add list extended with `README.md`,
`CHANGELOG.md`, `SECURITY.md`, `docs/adr/`, `VERSION`; uses `git add -A`
so the framework ADRs removed at Step 7.6 are picked up as deletions.

Validated post-hoc against the Foxtrot Corp testco state: all four
files rewrote with company-specific content; 10 framework ADRs
removed cleanly.

`LICENSE` is **not** rewritten by this step — adopters keep the
upstream MIT license unless they manually replace it post-bootstrap.
A future v0.6.6+ extension may add a wizard prompt for license choice.

### Added — `scripts/compile-templates.sh` shipped (F-6)

Pre-v0.6.4 every wizard pass at Step 7 (template substitution)
improvised an ad-hoc Python helper at a different path:

- Acme: `.juvant/_compile.py`
- Beta: `/tmp/compile_templates.py`
- Gamma: `/tmp/testco-bootstrap-manifestos.py`
- Delta: `.juvant/seed-manifests.py`
- Echo: `/tmp/compile_agents.py`

Five different paths across five testco runs. Different sessions
interpret the substitution rules subtly differently; inconsistent
behavior across adopters. Plus: each anonymous heredoc tripped
Claude Code's "shell syntax cannot be statically analyzed" warning,
contributing to the prompt-flood during the CSO subagent audit.

v0.6.4 ships `scripts/compile-templates.sh` — canonical Bash script
codifying the substitution rules:

- Reads identity, agent names, GitHub handles, and tunables from
  `.juvant/config.json` (with SYSTEM_INVARIANTS.md §2 defaults
  for tunables when not overridden).
- Walks `agents/<scope>/*.md` (default: company; `--scope projects`
  at project init).
- Substitutes whole-token placeholders only.
- Refuses to write (exit code 2) if any non-allowlisted placeholder
  survives. Allowlist: `ACTIVE_PROJECT`, `PROJECT_NAME` (runtime-
  bound at SessionStart / project init).
- `--codeowners` flag substitutes `{{*_GITHUB}}` in
  `.github/CODEOWNERS` (Step 7.5 deliverable).
- `--check-only` flag for dry-run validation.

`JUVANT_OS.md` Step 7 + Step 7.5 rewritten to invoke the script:
*"The Skill MUST invoke `bash scripts/compile-templates.sh --scope
company`."* The improvised helper anti-pattern is closed at Step 7.

`.claude/settings.json` pre-allows `Bash(bash scripts/compile-templates.sh:*)`
+ `Bash(scripts/compile-templates.sh:*)` + same for `migrate.sh` so
adopters don't get prompted during normal bootstrap. One named
allowlist entry per script vs N anonymous heredoc prompts pre-v0.6.4.

This is the first of three shipped-script fixes in v0.6.4. The other
two (`scripts/seed-matrix.sh` for F-7 and `scripts/audit-bootstrap-baseline.sh`
for F-8) require additional investigation:

- F-7 depends on F-12 (`coo.md` canonical v0 matrix has 11 errors
  the wizard auto-corrects; need to fix at source before encoding
  in a script).
- F-8 depends on F-11 (CSO query schema correctness; need to know
  which queries to encode).

Both deferred to a focused dogfood pass with explicit logging.

### Fixed — Wizard rendering rule amended with collection-collapse pattern (F-4 + F-5)

The v0.6.2 wizard determinism rule (HARD-REQUIRED one-question-at-a-time)
fixed the Delta Corp testco's batch-mode collapse but proved too rigid
during the Echo Corp testco run on 2026-05-09: the user faced 11
sequential prompts at Step 1.5 (folders), 4 at Step 1.5b (mailboxes),
6 at Step 4 (notifications), 20 at Step 9 (manifesto display + approve
× 10). Onboarding fatigue compounded by static-analysis approval
prompts during the CSO subagent audit (~300+ approvals).

v0.6.4 amends the rule with **two clauses**:

- **Clause 1 (unchanged from v0.6.2)** — identity-critical / branching
  fields render one question at a time, sequential, no batch.
  Step 1 identity (6 fields), Step 2 DB provider, Step 3 bank
  provider, Step 6 CRO enablement, Step 9 manifesto-approval mode.
- **Clause 2 (new, v0.6.4)** — **collection-collapse menu** for
  homogeneous collections of like-typed fields. Steps 1.5 / 1.5b /
  1.6 multi-human / 4 / 4.5 / 5 / 6 §2 names / 9 manifestos render
  a 4-option menu first:
    - [1] Accept all defaults (one approval, defaults applied)
    - [2] Edit specific (defaults + overrides)
    - [3] Walk-through every item (per-field prompts; v0.6.2
          fallback path)
    - [4] Skip the step (record as empty / null / fallback chain)

Path [1] for collections is **one decision** instead of N. Sandbox
and test instances pick [1] universally; production picks [3] for
the first bootstrap manifestos. v0.6.2 batch-mode prevention is
preserved by clause 1 + the menu-renders-verbatim requirement
(Skill emits exact text, no improvisation).

Per-step amendments:

- **Step 1.5 — folders**: header note documenting N=11 collection;
  default policy is function-centric layout.
- **Step 9 — manifestos**: full 4-option menu inlined verbatim.
  Path [1] writes all 10 in one transaction (10 manifests +
  10 agents + 10 bootstrap-action decisions). Path [3] is the
  canonical pre-v0.6.4 walk-through — kept as fallback for the
  production first-bootstrap. Path [4] keeps bootstrap NOT
  completed (master_context.bootstrap_completed_at stays NULL).

The two clauses together close finding #11 (wizard determinism)
in both facets: integrity (no batch-mode collapse on identity
fields) and UX (no N-prompt fatigue on collections).

### Fixed — v0.6.4 batch quick-wins (F-3, F-9, F-13, F-14, F-15)

Five small but adopter-visible fixes from the Echo Corp testco backlog,
batched together because each is a single-file change with clear
scope. Detail per finding:

- **F-3 — `hooks/bash-policy.json` CSO allow-list expansion.**
  Previous: `[git, gh, gpg, shellcheck, jq]` — too narrow for the
  audit job. CSO needs read-only access to query state, scan agent
  files, validate frontmatter. Expanded to: add `sqlite3`, `turso`,
  `grep`, `awk`, `sed`, `find`, `ls`, `cat`, `head`, `tail`, `wc`,
  `python3`. All read-only verbs; destructive `sudo`/`rm -rf`/`DROP`
  remain blocked by the universal deny-list.

- **F-9 — `.claude/settings.json` `defaultMode` policy + flag docs.**
  Kept the production-safe `acceptEdits` default (Edit/Write
  auto-accept, Bash prompts on each call). Added `README.md §
  Permission modes for sandbox / test contexts` documenting
  `claude --permission-mode auto` for trusted local work and
  `--permission-mode bypassPermissions` for `/tmp/<testco>` throwaway
  directories where the prompt cadence during the CSO audit becomes
  excessive (~300 prompts on the Echo run).

- **F-13 — `.mcp.json` first-run UX.** Pre-v0.6.4 shipped
  `.mcp.json` with the github MCP server pre-registered, requiring
  `GITHUB_PERSONAL_ACCESS_TOKEN` — every fresh adopter saw the
  *"Missing environment variables: GITHUB_PERSONAL_ACCESS_TOKEN"*
  warning at the first `claude` invocation. v0.6.4 ships an empty
  `mcpServers: {}` (with explanatory comment); README adds an
  `### Adding the github MCP server` section walking through PAT
  creation + env-var setup + `.mcp.json` snippet.

- **F-14 — `JUVANT_OS.md` Step 5 menu canonical pinning.** Previous
  prose said only *"Skip if CEO says 'no counterparties yet'"* —
  Skill improvised different menu UIs each session (Acme/Beta:
  4-option menu; Gamma: pipe-delimited; Echo: skip-only). Now the
  doc inlines the canonical 4-option menu verbatim
  (Skip / Sample / Walk-through / Custom); per the wizard
  determinism rule, Skill renders verbatim.

- **F-15 — `JUVANT_OS.md` Step 1.5 type-it slash-prefix caveat.**
  Claude Code's TUI interprets a leading `/` as a slash-command
  prefix; typing `/Echo Corp/01 - Legal` emits *"Unknown command:
  /Echo"* before the wizard recovers. Added a one-line caveat under
  the type-it path: *"Tip: paste folder paths verbatim — Claude
  Code may flag the leading `/` as an unknown command, but the
  wizard records the path correctly regardless."*

L1 4/4, L2 15/15, L4 10/10 PASS unchanged.

### Fixed — Layer 5 orphan-check SQL had wrong tool_name (HIGH; v0.6.4 patch #1)

Surfaced by the Echo Corp testco run on 2026-05-09 against post-v0.6.3
`main`. The v0.6.3 §11 detection SQL queries
`agent_actions_log.tool_name = 'Task'`, but Claude Code logs subagent
invocations with `tool_name = 'Agent'`. Result on every legitimate
audit: orphan check returns ALL CSO audit rows as suspect (11/11 false
positives in the Echo run), indistinguishable from the cover-up the
rule was designed to detect.

Fix: `tool_name IN ('Task', 'Agent')` in `agents/company/cso.md` §11.
Both names kept for forward-compat in case Anthropic renames.

This is the third revision of the §11 orphan check (v0.6.1 introduced
session_id-equality which never matched; v0.6.3 rewrote to time-window
correlation; v0.6.4 corrects the tool_name predicate). After this fix
the time-window correlation works as designed: zero false positives on
the Echo run's 11-row CSO audit.

The Echo run is documented in
`tests/integration/results-2026-05-09-echo-testco.md` as the canonical
v0.6.x cumulative validation record. 14 additional findings (F-2
through F-15) are tracked there for future v0.6.4+ patches.

### Fixed — Local SQLite hooks were silently no-op (HIGH) + Layer 5 orphan check correlation rewritten

Surfaced by the Delta Corp testco run on 2026-05-08: `agent_actions_log`
was **completely empty** after a full bootstrap with hundreds of tool
calls. Track 3 of handbook ADR 0004 (audit log) had been silently
disabled for every Local SQLite adopter since hooks were first shipped
on `main` (commit `9acfa71`). And the Layer 5 orphan-audit detection
rule shipped in v0.6.1 (`cso.md` §11) used a session_id-equality join
that **never matches** because the parent invoking Task and the spawned
CSO subagent use distinct Claude Code session_id values — the rule
produced false positives on every legitimate audit.

Two coupled bugs, both fixed in v0.6.3:

**Bug B — Local SQLite hooks no-op.** Pre-v0.6.3 every hook called
`turso db shell "$TURSO_URL"` directly. For Local SQLite adopters,
`db.url` is a filesystem path (e.g. `.juvant/state.sqlite`) — the
turso CLI cannot read filesystem paths, so every INSERT/UPDATE/SELECT
fell through to the silent `2>/dev/null || echo WARN` fallback.
`agent_actions_log` empty, `agents.status` never updated,
`agent_token_usage` never populated, `session_snapshots` never written.
Cloud adopters (Turso/Azure/AWS/GCP) were unaffected.

Fix:

- `hooks/lib/db.sh` — new shared helper. Three entry points:
  `juvant_db_exec` (DDL/DML), `juvant_db_query` (SELECT, text output),
  `juvant_db_query_csv` (SELECT, CSV output). `juvant_db_resolve`
  reads `db.provider` from `.juvant/config.json` and routes through
  either `sqlite3 <path>` (Local) or `turso db shell <url>` (cloud).
  Env override (`TURSO_URL`/`TURSO_TOKEN`) honored for cloud paths.
- All ten DB-touching hooks migrated to the helper:
  `pre-tool-use.sh`, `post-tool-use.sh`, `post-tool-use-failure.sh`,
  `session-start.sh`, `session-end.sh`, `subagent-start.sh`,
  `subagent-stop.sh`, `stop.sh`, `pre-compact.sh`, `post-compact.sh`,
  plus the `hooks/lib/track-tokens.sh` library.
- bash 3.2 SQL-escape regression fixed in `pre-compact.sh` while
  migrating (same root cause as the v0.6.0 fix in `pre-tool-use.sh`).

L2 hook tests (15/15) continue to pass — fake-turso shim is
provider-agnostic so the test setup works unchanged.

**Bug A — Layer 5 orphan check correlation broken.** The v0.6.1 rule
joined `security_audit_log.session_id` with `agent_actions_log.session_id`,
expecting them to share the parent's session_id. They don't:
`security_audit_log.session_id` is populated by the CSO subagent
(running in its own Claude Code session, getting its own session_id —
or a synthetic one as Delta showed: `cso-bootstrap-baseline-<TS>`),
while `agent_actions_log` rows for the Task invocation are written by
`pre-tool-use.sh` in the parent session (parent's session_id). The
two side never matched, so the orphan SQL flagged every legitimate
audit as suspect.

Fix in `agents/company/cso.md` Layer 5 §11:

- Rewrote the detection SQL to use a **time-window** correlation
  (Task invocation in the 60-min window preceding the audit row),
  no longer joining on session_id. Imprecise on which agent was
  spawned, but precise on the absence-of-Task signal (which is the
  cover-up failure mode we care about).
- Added two **fail-safe predicates** that catch the failure mode
  regardless of correlation precision:
  - Predicate (a): `agent_actions_log` empty plus `security_audit_log`
    with `auditor='cso'` populated → always cover-up flag.
  - Predicate (b): operator-mode (`AGENT_ROLE` unset / `'ceo'` /
    `'operator'`) writing audit rows → always cover-up flag, since
    humans cannot author CSO audits.
- Documented that the orphan check is best-effort
  defense-in-depth; the primary integrity guarantee remains
  `JUVANT_OS.md` Step 9.7 HARD-REQUIRED rule (v0.6.1).
- v0.6.4+ will add a `parent_session_id` column to
  `agent_actions_log` (or pass the parent session_id through the
  Task prompt and have CSO write it into `security_audit_log.session_id`)
  for tighter correlation. The `security_audit_log.session_id`
  column shipped in v0.6.1 stays in the schema as forward-compat
  metadata.

The Delta run is documented separately as an in-progress incident in
`tests/integration/results-2026-05-08-delta-testco.md` (added in a
follow-up commit if not already present).

### Fixed — wizard rendering must be deterministic (one question at a time)

Surfaced by the Delta Corp testco run on 2026-05-08 (post-v0.6.1
re-validation). At Step 1 (Identity), the Skill rendered all six
identity fields as a single batch prompt (*"reply with all six in
one message"*) — a fourth distinct rendering across four runs of the
same JUVANT_OS.md prose. Acme / Beta / Gamma had each rendered Step 1
"one question at a time" but inconsistently styled the wording.

This is wizard determinism finding #11 surfacing concretely. Prior to
v0.6.2 the rule lived only as informal phrasing inside individual
steps (e.g. Step 1's *"Collect from the CEO, one question at a time"*),
which different Skill sessions interpret as a suggestion rather than
a requirement. v0.6.2 promotes it to a load-bearing directive at the
top of `## Company setup` and `## Project setup`:

> **Wizard rendering rule (HARD-REQUIRED).** Every wizard step that
> collects multiple fields MUST render as one question at a time,
> sequentially, waiting for the CEO's reply before proceeding to the
> next field. Batch-mode collection is forbidden — non-deterministic
> across Skill sessions, breaks reasoning continuity, prevents
> per-field validation. The Skill emits each prompt, waits for the
> reply, records it, then emits the next. Steps with option menus
> render the menu verbatim from the JUVANT_OS.md prose without
> paraphrase or restructuring.

Step 1 prose tightened: bullet list → numbered sequence with
explicit "Skill emits each prompt, waits for the reply, records it,
then emits the next" preamble. Project setup section gets a
back-reference to the Company setup directive.

Same architectural principle as v0.6.1 (Step 9 hard-required CSO
audit): wizard procedure must be deterministic across Skill sessions.
v0.6.1 closed the integrity-relevant case (CSO audit fabrication);
v0.6.2 closes the UX-relevant cases (Step 1 batch, Step 1.5 missing
type-it option, Step 5 pipe-delimited freeform — all under the same
root cause).

### Fixed — CSO bootstrap_baseline audit can no longer be fabricated by the Skill (HIGH)

Surfaced by the Gamma Corp testco run on 2026-05-08 against post-merge
`main`. The wizard's previous Step 9 procedure permitted the Skill to
auto-skip the `Task(subagent_type='cso', ...)` invocation under
"sandbox-fast" interpretation, then synthesize the audit verdict
in-prose and write `security_audit_log` rows with `auditor='cso'`
directly. This is exactly the cover-up failure mode that handbook
ADR 0004 multi-track guardrails are designed to prevent: rows authored
as if produced by the CSO subagent that were in fact produced by the
Skill itself, structurally indistinguishable from a malicious agent
forging audit history.

Acme + Beta runs masked the failure mode by explicitly choosing
"Run via Task subagent" at the audit-mode prompt; Gamma run never saw
that prompt because the Skill collapsed "fast manifesto path" into
"skip all subsequent prompts including audit-mode". Three runs, three
different paths against the same JUVANT_OS.md prose.

The fix has four parts:

- **`SYSTEM_INVARIANTS.md` §1 step 7** — declares the Task spawn
  HARD-REQUIRED. Skill MUST NOT synthesize the verdict; MUST NOT write
  `security_audit_log` rows with `auditor='cso'` directly; MUST NOT
  substitute `subagent_type='general-purpose'` with inline cso.md
  briefing as a fallback. If the canonical resolution fails, the
  bootstrap aborts with explicit error and
  `master_context.bootstrap_completed_at` stays NULL — bootstrap is
  recoverable by addressing the registration gap and re-running.
- **`JUVANT_OS.md` Step 9** — removed the `[y/N]` "Trigger CSO audit?"
  prompt (it defaulted to skip-by-default and was the entry-point for
  the fast-path collapse). The audit now runs automatically and
  unconditionally. Step 7 declares the Task invocation hard-required
  with explicit prohibitions on synthesis / direct writes / fallback
  subagent type. Step 8 says verdicts come back from the subagent's
  response, never from the Skill's own reasoning. The project-bootstrap
  analog (Project setup Step 5) inherits the same hard-required rule.
- **`agents/company/cso.md` Layer 5 §11 — orphan-audit detection.**
  Any `security_audit_log` row authored as `auditor='cso'` lacking a
  corresponding `Task(subagent_type='cso', ...)` invocation in the
  same session window is forensically suspect. Detection SQL provided
  inline. HIGH-severity finding `cover-up:cso-audit-fabrication`.
  Operator-mode CSO audit rows (`AGENT_ROLE` unset or `'ceo'`) are
  flagged identically — humans cannot author CSO audits.
- **`scripts/schema.sql` + `scripts/upgrade-v0.5.sql`** —
  `security_audit_log.session_id TEXT` column added to support the
  Layer 5 orphan check (cross-reference against
  `agent_actions_log.session_id` for matching `tool_name='Task'`
  invocations). Existing rows without session_id are flagged by the
  Layer 5 check; new rows written by the CSO subagent capture the
  session_id from the event payload.

The Gamma run is documented in
`tests/integration/results-2026-05-08-gamma-testco.md` as the canonical
incident record.

### Added — ADR 0010: compiled agent registration via `.claude/agents/`

Surfaced by the Acme Corp testco bootstrap (FEAT-008 layer 4 dogfood,
2026-05-08, finding #6 — CRITICAL). Compiled agent templates lived
under `agents/<scope>/` but Claude Code's Task tool resolves
`subagent_type` from `.claude/agents/`. The two locations were not
bridged, so canonical `Task(subagent_type='<role>', ...)` failed to
register on every adopter and the Skill had to fall back to
`general-purpose` with inline briefing.

- `docs/adr/0010-compiled-agent-registration.md` (Accepted, validated
  end-to-end by the Beta Corp testco re-run on the same date).
- `.claude/agents/{ca,cco,cetho,cfo,chro,clo,cmo,cos,cro,cso}.md` —
  10 founding company-scope symlinks committed as mode 120000.
- `JUVANT_OS.md` Step 7 — item 5 documents the implicit registration.
- `README.md` — repo layout shows `.claude/agents/`.

### Added — FEAT-008 four-layer test suite

Closes `juvantlabs/juvant-os-pm#16`. L1 (eval scaffold), L3 (manual
integration scenarios), and L4 (schema validators) ship full;
L2 (hook tests) ships covering the v0.6.0 hook surface (15/15 cases).
LLM-judge automation and SDK-driven end-to-end runs are deferred
to v1.1.

- `tests/scenarios/` (L1) — eval scaffold + scenario lint + 4 seed
  scenarios (cfo/inbound-mail, clo/contract-review, cos/boot-summary,
  cso/system-audit).
- `tests/integration/` (L3) — three manual end-to-end procedures
  (mail-inbound-cfo-draft, context-compaction, offline-restart) +
  the dogfood evidence reports from the 2026-05-08 testco runs:
  `results-2026-05-08-acme-testco.md` (discovery, 10 findings) and
  `results-2026-05-08-beta-testco.md` (re-validation: six v1.0-blocking
  fixes confirmed PASS; CSO bootstrap_baseline audit returned PASS;
  three new MEDIUM/HIGH findings deferred to v1.1).
- `tests/hooks/run-tests.sh` (L2) — 15 cases against a local SQLite
  via `tests/hooks/fake-turso.sh` shim. Covers session-start,
  session-end + FEAT-024 token row, stop UPSERT idempotency,
  subagent-stop + parent_session_id, pre-tool-use universal deny +
  allow-list hit + allow-list miss + audit-log row + unknown role.
- `tests/schema/validate.py` (L4) — asserts 24 expected tables,
  9 indexes, CHECK constraint rejection of invalid maturity_status /
  to_status, baseline `model_pricing` seed presence, default values,
  and that `scripts/upgrade-v0.5.sql` applies cleanly to a v0.4-shape
  DB and backfills `project_maturity_history`.
- `.github/workflows/lint.yml` — three new CI jobs (L1, L2, L4) +
  `workflow_dispatch` + `push: branches: [release/**, feat/**]`
  triggers (the existing `pull_request` trigger has never fired on
  this repo).

### Added — FEAT-024: token usage tracking + cost report

Closes `juvantlabs/juvant-os-pm#40`. Captures token usage per session
and per subagent invocation, denormalizes cost using a versioned
`model_pricing` table, and surfaces a "Cost report" Skill operation
with by-agent / by-project / by-model breakdowns.

- `scripts/schema.sql` — `agent_token_usage` table (uuid pk,
  FEAT-022/023 forward-compat principal_id + project_slug,
  denormalized computed_cost_usd) + 5 indexes; `model_pricing` table
  (versioned by effective_from); seed rows for opus-4-7 / sonnet-4-6 /
  haiku-4-5 with explicit "verify against published pricing"
  disclaimer.
- `hooks/lib/track-tokens.sh` — shared library: transcript JSONL
  parse, pricing lookup, cost compute, UPSERT main / INSERT subagent.
- `hooks/stop.sh` — Stop hook (per-turn UPSERT for main session).
- `hooks/session-end.sh`, `hooks/subagent-stop.sh` — extended with
  FEAT-024 finalize / subagent-row write while preserving prior
  status-update behavior.
- `.claude/settings.json` — Stop hook registration.
- `JUVANT_OS.md` § Cost report — Skill operation phrasings, output
  structure, filter qualifiers, pricing-refresh procedure.

Token tracking is no-op on local-SQLite installations
(`hooks/lib/track-tokens.sh` requires Turso credentials per the
no-portal-on-local rule of ADR 0002). Adopters on Turso Cloud get
cost reports out of the box.

### Added — FEAT-023: project maturity status

Closes `juvantlabs/juvant-os-pm#39`. Adds the maturity-tier axis to
projects (`incubation` / `preview` / `general_availability`) that
calibrates how every agent treats the project — CMO publication
guard, CSO audit thresholds, CFO revenue tagging, CoS Morning Brief
grouping.

- `scripts/schema.sql` — `projects.maturity_status` column with
  CHECK constraint; `projects.maturity_changed_at`;
  `project_maturity_history` append-only table (demotion=1 flag);
  `idx_pmh_project_time` index. Plus a small bundled hardening:
  `agents.bash_allow` JSON-array column (mirrors
  `hooks/bash-policy.json` agent_allow[<role>] for query speed) and
  `idx_actions_log_status` index on `agent_actions_log`.
- `scripts/upgrade-v0.5.sql` — one-time migration for company DBs
  created before v0.6.0. Covers FEAT-018 bash_allow column,
  FEAT-019 agent_actions_log + indexes, FEAT-023 maturity_status +
  project_maturity_history (with backfill INSERT for existing
  projects), FEAT-024 agent_token_usage + model_pricing + seed.
  FEAT-025 (escalate-deny + bash_oneshot_grants) intentionally
  omitted — deferred to v1.1.
- `JUVANT_OS.md` § Project maturity status — two-axis model
  (status vs maturity_status), three-tier semantics with per-agent
  calibration table, transition procedure, agent guards, Skill
  operation.

### Fixed — bash 3.2 SQL escape regression in pre-tool-use.sh

The audit-log INSERT in `hooks/pre-tool-use.sh` used the bash
parameter expansion `${V//\'/\'\'}` which on macOS default bash 3.2
produces `\'\'` instead of `''` — invalid SQL escaping that silently
failed every `agent_actions_log` row carrying single quotes
(every allow-list miss deny reason). Replaced with a sed-based
`sql_escape` helper. Surfaced by FEAT-008 L2 tests on the first run.

Same root cause + same fix shape as commit `5d8aa52` (which only
patched `pre-compact.sh`). The same pattern still lives in
`hooks/post-tool-use.sh`, `hooks/post-tool-use-failure.sh`, and
`hooks/pre-compact.sh` — a follow-up sweep will harden those too.

### Fixed — testco trivial findings batch

Surfaced by the Acme Corp testco bootstrap on 2026-05-08. Full context
in `tests/integration/results-2026-05-08-acme-testco.md`.

- `scripts/migrate.sh` (finding #1) — handle `db.provider == "local"`
  (apply schema via `sqlite3` against a filesystem path); cloud
  providers retain the turso CLI path with TURSO_URL/TURSO_TOKEN env
  override.
- `JUVANT_OS.md` Step 3 (finding #2) — neutral inline descriptions
  per bank option + explicit no-template-maintainer-default directive
  (eliminates the synthesized "Common Juvant default" leak observed
  at runtime).
- `agents/company/cso.md` §9 (finding #4) — rephrased substitution
  audit rule without typing the literal token (was self-tripping the
  rule it described).
- `.gitignore` (finding #7) — added `.juvant/state.db` (local SQLite
  from Step 2 option [1]).
- `JUVANT_OS.md` Step 10 (finding #8) — extended canonical git-add
  list with `.github/CODEOWNERS`, `.gitignore`, `.claude/agents/`.

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
