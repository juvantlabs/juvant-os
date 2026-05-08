# Integration result: 2026-05-08 — Acme Corp testco bootstrap

End-to-end dogfood run of the company-init wizard against a throwaway
instance. Validates FEAT-008 layer 4 (acceptance) by exercising the OSS
template as-shipped, with no Juvant-specific state, against the full
JUVANT_OS.md `Initialize Juvant OS` flow through Step 10.5.

## Scope and method

| Field | Value |
|---|---|
| Test instance | `Acme Corp` (`acme-corp`), domain `acme.test`, CEO `Jane Doe` |
| Working tree | `/tmp/testco` (cloned from upstream juvantlabs/juvant-os) |
| Origin | `/tmp/testco-origin.git` (bare local repo — not GitHub) |
| Database | Local SQLite at `.juvant/state.db` (Wizard Step 2 option [1]) |
| Channels / bank / backup | All stubbed — test instance |
| Doc storage | OneDrive declared, type-it path with `/Acme/<role>` placeholders |
| Wizard driver | New Claude Code session opened in `/tmp/testco`, prompt `Initialize Juvant OS` |
| Outcome | **Bootstrap completed** — `master_context.bootstrap_completed_at = 2026-05-08T05:31:13Z` |
| Teardown | `rm -rf /tmp/testco /tmp/testco-origin.git` (no cloud artifacts) |

## Step-by-step outcome

