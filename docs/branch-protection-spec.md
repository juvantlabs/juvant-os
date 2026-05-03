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

## Application path

Branch protection is applied via COO using the `branch-protection-spec`
spec class (per `SYSTEM_INVARIANTS.md` §6 Spec Authorization Matrix).
CSO or CTO authors the spec; CEO approves; COO executes against the
GitHub API.

For first-time application during company init, the spec is authored
automatically by the wizard at Step 10.5 and queued for COO execution.
Adopters running with a single-CEO setup may apply the rules manually
via the GitHub web UI instead — both paths are accepted; the audit only
checks the resulting state.

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
flow: CHRO drift detection → CA `pr-spec` (here: `branch-protection-spec`
revision) → CEO approval → COO execution.
