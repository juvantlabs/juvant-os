# ADR 0038 — What the Bash allow-list guarantees

## Status

Accepted (2026-11-06, CEO decision, BUG-103).

## Context

The per-role allow-list in `hooks/bash-policy.json` decides which binaries a role can run. `bash` and `sh` are on `universal_allow`, and the hook saw only `bash <file>`, so a role could write a script and run a binary it wasn't granted. A batch run did this after a denial: the session wrote a helper script and finished, and the final state looked clean.

Several allowed tools can also run commands (`awk`, `git`, `gh`, `sort`).

## Decision

1. **Roles with no interpreter** get `hooks/lib/exec-scope.sh`. `bash` and `sh` run only the framework scripts Track 2f keeps out of agent writes: `hooks/*.sh`, `hooks/lib/*.sh`, `helpers/*.sh`, `scripts/*.sh`. Allowed tools can't be used to run other commands.
2. **Roles with an interpreter** are exempt, and the policy derives this from `exec_scope.interpreters`. They can run anything through `python3` or `node`, and their job runs code. Adding such a binary to a role takes it out of the check, so that's part of the tool-matrix-change review.
3. **`tests/` isn't a script root.** Suites are instance-editable (decisions#300 item 9), so a role without an interpreter could write its own. They run through `eng-platform` or the CEO.
4. **Detection covers what prevention can't.** Any exec-scope denial reaches `helpers/anomaly-check.sh`. Audit rows carry the hash of the script run. The batch driver fails a run that executes a script it wrote or sets `JUVANT_FRAMEWORK_DEV`.

## What this guarantees

The allow-list stops drift and honest workarounds: an agent denied a binary can't get there by the usual routes, and the attempt is visible.

It is not a security boundary against an agent set on evasion. A list of forms that run commands can't be proven complete, and an interpreter role isn't limited at all. Boundaries that hold regardless of the agent's intent are credentials, schema triggers, the audit trail and the Bash sandbox (ADR 0036). Don't rely on the allow-list alone to protect something that matters.

## Consequences

- The awk and sed checks read program text and can deny a harmless program. An adopter that hits this surfaces it as a tool-matrix-change.
- A relative script path is only resolved from the session's working directory or a leading `cd`. Any other `cd` on the line needs an absolute path.
- Roles without an interpreter can't run a script in a project repo. If one needs to, it dispatches an engineering role.
- Upstream sync step 11 dispatches `tests/` suites.