| Step | Outcome | Notes |
|---|---|---|
| 1 — Identity | ✓ pass | 7/7 fields captured |
| 1.5 — Folders | ✓ pass | Type-it path used; wizard correctly recognized M365 connector belonged to a different tenant and offered a bypass |
| 1.5b — Mail | ✓ pass | Canonical defaults bound to `*@acme.test` |
| 1.5c — M365 write | ✓ pass | Deferred (no Azure AD app needed for test) |
| 1.6 — GitHub | ✓ pass | Single CEO handle `@jane-doe-test` resolved across all 11 `*_GITHUB` placeholders |
| 2 — DB | ✗ blocked, workaround applied | `scripts/migrate.sh` cannot apply schema with `db.provider == "local"` (finding #1). Schema applied via raw `sqlite3` to keep the wizard moving |
| 3 — Bank | ✓ pass | Custom provider `acmebank` accepted; finding #2 in wizard copy |
| 4 / 4.5 — Notifications + guardrails | ✓ pass | Stubbed; no-op fallback path observed |
| 5 — Counterparties | ✓ pass | 2 stub rows inserted across 3 tables |
| 6 — Names | ✓ pass | §2 defaults applied (Atlas, Theos, …) |
| 7 / 7.5 — Compile | ✗ blocked, workaround applied | cso.md:191 self-referential `{{NAME}}` token aborted scan (finding #4). After patch: 11 templates compiled; ad-hoc Python helper improvised in `.juvant/_compile.py` (finding #5) |
| 8 / 8.5 — Matrix | ✓ pass | 19 v0 rows seeded; 0 FAIL, 3 WARN (1 mitigation tracked as finding #10) |
| 9 — Bootstrap | ✗ blocked, workaround applied | CSO subagent could not be spawned via canonical `subagent_type=cso` (finding #6 — CRITICAL). Fell back to `subagent_type=general-purpose` with inline cso.md briefing. Audit returned `WARN-WITH-CONDITIONS`, 3 conditions logged (30-day clock) |
| 10 / 10.5 — Commit | ✓ pass | Commit subject placeholder substituted correctly (`init(acme-corp): …`); finding #7 + #8 surfaced and worked around |

## Findings

Severity:
- **CRITICAL** — blocks v1.0 ship; framework contract broken on every adopter
- **HIGH** — wizard cannot complete its own documented procedure without manual intervention
- **MEDIUM** — wizard completes, but artifacts/copy diverge from intent
- **LOW** — cosmetic / doc-drift

### #1 — `scripts/migrate.sh` has no local-SQLite path  · HIGH

`scripts/migrate.sh:19-31` hard-fails when `TURSO_URL`/`TURSO_TOKEN` are
unset, with no branch for `db.provider == "local"`. Wizard Step 2 option
[1] advertises Local SQLite as *"Recommended for test"* and JUVANT_OS.md
prescribes running migrate.sh for every provider including local.

**Fix:** read `.juvant/config.json`; if `db.provider == "local"`, treat
`db.url` as a filesystem path and apply the schema via `sqlite3`.

### #2 — Wizard Step 3 names "Juvant" in OSS-template copy  · MEDIUM

JUVANT_OS.md Step 3 (Bank provider binding) describes the Finom option
as *"Common Juvant default"*. The template ships to all adopters; naming
"Juvant" as a default reference violates the
no-fixed-names-in-template-artifacts rule. **Fix:** drop the "Juvant
default" phrase. Sweep the rest of JUVANT_OS.md while there.

### #3 — Placeholder-audit grep pattern is too narrow  · LOW

The CSO checklist (`agents/company/cso.md` §9) instructs auditors to
search for `{{NAME}}`-style tokens. The literal pattern `\{\{NAME\}\}`
matches only the example string, missing real placeholders like
`{{COMPANY_NAME}}`, `{{CEO_NAME}}`, etc. **Fix:** specify the canonical
pattern `\{\{[A-Z_]+\}\}` and the runtime-bound allowlist (today
`{{ACTIVE_PROJECT}}`). Optionally ship `scripts/audit-placeholders.sh`
encoding the contract.

### #4 — `cso.md:191` self-references the substitution rule  · HIGH

`agents/company/cso.md:191` documented the substitution rule using a
literal `{{NAME}}` example, which itself trips the rule it describes.
Wizard Step 7 correctly aborted on the self-reference. **Fix:** rephrase
without typing the literal token (e.g. *"any surviving double-brace
placeholder token"*). Patched on testco for continuation; same fix to
land upstream.

**Positive corollary:** validates that the wizard's CSO Layer-5 audit
fires correctly — it caught a real self-reference bug.

### #5 — Step 7 substitution mechanics underspecified  · MEDIUM

JUVANT_OS.md Step 7 describes *what* substitution must achieve but not
*how*. Two Claude sessions running the wizard will produce non-equivalent
artifacts (Python helper vs. iterative `Edit` calls vs. shell `sed`).
The testco inner session improvised a one-shot Python helper in
`.juvant/_compile.py` — wrong location (`.juvant/` is per-instance
gitignored state, not template tooling) and non-deterministic across
adopters. **Fix:** ship `scripts/compile-templates.sh` (or `.py`)
covering both `agents/company/*.md` and `.github/CODEOWNERS`; prescribe
its use in Step 7.

### #6 — Compiled agents not registered for Task subagent spawn  · CRITICAL

The wizard compiles agent templates into `agents/company/*.md` and
`agents/projects/*.md`, but Claude Code's Task tool resolves
`subagent_type` from `.claude/agents/*.md`. Without bridging the two
locations, **every framework subagent spawn from the Skill is broken
out-of-box** — the canonical `Task(subagent_type='<role>', ...)`
contract does not resolve. Surfaced when the testco run could not spawn
the CSO bootstrap_baseline audit and fell back to `general-purpose`
with inline briefing.

**Fix options (decide by ADR):**

1. Add Step 7.6: copy or symlink compiled agent files into
   `.claude/agents/<role>.md` after substitution.
2. Move `agents/company/*.md` to `.claude/agents/*.md` directly
   (architectural change — affects layout and gitignore).
3. Ship `scripts/register-agents.sh` invoked by the wizard.

Option 1 is least intrusive; Option 2 is structurally cleanest if
`.claude/agents/` is the canonical home anyway.

**Positive corollary:** the inner Claude correctly recognized the gap
and routed around it — the framework's degradation behavior under
missing registration is graceful, but original intent is unmet.

### #7 — `.gitignore` missing `.juvant/state.db`  · MEDIUM

The shipped `.gitignore` covers `.juvant/config.json` and secret paths
but not `.juvant/state.db` — the local SQLite file produced by Wizard
Step 2 option [1]. The testco wizard proactively patched `.gitignore`
before committing, but adopters following the documented flow without
that intervention would commit local state. **Fix:** add
`.juvant/state.db` to the shipped `.gitignore`.

### #8 — Step 10 canonical git-add list is incomplete  · MEDIUM

JUVANT_OS.md Step 10 prescribes staging `agents/`, `scripts/`, `hooks/`,
`.claude/settings.json`, `SYSTEM_INVARIANTS.md`, `JUVANT_OS.md`. Step 7.5
modifies `.github/CODEOWNERS` and the wizard often patches `.gitignore`
(see #7). Both are missed by the canonical add list, leaving a dirty
working tree post-bootstrap. **Fix:** extend the list to include
`.github/CODEOWNERS` and `.gitignore`. Or change the procedure to
`git add -A` filtered through a template-shipped allowlist file.

### #9 — Schema enum-comments diverge from wizard writes  · MEDIUM

`scripts/schema.sql` declares CHECK-comment enums on `manifests.status`
(`pending|approved|rejected`) and `agents.manifesto_status`
(`pending|approved`). Wizard Step 9 + SYSTEM_INVARIANTS.md §1 write
`operational_restricted` and `operational`. SQLite/LibSQL accept the
values silently, so the divergence is not caught at write time, but
schema comments mislead adopters and trip linters. **Fix:** align
enum-comments to the lifecycle states actually written, OR convert to a
real CHECK constraint and pick one canonical set.

### #10 — CoS dual capability: state.db read + external-channel send  · MEDIUM

The v0 `agent_tool_matrix` gives CoS both `turso` (state.db) and
`telegram:send` on the same row. `MCP_INVENTORY.md:60-61` names this
combination as forbidden under Universal Boundary §4. Mitigated at
runtime by `agents/company/cos.md:318` Security Rule #2, which forbids
reading `state.db` on external-facing turns. The runtime rule is correct
but unverifiable: nothing prevents CoS from violating it at inference
time.

**Fix options (decide by ADR):**

1. Ratify the runtime rule with a `PreToolUse` hook that blocks
   `telegram:send` when `state.db` was read in the same turn (handbook
   ADR 0004 Track 1 alignment).
2. Refactor the row to split CoS into two operating modes with disjoint
   MCP+channel sets.

## Passing assertions

The following framework behaviors were exercised and validated:

- ✓ Pre-flight rejects origin pointing at `juvantlabs/juvant-os` (not
  exercised in testco — origin is a local bare; verified by reading the
  pre-flight code path).
- ✓ Wizard recognizes M365 connector belongs to a tenant other than the
  CEO's company and offers a bypass (Step 1.5 — important genericity
  guard).
- ✓ Doc-storage type-it fallback path produces a complete schema in
  `.juvant/config.json` with no connector available.
- ✓ Placeholder substitution across 11 company-scope templates
  succeeds; only `{{ACTIVE_PROJECT}}` (allowlisted) survives.
- ✓ `agent_tool_matrix` v0 seed (19 rows) parses cleanly against
  `MCP_INVENTORY.md` with 0 FAIL.
- ✓ Bootstrap Protocol §1 step 8 logic correctly promotes manifestos to
  `operational` on `WARN-WITH-CONDITIONS` outcome.
- ✓ `master_context.bootstrap_completed_at` set exactly once; no
  partial-bootstrap state observed.
- ✓ Commit-message placeholder substitution works
  (`init(acme-corp): …`).
- ✓ `branch-protection-spec` decision queued correctly with payload
  marking `executed_by=COO` deferred to first project-init.
- ✓ Wizard handles non-GitHub origin gracefully at Step 10.5
  (record-without-apply).

## Recommendation for v1.0

| Finding | Severity | Recommend for v1.0 |
|---|---|---|
| #6 Subagent registration | CRITICAL | **Block ship.** ADR + fix required. |
| #1 migrate.sh local path | HIGH | Ship — trivial fix |
| #4 cso.md self-ref | HIGH | Ship — trivial fix (already prepared on testco) |
| #2 Juvant default leak | MEDIUM | Ship — trivial fix |
| #7 .gitignore | MEDIUM | Ship — one-line fix |
| #8 git-add list | MEDIUM | Ship — doc fix |
| #5 Substitution helper | MEDIUM | Defer to v1.1 — needs design |
| #9 Schema enum drift | MEDIUM | Defer to v1.1 — needs decision (comment vs constraint) |
| #10 CoS dual capability | MEDIUM | Defer to v1.1 — needs ADR |
| #3 Audit grep pattern | LOW | Defer to v1.1 — bundle with #5 |

Suggested release path:

1. Land `release/v0.6.0-close-v1.0` fixes for #6, #1, #4, #2, #7, #8.
2. Re-run a fresh testco bootstrap to validate the trivial batch and
   confirm #6 is closed end-to-end (CSO subagent spawns via canonical
   `subagent_type=cso`).
3. Run `tests/integration/context-compaction.md` and
   `offline-restart.md` against the validated testco.
4. Open the v1.0 release PR.

The deferred findings (#3, #5, #9, #10) become v1.1 backlog with this
report as their charter.
