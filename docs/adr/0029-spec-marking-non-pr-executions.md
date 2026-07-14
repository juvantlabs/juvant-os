# ADR 0029 — Spec-marking for artifact-less executions: capture the spec id at execution via an explicit signal

## Status

Proposed (2026-07-14). Mini-ADR resolving the **D1 punt** of
[ADR 0028](0028-spec-execution-marking-enforcement.md) — how ARCH-017 Layer 1
covers spec executions that produce **no GitHub artifact with a recoverable
body**. Tracks juvantlabs/juvant-os-pm#147 (item 1). Proposed; no code until the
sub-decisions are ratified.

## Context

ARCH-017 Layer 1 (`hooks/lib/spec-marking-gate.sh`) and Layer 2
(`helpers/audit-reconcile.sh`) both recover the spec↔artifact link the same way:
find the GitHub artifact whose body references `decisions#<id>` — a **merged PR**
(`pr-spec`) or an **existing issue** (`gh-issue-spec`). That covers every spec
whose execution yields a body-bearing GitHub object.

It does **not** cover executions with no such artifact:

- **`config-fix` / direct local edits** — the "execution" is a local file put
  into the desired state (an `Edit`/`Write` tool call, or a local Bash mutation).
  There is **no PR, no issue, no durable external object** to recover a link from.
- **`deployment-spec`** — cloud mutations flow via the CEO-triggered
  terraform-apply **GitHub workflow** (local `terraform apply` is denied by the
  R3 deny-list). The artifact is a workflow run / the triggering PR — *sometimes*
  body-recoverable (if the triggering PR carries `decisions#<id>`), but not
  guaranteed.

### The load-bearing insight

For an **artifact-less** execution the link is **not recoverable after the
fact — ever**, by either layer: there is nothing to search. Layer 2's
"reconcile later" model, which works for PRs/issues, has **nothing to find** for
a `config-fix`. Therefore the only place the link can exist is **at execution
time**. This is decisive: artifact-less spec-marking *must* be capture-at-
execution or it is lost. Option "defer to Layer 2" is not available here.

## Decision

Add an **explicit execution signal**, captured by the existing PreToolUse audit
write, as the general (modality-independent) link for artifact-less executions.

1. **Signal.** The executing agent sets `JUVANT_EXECUTING_SPEC=<id>` for the
   duration of the landing action (the tool call that puts the artifact/state in
   place), then unsets it. It names the `decisions.id` being executed.
2. **Capture.** `hooks/pre-tool-use.sh` (Track 3) reads `JUVANT_EXECUTING_SPEC`
   and stamps it onto that action's `agent_actions_log` row in a new nullable
   `spec_id` column — for **any** tool (`Bash`, `Edit`, `Write`, …), so the
   mechanism is not Bash-only.
3. **Gate.** The Layer-1 gate additionally blocks when this session has an
   `agent_actions_log` row with a non-null `spec_id` whose `decisions` row is
   still `approved` — with the same satisfiable, self-remediating close
   instruction. This complements (does not replace) the PR-body recovery, which
   remains the path for `pr-spec`/`gh-issue-spec`.

`deployment-spec` keeps the option of PR-body recovery when it goes through a
PR; the explicit signal is the fallback/general mechanism.

## Sub-decisions (ratify before implementation)

- **S1 — schema.** Add `agent_actions_log.spec_id INTEGER` (nullable; a soft
  reference to `decisions.id`, no FK to keep the append-only audit write
  cheap/local). Idempotent migration in `scripts/schema.sql` + `migrate.sh`.
- **S2 — signal discipline & leak prevention.** `JUVANT_EXECUTING_SPEC` MUST be
  scoped to the single landing action (set immediately before, unset immediately
  after) so it does not bleed onto unrelated actions in the same session and
  over-tag them. Preference: a one-shot convention (the agent sets it inline for
  exactly the landing command) rather than a session-long export. Define the
  exact idiom in the protocol doc.
- **S3 — 5-check enforcement.** For artifact-less spec categories (`config-fix`
  and any category with no body-bearing artifact), the execution step MUST set
  the signal; Eng Lead's "Format completeness" check REJECTs an execution plan
  that lacks it — mirroring the D2 `decisions#<id>` requirement for PR bodies.
- **S4 — no false-block / no deadlock.** Same guarantees as Layer 1 today: the
  block fires only on a concrete stamped `spec_id` whose row is approved (always
  satisfiable — the agent knows the id it just stamped); fail-open on any
  ambiguity. The BUG-058 spool-drain applies (the stamped row is spooled too).
- **S5 — scope of rollout.** Ship `config-fix` first (the pure artifact-less
  case that has no other coverage). `deployment-spec` can lean on PR-body
  recovery meanwhile; fold it in if/when it needs the signal.

## Consequences

**Positive** — closes the only spec-marking gap with *no* possible after-the-fact
recovery; one mechanism covers all tool modalities; deterministic (explicit id,
no heuristic).

**Negative / cost** — a schema column + migration; a new authoring discipline
(set the signal at execution) that must be enforced by the 5-check or it silently
under-covers (a BUG-057-class risk — so S3 is not optional); env-var scoping care
(S2).

## Alternatives rejected

- **Command annotation only (`# decisions#<id>` in the Bash command).** Reuses
  `input_summary` with no schema change, but is **Bash-only** — `Edit`/`Write`
  input summaries are `"Edit <file>"` with no room for the ref, so it misses the
  main `config-fix` case (config edited via the Edit tool). Insufficient.
- **Gate on any approved spec the agent owns.** No per-action link → cannot tell
  which spec an action executed → false-blocks / deadlocks. Rejected in ADR 0028.
- **Category-specific state verification (read terraform state / cloud API).**
  Heavy, provider-specific, and still cannot verify a local `config-fix`.

## Affected surfaces

`scripts/schema.sql` + `scripts/migrate.sh` (S1), `hooks/pre-tool-use.sh` (S2
capture), `hooks/lib/spec-marking-gate.sh` (S3 gate), the ARCH-013 / 5-check
protocol in `JUVANT_OS.md` (S3), and the config-fix authoring flow.
