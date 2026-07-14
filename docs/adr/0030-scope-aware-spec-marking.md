# ADR 0030 — Scope-aware spec-marking: qualify the decision reference by scope and resolve the right DB

## Status

Proposed (2026-07-14). Fixes **BUG-060** (juvantlabs/juvant-os-pm#148) and
subsumes **#147 item 2** (per-project reconcile). Extends the spec-marking
enforcement of [ADR 0028](0028-spec-execution-marking-enforcement.md) (Layer 1/2)
and [ADR 0029](0029-spec-marking-non-pr-executions.md) (the `spec_id` signal) to
work correctly across the company DB **and** N project DBs. Proposed; no code
beyond the **interim safety guard** (which should ship immediately) until the
sub-decisions are ratified.

## Context

Decisions are split across DBs: company specs live in `company.decisions`,
project specs in `project-<slug>.decisions` (§4c). `decisions.id` is a **per-DB
autoincrement**, so `decisions#42` in the company DB and `decisions#42` in a
project DB are **different rows**. But the enforcement is scope-blind:

- `hooks/lib/db.sh` `juvant_db_resolve` always resolves the **company** DB; there
  is no per-project repointing. All agents' `agent_actions_log` audit rows land
  in the company DB, while project decisions live in project DBs.
- The Layer-1 gate looks decisions up in the **company** DB, and its PR-body path
  fetches the PR from the **company** repo (`spec-marking-gate.sh:94`), ignoring
  the `--repo <project-repo>` in the actual merge command.
- The Layer-2 reconciler runs on the company DB only.

Consequences (BUG-060): a **cross-scope false-block** (a project session told to
close an unrelated company decision whose id collides) and a **coverage gap**
(project specs covered by neither layer). §4c also allows a project agent to
write a company-originated spec's confirmation to the *project* DB, so scope
cannot be inferred from the agent role alone — it must be explicit.

## Decision

Make the spec↔decision reference **scope-qualified**, and make the gate and
reconciler **resolve the DB (and repo) for that scope**.

1. **Scope-qualified reference.** The canonical reference becomes
   `decisions#<id>@<scope>`, where `<scope>` is `company` or a `<project-slug>`.
   A bare `decisions#<id>` means `@company` (back-compat). This applies to the
   ADR 0028 D2 PR-body requirement and the ADR 0029 signal
   (`JUVANT_EXECUTING_SPEC=<id>@<scope>`).
2. **Scope→DB resolution.** A shared helper resolves the target DB for a scope:
   `company` → `.db.*`; `<slug>` → `.projects[<slug>].db.*`. The gate and the
   reconciler use it to query/close the row in the **correct** DB. This is where
   #147 item 2's multi-DB connection work lives — folded in here, done once.
3. **Correct repo in the gate.** Path 2 uses the merge command's **actual**
   `--repo <org/repo>`, not the hardcoded company repo, to fetch the PR body.
4. **Interim safety guard (ship first, before the rest).** Independently of the
   format change, kill the false-block now: the gate acts only on references it
   can scope-confirm against the DB/repo it resolved — Path 2 proceeds only when
   the merge command's `--repo` equals the resolved company repo; Path 1 acts
   only on a `@company` (or bare) signal. Anything project-scoped → fail-open (no
   block) until scope-aware resolution lands. This removes the correctness hazard
   immediately and degrades to the (pre-existing) coverage gap, not a false-block.

## Sub-decisions (ratify before the full implementation)

- **T1 — reference grammar.** `decisions#<id>@<scope>` (recommended:
  GitHub-safe, greppable, bare = company). Alternative `<slug>:decisions#<id>`
  rejected as easy to confuse with `org/repo#N`.
- **T2 — scope→DB helper.** Add `juvant_db_query_scope <scope> <sql>` /
  `juvant_db_exec_scope` to `hooks/lib/db.sh` (resolve + run against the scope's
  DB), so the gate, reconciler, and future callers share ONE multi-DB path
  instead of ad-hoc `TURSO_URL` overrides. Provider-sensitive (local vs cloud) —
  the main implementation cost.
- **T3 — signal scope.** `JUVANT_EXECUTING_SPEC=<id>@<scope>`; `pre-tool-use.sh`
  stamps both `spec_id` and a new `spec_scope` (or a combined `spec_ref`) so the
  gate resolves the right DB. Bare = company.
- **T4 — 5-check enforcement.** For a project spec, the PR body / signal MUST be
  `@<project-slug>`-qualified; Eng Lead REJECTs a bare project reference (it is
  the collision source). Company specs may stay bare.
- **T5 — reconciler sweep.** Layer 2 iterates `company` + each `.projects[<slug>]`
  with a DB + repo, running the auto-close (pr-spec + gh-issue-spec) against each
  via T2, with per-scope repo resolution and per-project error isolation (one
  unreachable project DB does not fail the run). This IS #147 item 2.
- **T6 — §4c carve-out extension.** The audit-reconcile maintenance-writer
  carve-out (ADR 0028 §4c) must be extended to sanction writing the close-set to
  **project** DBs, tagged `executed_by='audit-reconcile'`, close-set only.

## Consequences

**Positive** — removes the cross-scope false-block (interim guard, immediately);
extends both layers to project scope correctly; unifies multi-DB access behind
one helper; folds #147 item 2 into a coherent design instead of a bolt-on.

**Negative / cost** — the scope→DB helper is provider-sensitive and is the real
implementation cost; a reference-grammar change with a back-compat default and a
new 5-check rule; a schema addition (`spec_scope`) alongside ADR 0029's
`spec_id`; the reconciler now writes across DBs (T6 carve-out).

## Rollout

1. **Interim safety guard** (§ Decision 4) — ships first, standalone, removes the
   false-block. Low-risk, no format change.
2. Scope-qualified references + scope→DB helper + gate/reconciler updates + T6.
3. #147 item 2 (per-project reconcile) rides on step 2.

## Affected surfaces

`hooks/lib/db.sh` (T2 helper), `hooks/lib/spec-marking-gate.sh` (scope-aware
lookup + correct repo + interim guard), `helpers/audit-reconcile.sh` (per-scope
sweep), `hooks/pre-tool-use.sh` + `scripts/schema.sql` (T3 `spec_scope`), the
5-check + D2/0029 protocol in `JUVANT_OS.md` (T4), `SYSTEM_INVARIANTS.md` §4c
(T6).
