# ADR 0028 — Close the spec-execution marking gap: capture the artifact link at execution, reconcile only the verifiable subset

## Status

Accepted (2026-07-14). Tracks **ARCH-017** (juvantlabs/juvant-os-pm#142).
Extends the **ARCH-013 governance protocol** in `JUVANT_OS.md` ("after
execution — mark `status='executed'` immediately; never leave an executed spec
as `approved`") from an *agent-remembered rule* to a *mechanically enforced*
one. Layered direction ratified (capture-at-execution primary + reconciler
backstop); all five sub-decisions resolved (D4 verified below; D1/D2/D3/D5
ratified — see §"Sub-decisions"). Implementation ships in two cuts:
**Layer 2 (reconciler backstop) first** (lowest risk, silences the audit
noise), then **Layer 1 (Stop-hook)**.

## Context

The `decisions` table is the governance source of truth. An approved spec is
executed (PR merged, config edited, Terraform applied), after which its row is
meant to close: `status='executed'`, `executed_at`, `executed_by`,
`source_ref`. In practice the closing `UPDATE` is a **separate,
agent-remembered step** with no mechanical coupling to the artifact landing, so
it is routinely skipped. The DB then reads `approved`/unexecuted while the
artifact is already live.

Observed in a live adopter instance:

- A config-fix spec whose target config was already in the fixed state, row
  still `approved` — nearly triggered a redundant re-apply.
- Five infra `pr-spec`s: all PRs merged, branches deleted, every row still
  `approved`.
- Two "orphan" decisions: executed specs with no `agent_actions_log`
  antecedent, surfaced by audit-reconcile as *possible fabrication*.

The DB is trusted by downstream automation, so the drift is not cosmetic:

1. **audit-reconcile false positives** — Anomaly 1 (orphan/fabrication) and
   Anomaly 4 (stale gh-issue/pr specs) in `helpers/audit-reconcile.sh` fire on
   already-done work; the noise masks real anomalies.
2. **Phantom pending work** — boot/status reads show completed specs as open →
   risk of re-executing done work.
3. **CSO gating stalls** — an incident held open pending a remediation whose
   spec-row said unexecuted, though the fix was already live (observed: a
   ~10-day-late incident closure). The gate keyed on the row, not reality.

`helpers/audit-reconcile.sh` today **detects** these (Anomaly 1 + Anomaly 4)
and alerts — its Anomaly 4 comment already names the root cause: *"Eng Lead
created the GH artifact but skipped the source_ref / status UPDATE."* It does
not close anything.

### The load-bearing constraint the naive fix misses

The reason the row is unmarked is the **same** reason a pure after-the-fact
reconciler struggles to close it: the field that links spec → artifact
(`source_ref`) is exactly the field that was never written. An after-the-fact
job must *reconstruct* a link that was lost. This has two consequences:

- The link is recoverable **only** when the artifact independently encodes the
  spec identity — e.g. a `pr-spec` whose PR body/commit references
  `decisions#NNN` or `Closes …`, or a deterministic branch-name convention.
- For `config-fix` / `terraform-spec`, "artifact present" is heterogeneous and
  often not machine-checkable. Auto-closing on **inference** there introduces
  the **reverse integrity risk**: marking `executed` a spec that was not — a
  new, opposite governance hole. The universal invariant "never fabricate an
  `executed` row" must not be traded away to fix "never leave `executed`
  unmarked."

This is why the three options in the report are **not equivalent
alternatives**, and why the answer is layered rather than a single pick.

## Decision

Adopt a **two-layer** mechanism. Capture the link when it is known; reconcile
only where it can be recovered without inference.

### Layer 1 (primary) — capture-at-execution via Stop-hook enforcement

The link (`source_ref`) is present in-session at the moment of execution. Force
it to be written **before the executing agent's session can end**, rather than
relying on memory.

- Extend the Stop / SubagentStop hook: at session end, if an agent has an
  in-scope `decisions` row that is `approved` **and** whose artifact has
  demonstrably landed within the session (e.g. a `gh pr merge` / `git push` /
  `terraform apply` action recorded in `agent_actions_log` for this session
  referencing the spec), **block the stop** with a self-remediating message
  instructing the agent to run the closing `UPDATE` (`status='executed'`,
  `executed_at`, `executed_by`, `source_ref`).
- This attacks the cause, not the symptom, and leaves **zero drift window** for
  in-session executions.
- **Coverage limit** (explicit, not silent): it cannot cover an artifact that
  lands **outside** an agent session — most importantly a PR the CEO merges by
  hand. Those fall to Layer 2.

### Layer 2 (backstop) — reconciler auto-close of the verifiable subset only

Extend `helpers/audit-reconcile.sh` from *detect-and-alert* to
*detect-then-auto-close-**iff**-verifiable*:

- **Auto-close** a stale `approved` `pr-spec`/`gh-issue-spec` **only** when the
  linked artifact is unambiguously verifiable *and* recoverable: the referenced
  PR/issue is merged/closed **and** the spec↔artifact link is machine-derivable
  (PR body or a commit contains `decisions#<id>` / `Closes <ref>`, or the
  branch matches the recorded convention). Write `status='executed'`,
  `executed_at=<merge time>`, `source_ref=<discovered artifact>`,
  `executed_by='audit-reconcile'`.
- **Alert only, never close** every ambiguous case (no recoverable link;
  `config-fix`/`terraform-spec`; any category without a machine-checkable
  artifact). This preserves the no-fabrication invariant.
- **Distinguishability**: an auto-closed row is tagged (`executed_by
  ='audit-reconcile'` + a note in `source_ref`) so audits can tell a
  reconciler close from an agent close.
- **Orphan-check consistency**: a reconciler-authored close must **not** then
  trip Anomaly 1 (orphan/fabrication). Anomaly 1's query is amended to exclude
  `executed_by='audit-reconcile'` closes (the same way it already tolerates
  `agent='cos'`/`'unknown'`), OR the reconciler writes its own
  `agent_actions_log` antecedent for the close. (Sub-decision D3 below.)

### Layer 0 (rule, unchanged) — ARCH-013 stays

ARCH-013's "mark executed immediately" remains the norm agents follow. Layers 1
and 2 are the enforcement/backstop that make compliance mechanical rather than
voluntary. Rejected as *primary*: **Option 1 (atomic close in the executor
path)** — there is no single execution chokepoint (PR merge is often the CEO;
config edits, Terraform, and gh writes each land differently), so atomic
coupling would require wrapping every modality; high-touch and brittle for
marginal gain over Layer 1. It may be revisited per-modality later.

## Sub-decisions (all ratified 2026-07-14)

- **D1 — Layer-1 landing signal. RATIFIED → (a).** The Stop-hook scans
  `agent_actions_log` for this session for write verbs (`gh pr merge`,
  `git push`, `terraform apply`) referencing the spec. No new mandatory field
  on the landing action.
- **D2 — Layer-2 link-recovery source of truth. RATIFIED.** Canonicalize the
  spec↔artifact link: **`decisions#<id>` is required in the PR body** (a
  `pr-spec` authoring-template requirement), so Layer-2 recovery is a
  deterministic search rather than a heuristic. Legacy rows without the
  reference are simply not recovered → they stay alert-only (safe degradation).
- **D3 — reconciler close vs. orphan-check. RATIFIED, and largely subsumed by
  the D4 never-INSERT bound.** Anomaly 1 keys on a row's `created_at`
  antecedent; the reconciler close is an **UPDATE** (never INSERT), so it does
  not change `created_at` and cannot manufacture an orphan. The
  `executed_by='audit-reconcile'` tag is nonetheless excluded from Anomaly 1 as
  belt-and-suspenders against a future regression that would make the close
  INSERT a confirmation row. No synthetic `agent_actions_log` antecedent is
  written (it would muddy the ground-truth log); reconciler closes are audited
  via the tag + the helper's own run log.
- **D5 — Layer-1 false-block escape hatch. RATIFIED.** If an artifact landed
  but the spec link is genuinely unknown, the Stop-hook surfaces-to-CoS and
  lets the session end (degrading to Layer 2) rather than deadlocking — the
  BUG-039 self-remediating-deny lesson (never name a remedy the agent cannot
  perform in-session).
- **D4 — §4 compliance. RESOLVED (verified against SYSTEM_INVARIANTS §4/§4b/
  §4c/§4d, 2026-07-14).** Findings:
  - **§4 single-writer does not apply.** Single-writer governs repo/cloud/npm
    (`eng-platform`, `eng-lead`); `decisions` is deliberately *multi-writer*
    (every agent authors specs there).
  - **§4d authorship is not implicated.** The reconciler **authors nothing** —
    it transitions the `status` of a row already authored by the correct agent
    and already `approved`. Recording that an approved decision's artifact
    landed ≠ authoring a decision.
  - **§4c is the real constraint** (it names `decisions` explicitly) and
    presumes rows are mutated by accountable *company-scope agents*; a scheduled
    helper is not an agent. **Resolution: a bounded §4c maintenance carve-out**
    for `audit-reconcile` — it MAY UPDATE `decisions` `approved → executed`
    **only** for the verifiable subset, writing **only** the close-set
    (`status`, `executed_at`, `executed_by='audit-reconcile'`, `source_ref`),
    **never** INSERT and never any other field. Do **not** route the close
    through the scope writer (a spec-to-close-a-spec is circular). Per §4c's
    spec-execution pattern, a project `pr-spec`'s confirmation lives in the
    project DB, so the carve-out applies **per scope** where the reconciler runs.
  - **Enforcement note (load-bearing).** The reconciler calls `juvant_db`
    directly via launchd/cron — it does **not** pass through PreToolUse /
    Track 2b, so no hook gates its writes. The close's safety (subset test,
    field allow-list, never-INSERT) must live in the reconciler's own logic and
    a dedicated test — it cannot be delegated to the tool-gate. `SYSTEM_
    INVARIANTS.md` §4c gains a one-line maintenance-writer carve-out documenting
    this bound.
- **D5 — Layer-1 false-block guard.** The Stop-hook must not trap an agent on a
  spec it cannot close (e.g. artifact landed but link genuinely unknown) — it
  needs a documented escape (surface-to-CoS) so it degrades to Layer 2 rather
  than deadlocking, echoing the BUG-039 self-remediating-deny lesson.

## Consequences

**Positive**

- In-session executions close with zero drift (Layer 1); out-of-session
  artifacts with recoverable links close within one reconcile cycle (Layer 2).
- audit-reconcile Anomaly 1/4 counts converge on *genuinely* open/unauthorized
  rows — the noise that masked the ~10-day incident stall goes away.
- The no-fabrication invariant is preserved: nothing is auto-closed on
  inference.

**Negative / cost**

- Two enforcement surfaces to maintain (Stop-hook + reconciler) instead of one.
- Layer 2 coverage is bounded by link-recoverability; `config-fix`/Terraform
  specs still rely on Layer 1 or manual close (surfaced by alert, not silently
  dropped).
- D2 may add a `pr-spec` template requirement (`decisions#<id>` in PR body),
  a small authoring-flow change.

## Acceptance criteria

- After a spec's artifact lands **in-session**, its `decisions` row reaches
  `executed` with `executed_at` + `source_ref` without a separate manual step
  (Layer 1).
- A merged `pr-spec` with a recoverable link but `approved` row is
  auto-reconciled to `executed` within one cycle, tagged
  `executed_by='audit-reconcile'` (Layer 2).
- An ambiguous / non-verifiable stale spec is **alerted, never auto-closed**.
- A reconciler-authored close does **not** raise an Anomaly 1
  orphan/fabrication alert.
- audit-reconcile stale-spec / orphan counts reflect only genuinely-open or
  genuinely-unauthorized rows.

## Affected surfaces

`helpers/audit-reconcile.sh` (Anomaly 1 + 4), the Stop / SubagentStop hook, the
ARCH-013 protocol section in `JUVANT_OS.md`, the `pr-spec` authoring flow (D2),
and `SYSTEM_INVARIANTS.md` §4 (D4 confirmation).
