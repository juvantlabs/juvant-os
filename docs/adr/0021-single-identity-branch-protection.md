# ADR 0021 — Branch protection for single-identity agent-maintained repos (administrators exempt)

## Status

Accepted (2026-06-23); **amended same day** — the exception is
`required_approving_review_count = 0`, not "1 review + `enforce_admins=false`"
(see the Decision amendment). **Applies to component-scope repos (ADR 0020)** where the
`<slug>-maintainer` agent operates as the same GitHub identity as the CEO. The
canonical ruleset in `docs/branch-protection-spec.md` remains unchanged for all
other repo classes; this ADR encodes the one exception needed under the single-
identity premise.

## Context

ADR 0020 (component-scope) introduced the `<slug>-maintainer` agent as the sole
writer for each library / MCP server / toolbox repo. The single-writer invariant
(SYSTEM_INVARIANTS §4 / ADR 0014) ensures that only one agent holds git/gh write
authority per repo at any time.

In the current org setup (documented in handbook ADR 0001 at
[`juvantlabs/handbook/docs/adr/`](https://github.com/juvantlabs/handbook/tree/main/docs/adr)),
the `juvantlabs` org has **one** GitHub identity: the CEO's personal account.
There is no separate bot account, no dedicated push identity, no second human
reviewer. The maintainer agent is therefore dispatched **as the CEO's identity**
when it performs git/gh operations.

This creates a structural deadlock when the canonical branch-protection ruleset
(see `docs/branch-protection-spec.md`) is applied with `enforce_admins=true`:

- The maintainer (operating as the CEO) opens a PR on the component repo.
- GitHub requires at least one approving review.
- The only available reviewer is the CEO — the same account that opened the PR.
- GitHub **forbids self-approval**: a user cannot approve their own pull request.
- The admin bypass (`enforce_admins=true`) prevents the CEO from merging without
  a review even as an admin.
- Result: **`main` is permanently locked** — no PR can ever be merged.

The first concrete instance of this deadlock was observed on
`juvantlabs/m365-graph-mcp-server` (2026-06-22/23) when branch protection was
applied with `enforce_admins=true`.

## Decision

For **component-scope repos** where the maintainer agent shares the CEO's GitHub
identity (i.e. there is no separate bot/reviewer identity in the org):

1. Apply the **canonical ruleset** from `docs/branch-protection-spec.md`
   (require PR, required status checks, no force-push, no branch deletion) but
   set **`required_approving_review_count = 0`** (`require_code_owner_review =
   false`, `require_last_push_approval = false`). This is the one deviation from
   the canonical spec.

   > **Amendment (2026-06-23).** The original decision kept "1 approving
   > review" and set `enforce_admins=false`. That does **not** clear the
   > deadlock — a 1-review requirement is unsatisfiable under a single identity,
   > so the *only* way to merge becomes an **admin bypass**, and an agent
   > sub-process cannot legitimately perform an admin bypass on its own (it is a
   > privileged outward action requiring direct CEO authorization, which the
   > anti-relay rule means it never receives through the orchestrator). The lock
   > simply moves from "can't merge" to "can't merge without a bypass the agent
   > can't make." Setting required reviews to **0** removes the bypass
   > requirement entirely: the maintainer prepares and merges a normal PR, gated
   > only by status checks. First corrected on `juvantlabs/juvant-os` itself
   > (2026-06-23) after the same deadlock surfaced there.

2. The "approving review" requirement becomes **procedurally enforced**, not
   technically enforced. The gate is:
   - The orchestrator (CoS) dispatches the maintainer to prepare a PR.
   - The CEO reviews the diff and authorizes the merge; the maintainer (or the
     CEO via the main operator thread) merges normally — **no admin bypass**.
   - The merge is logged in `agent_actions_log` (hooks) as the audit trail.
   - No `juvant:decision`-labeled Issue is required for routine PRs; for
     ADR-class or breaking changes, the `juvant:decision` label pattern from
     ADR 0020 §4 applies.

3. The **documented upgrade path** is: provision a dedicated second GitHub
   identity (bot account or co-maintainer human) as the required reviewer, then
   set `required_approving_review_count = 1` to restore full technical
   enforcement. Until that identity exists, the procedural gate is the accepted
   substitute.

This decision applies to any component-scope repo and, by extension, to any
repo in the `juvantlabs` org (or a downstream adopter's equivalent) where the
org has a single GitHub identity. It does NOT apply to:

- Company-scope repos with a separate bot or reviewer identity.
- Project-scope repos where a distinct `eng-lead` identity exists.
- Any repo where `enforce_admins=true` can be set without inducing the
  self-approval deadlock.

## Consequences

**Positive**
- Unblocks all merges on component-scope repos under single-identity orgs.
- Preserves the full branch-protection ruleset as a visible signal of intent;
  the audit records `WARN` (not `FAIL`) for the admins-exempt deviation because
  it is plan/identity-imposed, not adopter-neglect-imposed.
- The procedural CEO-review gate is operationally identical to what a technical
  gate would produce: no code reaches `main` without CEO visibility.
- The upgrade path is clear and self-contained: one new GitHub identity, one
  setting flip, no ADR amendment needed (the upgrade is within the envelope of
  the canonical spec, not a further exception).

**Negative / trade-offs**
- The "approving review" rule is not technically enforced: a CEO who chose to
  merge directly without reviewing the PR could do so. The safeguard is
  procedural discipline and the `agent_actions_log` trail.
- Audit tooling must treat `required_approving_review_count = 0` as `WARN`
  (not `FAIL`) when the single-identity condition is confirmed. Without this
  contextual check, the CSO baseline audit would produce spurious FAILs on all
  single-identity / component repos.
- Technical debt accrues until the upgrade path is exercised: the org remains
  dependent on one identity for both authoring and merging.

## References

- `docs/branch-protection-spec.md` — canonical ruleset; amended by this ADR
  (new subsection "Single-identity / agent-maintained repos").
- ADR 0020 (`0020-component-scope.md`) — component-scope definition; maintainer
  agent; §4 CEO ratification via `juvant:decision` label.
- ADR 0014 (`0014-tech-leadership-restructure.md`) — single-writer-per-scope
  invariant (SYSTEM_INVARIANTS §4).
- Handbook ADR 0001 ([`juvantlabs/handbook/docs/adr/`](https://github.com/juvantlabs/handbook/tree/main/docs/adr))
  — org-level premise: single GitHub identity in the `juvantlabs` org.
- First applied to: `juvantlabs/m365-graph-mcp-server` (2026-06-22/23).
