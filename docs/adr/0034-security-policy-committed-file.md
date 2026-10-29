# ADR 0034 — Instance security policy is a committed file read from origin/main

## Status

**Proposed** — 2026-10-29. Governing record: decisions#305 (CTO ruling on
security_audit_log#159, CEO-approved 2026-10-28). **Supersedes ADR 0025
clause 5 only** ("instance-specific rules live in `.juvant/config.json`
`.security.space_access[]`, gitignored"). Every other clause of ADR 0025 stands.
ADR 0025 is not edited: accepted ADRs are immutable; this ADR is its successor
for that clause.

## Context

ADR 0025 put the sensitive-space perimeter rules — the `driveId`s and agent
allowlists of a company's Universal-CONFIDENTIAL spaces — in
`.juvant/config.json`, with two intents:

1. the rules are **instance state**, so they must never live in an
   upstream-synced file (an `upstream-sync` would overwrite them and evaporate
   the perimeter);
2. the file is **gitignored**.

The 2026-10-28 CSO review (security_audit_log#159) showed intent 2 is the
problem. `.juvant/config.json` is excluded from git wholesale, so the rule
source has **no history, no review and no attribution**, and any agent can edit
it: emptying `.security.space_access` silently turned Track 2e into a no-op.
A perimeter whose rules the perimetered party can rewrite is not a perimeter.

## Decision

1. **The rules move to a committed file, `security/policy.json`, in the
   instance repo.** Not under `.juvant/` (gitignored wholesale). It holds
   `space_access` (Track 2e), `connector_tool_allowlist` (decisions#306) and
   `alert_routing`. **No secrets** — webhook URLs and tokens stay in
   `.juvant/config.json`.
2. **Intent 1 is kept.** `security/policy.json` is on the JUVANT_OS.md
   "Files NEVER touched" list: upstream sync never overwrites it.
3. **The hook reads the policy from the remote-tracking ref, not the working
   tree**: `GIT_NO_REPLACE_OBJECTS=1 git cat-file -p
   refs/remotes/origin/main:security/policy.json`. Local edits, local commits,
   branch switches, a local branch or tag named `origin/main`, and `git
   replace` have no effect on enforcement. A policy change is a reviewed merge
   to `main` followed by a fetch.
4. **What can move that ref is protected.** Track 2f denies writes to
   `security/policy.json`, to anything under `.git/`, and the git operations
   that move or redefine remote refs (`update-ref`/`symbolic-ref` on
   `refs/remotes`, `replace`, `remote add|set-url|rm|rename|…`, `config`
   writes to `remote.*`/`url.*`/`include.*`, `fetch` with a refspec into
   `refs/remotes`). The framework permission denies (decisions#303 R2) include
   `Edit/Write(security/policy.json)`.
5. **Fail closed.** A policy that is unparseable or structurally invalid, or
   that was deleted from `origin/main` after it existed, makes the hook deny
   every `mcp__` call, write a high `security_audit_log` row and alert. A
   required alert channel (`alert_routing.required`) with no secret configured
   denies the operations that would raise a sensitive-space row.
6. **Change detection.** At SessionStart, a policy blob on `origin/main`
   different from the previous session's → high row + CEO alert.
7. **`JUVANT_CONFIG` never selects the policy.** Tests use an explicit test
   flag (`JUVANT_POLICY_TEST=1` + `JUVANT_POLICY_FILE`); the SessionStart
   integrity check reports it if it appears in `.claude/settings*.json` `env`.
8. **Migration.** The legacy `.juvant/config.json` `.security.space_access` is
   honoured for ONE minor version, with a deprecation warning, when no
   `security/policy.json` has ever existed on `origin/main`. The adopter
   commits `security/policy.json` to `main` **before** syncing this mechanism.
9. **Validation.** `scripts/validate-security-policy.sh` (same rules as the
   hook) and `docs/schemas/security-policy.schema.json`; adopters run the
   validator in their CI on every PR touching the file.

## Consequences

**Positive**
- The perimeter's rules have history, review and attribution; no agent can
  weaken them from inside a session.
- A broken or removed policy is loud (deny + row + alert), never silent.

**Negative / costs**
- Editing the policy requires a merge to `main` from outside the agent session
  (the CEO's editor, terminal or the GitHub UI).
- A fresh clone needs `origin/main` fetched for the policy to apply; until then
  the legacy fallback (one minor version) or no-op applies.

**Residual**
- Someone with direct shell access outside Claude Code can still rewrite
  `.git/`; the CEO-visible change alert and the CSO audit are the controls.
- Secrets in `.juvant/config.json` remain readable by agents; moving them to
  the macOS Keychain is B1b (decisions#305), a separate change.
