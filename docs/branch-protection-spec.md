# Branch protection — recommended rules for `main`

Normative reference for branch protection on the `main` branch in any
per-company Juvant OS instance. The CSO `bootstrap_baseline=1` audit
checks for these rules; absence is recorded as a Tier-2 follow-up.

## Recommended rules

1. **Require pull request before merging**
   - At least 1 approving review required.
   - Dismiss stale reviews on new commits.
   - Require review from CODEOWNERS for protected paths (paths listed in
     `.github/CODEOWNERS`).

2. **Require status checks to pass before merging**
   - The `Juvant OS lint` workflow (from `.github/workflows/lint.yml`)
     must pass before merge. Adopters can add additional required checks
     post-init.

3. **Require linear history**
   - Squash or rebase merges only. No merge commits in `main`.

4. **Block force pushes**
   - `main` is append-only. History rewrites require admin override
     (logged in `decisions` category `forced-history-rewrite`).

5. **Block branch deletion**
   - `main` cannot be deleted via the standard interface. Protects against
     accidental destruction.

6. **Include administrators (where plan supports it)**
   - GitHub Team / Enterprise plans: enable. CEO (admin) is also subject
     to the rules.
   - GitHub Free org plans: not enforceable. Per CSO Layer 4 convention,
     ship the ruleset in `disabled` state rather than missing — see
     "Free-plan caveat" below.
   - **Single-identity exception**: when the maintainer agent operates as
     the same GitHub identity as the CEO (no separate reviewer identity
     exists), **required approving reviews MUST be `0`** — the review gate
     becomes procedural (the CEO reviews the diff and merges). A required
     review of 1 is *unsatisfiable* under a single identity (GitHub forbids
     self-approval); "1 review + admins-exempt" only relocates the deadlock,
     because every merge then needs an **admin bypass**, which an agent
     sub-process cannot legitimately perform on its own (it requires direct
     CEO authorization it never receives in this topology). Setting reviews
     to `0` lets the maintainer/CEO merge a PR normally; status checks,
     non-fast-forward, and deletion protection stay fully enforced. See
     ADR 0021 for rationale and the upgrade path (provision a second
     identity → restore reviews to 1).

## Single-identity / agent-maintained repos

Applies to **component-scope repos** (ADR 0020) where the `<slug>-maintainer`
agent operates as the same GitHub identity as the CEO — i.e. the org has no
separate bot account or second reviewer identity (see handbook ADR 0001).

**Rule**: apply the full canonical ruleset above, but set
**`required_approving_review_count = 0`** (`require_code_owner_review = false`,
`require_last_push_approval = false`). Keep every other protection — required
status checks (e.g. `lint`), non-fast-forward, deletion protection — and retain
the admin / bypass-actor for emergency override. This is the only permitted
deviation from the canonical spec under the single-identity condition.

**Why**: GitHub forbids self-approval — a user cannot approve their own pull
request. When author = reviewer = admin = one identity, "1 approving review
required" is unsatisfiable: the *only* way to merge is an **admin bypass**.
That is the trap — an agent sub-process will not (and should not) perform an
admin bypass on its own, because that is a privileged outward action requiring
direct CEO authorization, which it never receives through the orchestrator
(anti-relay rule). So "1 review + admins-exempt" doesn't fix the lock, it just
moves it from "can't merge at all" to "can't merge without a bypass the agent
can't make." Setting reviews to `0` removes the bypass requirement entirely:
the maintainer prepares and merges a normal PR, gated only by the status checks.

**Gate in this mode**: the CEO-review gate is procedural, not technical.
1. The orchestrator (CoS) dispatches the maintainer to prepare a PR.
2. The CEO reviews the diff and authorizes the merge; the maintainer (or the
   CEO via the main operator thread) merges normally — no admin bypass needed.
3. The merge is recorded in `agent_actions_log` as the audit trail.

**Audit treatment**: the CSO baseline audit MUST record
`required_approving_review_count = 0` as `WARN` (not `FAIL`) when the
single-identity condition is confirmed. A spurious `FAIL` would incorrectly
penalize an intentional, documented exemption.

**Upgrade path**: provision a dedicated second GitHub identity (bot account or
co-maintainer human) as the required reviewer, then set
`required_approving_review_count = 1` to restore full technical enforcement.
The upgrade is within the canonical envelope.

**Cross-reference**: ADR 0021 (`docs/adr/0021-single-identity-branch-protection.md`)
for full rationale, decision, and consequences.

## Application path

Branch protection is applied via the scope's writer using the
`branch-protection-spec` spec class (per `SYSTEM_INVARIANTS.md` §6 Spec
Authorization Matrix + ADR 0014 §4 single-writer-per-scope):

- **Company-scope repos** (template fork, *-infra at company scope,
  shared-services-infra, canonical-helpers source): `eng-platform`
  executes. Authors of the spec: CSO + CTO + eng-platform (joint).
- **Project-scope repos** (`<your-org>/<project>-infra`, project
  application repos): the project's `eng-lead` executes. Authors:
  CSO + PCA.

CEO approves either way before execution.

For first-time application during company init, the spec is authored
automatically by the wizard at Step 10.5 and queued for the appropriate
scope's writer. Adopters running with a single-CEO setup may apply the
rules manually via the GitHub web UI instead — both paths are accepted;
the audit only checks the resulting state.

## Free-plan caveat

GitHub Free org plans restrict branch protection to public repositories
and do not allow including administrators. Per `cso.md` Layer 4 (Code)
audit conventions:

- **Plan supports full enforcement**: rules required, enforced.
- **Plan limits enforcement** (e.g. private repo on Free plan): rules
  required, present in `disabled` state, **flagged as WARN** rather than
  FAIL by the audit. The intent is clear; the enforcement gap is plan-
  imposed, not adopter-imposed.
- **Rules missing entirely**: FAIL.

The distinction matters for Juvant Srls (the canonical OSS adopter)
because `juvantio/juvant` is a private repo on a Free org plan today.
The audit accepts `WARN` status on this dimension until / if the plan
is upgraded.

## Verification

The CSO baseline audit checks branch protection state via the
`github:read` MCP. Findings:

| State | Audit verdict |
|---|---|
| All rules present and enforced | PASS |
| Rules present but disabled by plan limit | WARN |
| Some rules missing | FAIL |
| No ruleset configured | FAIL |

## Re-application after upstream sync

When the OSS template ships updates to this spec (e.g. a new required
status check), adopters apply the delta via the standard upstream-sync
flow: CHRO drift detection → CTO `pr-spec` (here: `branch-protection-spec`
revision) → CEO approval → executor by scope (eng-platform for company-
scope repos, project's eng-lead for project-scope repos) per §4
single-writer-per-scope (ADR 0014).
