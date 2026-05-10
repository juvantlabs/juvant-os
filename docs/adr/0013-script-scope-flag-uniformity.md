# ADR 0013 — Script scope-flag uniformity (`--project=<slug>` canonical pattern)

## Status

Accepted (2026-05-10). Promoted from
[ARCH-009 #42](https://github.com/juvantlabs/juvant-os-pm/issues/42).
Three instances already closed in v0.7.1 and v0.7.3 — F-23, F-24, F-31
— each followed the same template; this ADR codifies the pattern so
future scripts adopt it from day 1.

## Context

The framework's wizard prose (`JUVANT_OS.md`) drives the same shipped
shell scripts at two structurally different scopes — company init
(`## Company setup`) and project init (`## Project setup`). The first
batch of shipped scripts (v0.6.x baseline) operated only on
**company-scope state**, accessed via top-level keys in
`.juvant/config.json`:

```
.db.{provider,url,auth_token}
.agent_names.<role>
.bank.{...}
.notifications.{...}
```

When the project-init wizard reused these scripts at project scope,
each one repeatedly hit the same gap: the script had no way to find
project-scope state nested under `.projects.<slug>.<key>`. The Skill
worked around inline (Python heredoc, ad-hoc SQL) and surfaced the
gap as a finding only when an instrumented batch run captured it.
Three concrete instances:

| Finding | Script | Symptom | Closed |
|---|---|---|---|
| **F-23** | `scripts/compile-templates.sh` | `--scope projects` iterated `agents/projects/*.md` but did not substitute project-scope agent name placeholders ({{CTO_NAME}}, etc.); allowed `{{PROJECT_NAME}}` to survive even at project init when it should be bound. | v0.7.1 |
| **F-24** | `scripts/migrate.sh` | Read only top-level `.db.url`; per-project DB file at `file:.juvant/project-<slug>.db` never materialized despite the wizard inserting the projects table row pointing at it. | v0.7.1 |
| **F-31** | `scripts/audit-bootstrap-baseline.sh` | Refused any `--scope` other than `company`; project bootstrap_baseline audit (CSO subagent at `proj.5.cso`) emitted "audit BLOCKED: lacks project-scope support" and the project audit row was never written to `security_audit_log`. | v0.7.3 |

In each case the fix followed the same template:

1. Add a `--project=<slug>` flag (or `--scope=<slug>` where the existing
   flag already discriminated by name).
2. Read state from `.projects.<slug>.<key>` (canonical schema is
   nested under each category, symmetric with the company top-level
   `.<key>`).
3. Pre-flight verifies the slug exists in `.projects.<slug>` and that
   required fields (e.g. `.name`, `.db.url`) are present; fail-loud
   with a config-pointing error otherwise.
4. Default behavior (no flag) operates on company-scope as before
   — backward-compat for adopters who haven't yet run project-init.
5. Wizard prose explicitly invokes the flag form at the relevant step
   (`## Project setup` Step 2 / Step 4 / Step 5).

The pattern is likely to recur on any future script. Codifying it as
an ADR prevents the next contributor from relearning it through
another finding cycle.

## Decision

**Adopt `--project=<slug>` (or, where the existing flag already
discriminates by name, `--scope=<slug>`) as the canonical scope-flag
pattern** for every shipped script in `juvantlabs/juvant-os` that
operates on state that has both a company-scope shape (top-level
`.<key>` in `.juvant/config.json`) and a project-scope mirror
(`.projects.<slug>.<key>`).

### Schema convention

Project-scope state is **nested** by category in
`.juvant/config.json`, symmetric with the company top-level:

```jsonc
{
  "company": { ... },                          // company identity
  "db": { "provider": "...", "url": "...", "auth_token": "..." },
  "agent_names": { "cos": "Atlas", ... },
  "github_user_map": { ... },
  "bank": { ... },
  "notifications": { ... },
  "projects": {
    "<slug>": {
      "name": "<Display Name>",                // HARD-REQUIRED for compile-templates
      "slug": "<slug>",
      "scope": "project",
      "db": { "provider": "...", "url": "...", "auth_token": "..." },
      "agent_names": { "cto": "Pallas", ... },
      "doc_folder": "..."                      // optional
    }
  }
}
```

Adopters writing custom scripts that span scope MUST follow the
nested schema. Reading project-scope state from a flat shape (e.g.
`.projects.<slug>.url` instead of `.projects.<slug>.db.url`) is a
schema violation.

### Flag semantics

- **No flag** (default): script operates on company-scope, reading
  from top-level `.<key>`.
- **`--project=<slug>`** (or `--scope=<slug>` for scripts whose
  existing `--scope` flag already takes a discriminator): script
  operates on project-scope, reading from `.projects.<slug>.<key>`.
- **Resolve precedence** when `--project` flag is omitted but the
  script logic could still benefit from auto-resolution:
  1. `--project=<slug>` explicit pass.
  2. `.juvant/config.json` `.active_project` field, if set.
  3. Single-entry `.projects.<slug>` if exactly one project exists.
  4. Else error: "scope ambiguous, pass --project=<slug>".
- **Pre-flight error format**: `ERROR: project '<slug>' not found in
  $CONFIG (.projects.$<slug> missing).` to point the operator
  directly at the schema gap.

### Wizard contract

The `## Project setup` wizard prose in `JUVANT_OS.md` MUST invoke the
canonical flag form at the relevant step. The Skill MUST NOT
improvise inline substitution / migration / audit when the canonical
script exists. If the script genuinely lacks a needed code path
(F-31 was this — script existed but refused project scope), the
Skill emits a `[BATCH] {"event":"checkpoint","detail":"<script>
v<n.n.n> lacks project-scope support"}` event and continues; the gap
becomes the next ADR-013 instance.

### Backward compatibility

Existing scripts gain the flag without breaking the no-flag path.
Adopters who haven't run project-init see no behavior change. Adopters
who have run project-init are required to write the canonical nested
schema (which the wizard already produces; only adopter-authored
scripts that wrote a flat shape would need migration).

## Consequences

**Positive**:

- Future scripts ship the right pattern from day 1, without the
  finding → fix → re-validate cycle that consumed v0.7.1 + v0.7.3.
- Canonical references in `JUVANT_OS.md` become consistent and
  greppable (`bash scripts/<name>.sh --scope=<slug>` /
  `--project=<slug>`).
- Adopter custom scripts that span scope can read this ADR and know
  exactly which schema to expect under `.projects.<slug>`.

**Negative**:

- One more ADR to maintain. Mitigated by the pattern being
  self-documenting through naming convention (`--project=<slug>` is
  the obvious flag name once you've seen one example).
- Backward-compat for old scripts that wrote a flat
  `.projects.<slug>.<key>` shape would require schema migration. None
  exist in upstream; only adopter-side concern.

**Neutral**:

- ARCH-009 #42 in the PM repo is closed with a "promoted to ADR 0013"
  comment. Future contributors arrive at this ADR via the cross-link
  in CHANGELOG / git log / `JUVANT_OS.md` prose.

## Scope-flag pattern as a checklist

When a contributor introduces a new shipped script, evaluate:

1. Does the script read state from `.juvant/config.json`?
2. Does that state have a per-project mirror under `.projects.<slug>`
   (or could it plausibly gain one in v1.x)?
3. If yes to both → ship with `--project=<slug>` from day 1, schema
   following the nested convention.
4. If yes to (1) but no to (2) → no flag needed; document why the
   state is company-only (e.g. `seed-matrix.sh` — matrix is
   per-company by ADR 0006).

Scripts evaluated against this checklist as of v0.7.3:

| Script | Company-only or scope-spanning? | Flag |
|---|---|---|
| `scripts/seed-matrix.sh` | Company-only (ADR 0006: matrix per-company by design) | None |
| `scripts/compile-templates.sh` | Spanning | `--scope <company\|projects> [--project=<slug>]` |
| `scripts/migrate.sh` | Spanning | `[--project=<slug>]` (default: company) |
| `scripts/audit-bootstrap-baseline.sh` | Spanning | `--scope=<company\|<slug>>` |
| `scripts/run-testco-batch.sh` | Test infra (orchestrator; consumes fixtures, not config) | None |
| `scripts/validate-batch-fixture.sh` | Test infra | None |

## Cross-references

- ARCH-009 #42 (`juvantlabs/juvant-os-pm`) — original tracking issue;
  closed at this ADR's acceptance.
- F-23 closure: `juvantlabs/juvant-os` v0.7.1, commit `835b236`.
- F-24 closure: `juvantlabs/juvant-os` v0.7.1, commit `0532a6b`.
- F-31 closure: `juvantlabs/juvant-os` v0.7.3, commit `22c0284`.
- ADR 0006 (CA owns agent_tool_matrix) — explains why the matrix is
  per-company; canonical example of "company-only by design, no
  project flag needed".
- `JUVANT_OS.md` § Project setup Step 2 (project DB), Step 4 (project
  template compile), Step 5 (project bootstrap audit) — canonical
  wizard invocations of the flag form.
- `tests/integration/results-2026-05-10-batch-v0.7.1.md` — audit
  narrative covering F-23 / F-24 / F-31 surfacing and closure
  iterations.
