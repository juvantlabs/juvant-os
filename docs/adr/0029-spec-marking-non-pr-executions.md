# ADR 0029 — Spec-marking for artifact-less executions: capture the spec id at execution via an explicit signal

## Status

Accepted (2026-07-14, implemented same day). Mini-ADR resolving the **D1 punt**
of [ADR 0028](0028-spec-execution-marking-enforcement.md) — how ARCH-017 Layer 1
covers spec executions that produce **no GitHub artifact with a recoverable
body**. Tracks juvantlabs/juvant-os-pm#147 (item 1). All five sub-decisions
ratified (see §"Sub-decisions"); **S2 was corrected during implementation** —
the signal is a **Bash-command inline env-prefix**, so the mechanism covers
**Bash-landing executions only**; pure `Edit`/`Write` landings have no per-call
channel and are out of scope (documented, not silent).

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
write, as the link for artifact-less **Bash-landing** executions.

1. **Signal.** The executing agent runs the landing **Bash command** prefixed
   `JUVANT_EXECUTING_SPEC=<id> <cmd>` (an inline env-prefix). It names the
   `decisions.id` being executed. Scoped-by-construction to that one command.
2. **Capture.** `hooks/pre-tool-use.sh` (Track 3) reads the id **from the Bash
   command text** (not the process environment — an `Edit`/`Write` tool call has
   no per-call channel to carry it) and stamps it onto that action's
   `agent_actions_log` row in a new nullable `spec_id` column. **Correction (S2,
   during implementation):** this makes the mechanism **Bash-landing only** — the
   earlier "any tool" claim was wrong; pure `Edit`/`Write` landings are out of
   scope. Run the landing as a Bash command to make it gate-able.
3. **Gate.** The Layer-1 gate additionally blocks when this session has an
   `agent_actions_log` row with a non-null `spec_id` whose `decisions` row is
   still `approved` — with the same satisfiable, self-remediating close
   instruction. This complements (does not replace) the PR-body recovery, which
   remains the path for `pr-spec`/`gh-issue-spec`.

`deployment-spec` keeps the option of PR-body recovery when it goes through a
PR; the explicit signal is the fallback/general mechanism.

## Sub-decisions (all ratified 2026-07-14)

- **S1 — schema. RATIFIED.** Added `agent_actions_log.spec_id INTEGER` (nullable;
  soft reference to `decisions.id`, no FK to keep the append-only audit write
  cheap/local). Idempotent migration in `scripts/schema.sql` + `migrate.sh`
  (`common_patches`). The audit INSERT includes the column **only when the
  signal is present**, so the common write stays byte-identical and needs no
  migration dependency (an un-migrated DB simply never stamps).
- **S2 — signal mechanism & scoping. RATIFIED, WITH CORRECTION.** The signal is
  an **inline env-prefix on the Bash landing command** (`JUVANT_EXECUTING_SPEC=<id>
  <cmd>`), read by `pre-tool-use.sh` from the **command text** — no real
  environment variable, so it is scoped-by-construction to that one command
  (zero leak) and needs no set/unset discipline. **Correction:** this is
  **Bash-landing only**; the ADR's original "modality-independent (Bash/Edit/
  Write)" was wrong — `Edit`/`Write` tool calls cannot carry a per-call signal.
- **S3 — 5-check enforcement. RATIFIED.** For artifact-less spec categories
  executed via a Bash command (`secret-rotation-spec`, `install-spec`,
  local `deployment-spec`, `tool-matrix-change`, …), the execution step MUST
  carry the prefix; Eng Lead's "Format completeness" check REJECTs a plan that
  lacks it — mirroring the D2 `decisions#<id>` requirement for PR bodies. Not
  optional (else it under-covers silently — a BUG-057-class risk).
- **S4 — no false-block / no deadlock. RATIFIED.** The block fires only on a
  concrete stamped `spec_id` whose row is `approved` (always satisfiable — the
  agent knows the id it stamped); fail-open on any ambiguity, missing column, or
  error. The BUG-058 spool-drain applies (the stamped row is spooled too; the
  drain trigger was broadened to `merge|JUVANT_EXECUTING_SPEC`). Path 1 is
  pure-DB, so it gates even when `gh`/repo are unavailable.
- **S5 — scope of rollout. RATIFIED (reframed).** Ship the Bash-landing signal
  for all artifact-less categories; **pure `Edit`/`Write` landings stay out of
  scope** (run the landing as Bash to gate it). `deployment-spec` can lean on
  PR-body
  recovery meanwhile; fold it in if/when it needs the signal.

## Consequences

**Positive** — closes the spec-marking gap for Bash-landing artifact-less
executions (the categories with *no* possible after-the-fact recovery);
deterministic (explicit id, no heuristic); Path 1 is pure-DB so it gates without
`gh`/repo.

**Negative / cost** — a schema column + migration; a new authoring discipline
(prefix the landing command) that must be enforced by the 5-check or it silently
under-covers (a BUG-057-class risk — so S3 is not optional); **pure `Edit`/`Write`
landings remain uncovered** (no per-call channel).

## Alternatives rejected

- **Comment annotation (`# decisions#<id>` in the command), matched in
  `input_summary`.** No schema change, but a free-text comment is fragile to
  parse and easy to get wrong. The chosen `JUVANT_EXECUTING_SPEC=<id>` env-prefix
  is a **structured assignment token** `pre-tool-use.sh` extracts deterministically
  (same parser family as the BUG-054 env-prefix handling), and is the natural
  execution idiom. (Both are Bash-scoped — neither reaches `Edit`/`Write`.)
- **Gate on any approved spec the agent owns.** No per-action link → cannot tell
  which spec an action executed → false-blocks / deadlocks. Rejected in ADR 0028.
- **Category-specific state verification (read terraform state / cloud API).**
  Heavy, provider-specific, and still cannot verify a local `config-fix`.

## Affected surfaces

`scripts/schema.sql` + `scripts/migrate.sh` (S1), `hooks/pre-tool-use.sh` (S2
capture), `hooks/lib/spec-marking-gate.sh` (S3 gate), the ARCH-013 / 5-check
protocol in `JUVANT_OS.md` (S3), and the config-fix authoring flow.
