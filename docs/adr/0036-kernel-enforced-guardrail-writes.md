# ADR 0036 — Kernel-enforced protection of guardrail files via the Claude Code Bash sandbox

## Status

**Proposed** — 2026-11-03. Origin: ARCH-022 (`juvantlabs/juvant-os-pm#202`), the
follow-up to BUG-096/097/098 (`#199`, `#200`, `#201`). **Extends** handbook
ADR 0004 Track 2f (the tamper floor) and ADR 0034 (committed security policy).
It supersedes nothing. Track 2f stays in place.

## Context

The Track 2f tamper floor (`hooks/pre-tool-use.sh`) decides whether a Bash
command writes a protected path (`hooks/`, `helpers/`, `scripts/`,
`security/`, the audit spool and backups, `.git`, the guardrail launchd jobs)
by **reading the command text**. v1.17.1–v1.17.3 closed every class found so
far: option values, inline shell, interpreter code, and compound lines. A
text scanner cannot be complete, though. These classes stay open by
construction:

- paths computed at run time: `f=hooks; rm -rf $f`, `rm -rf $(cat list)`,
  `xargs rm -rf < list`;
- globs resolved by the shell: `rm -rf ho*ks`, `rm -rf [h]ooks`;
- tools whose targets live in data: `find . -path '*/hooks*' -delete`,
  `patch`, `git apply`, archive extraction;
- code that already exists: a `gh` alias defined before v1.17.2, or a script
  in a writable directory that the agent runs.

Today these are **detected**, not prevented. The SessionStart integrity check
(`hooks/lib/hooks-integrity.sh`) flags the damage on the next session.
Adding pattern after pattern does not converge.

Claude Code ships an OS-level Bash sandbox: Seatbelt on macOS, bubblewrap on
Linux and WSL2. Its filesystem rules apply to the command **and every process
it starts** (python, node, a script, `find -delete`), whatever the command
text says (code.claude.com/docs/en/sandboxing). It is the prevention layer the
text scanner cannot be.

## Decision

1. **Every deployed instance runs agent Bash inside the Claude Code
   sandbox**, with the escape hatch disabled. The configuration is generated
   by `scripts/compile-templates.sh` into `.claude/settings.json`:

   ```json
   {
     "sandbox": {
       "enabled": true,
       "allowUnsandboxedCommands": false,
       "filesystem": {
         "denyWrite": [
           "./hooks/", "./helpers/", "./scripts/", "./security/",
           "./.juvant/audit-spool*", "./.juvant/backups/",
           "./.juvant/pinned-main/", "./.juvant/alert-receipts.jsonl",
           "./.juvant/policy-blob-seen",
           "./.git/config", "./.git/refs/remotes/", "./.git/packed-refs",
           "~/Library/LaunchAgents/"
         ]
       },
       "network": { "allowedDomains": ["<compiled — see 3>"] },
       "excludedCommands": ["bash helpers/upstream-apply.sh *"]
     }
   }
   ```

   `allowUnsandboxedCommands: false` makes Claude Code ignore
   `dangerouslyDisableSandbox`, so a failed write cannot be retried outside
   the sandbox. The protected set is the one in `hooks/lib/guardrail-paths.sh`.
   A test keeps the two lists equal.

2. **What keeps writing.** Hooks, local MCP servers and launchd helpers are not
   sandboxed (by design of Claude Code), so:
   - the hook still appends to the audit spool;
   - the drain, backup and anomaly helpers still run;
   - `helpers/install-schedules.sh` is still run by the CEO from their own
     terminal or with `!`. The `!` shell does not pass through the sandbox.

3. **Network.** Sandboxed commands reach only the domains in
   `network.allowedDomains`. The allowlist starts empty, and in
   `dontAsk`/auto modes a domain that is not listed is refused. The list is
   compiled from the binaries in `scripts/templates/v0-agent-tool-matrix.json`
   through a new map in `bash-policy.json` (`binary_domains`), for example:
   - `gh` → `github.com`, `api.github.com`, `uploads.github.com`;
   - `turso` → `*.turso.io`, `api.turso.tech`;
   - `az` → its management endpoints.
   It is one list for the whole session. Per-role restriction stays with
   Track 2. MCP traffic is not affected.

4. **`.git`.** Only what the policy trusts is write-denied: `.git/config`
   (remotes, `insteadOf`, includes), `.git/refs/remotes/` and
   `.git/packed-refs`. Commits, branches and the index stay writable. As a
   result, an agent's `git fetch` / `git pull` cannot update
   `refs/remotes/origin/*`. The pinned-main launchd job, which is not
   sandboxed, becomes the **only** process that fetches `origin`. It already
   runs periodically for BUG-089. After an agent's `git push`, git cannot
   update the local remote-tracking ref. The push itself succeeds, and the
   next scheduled fetch reconciles the ref.

5. **Upstream sync.** Step 7 (`git checkout upstream/main -- <file>`) writes
   `hooks/` and the other protected directories, so it can no longer run in
   the sandbox. A new helper, `helpers/upstream-apply.sh <files…>`, does it
   and is the only `excludedCommands` entry. Claude Code keeps a call
   sandboxed unless **every** command in it matches, and a `cd`, a redirect
   or a `$( )` also keeps it sandboxed, so the entry cannot be piggy-backed.
   The helper:
   - refuses anything except a restore from `upstream/main` while `upstream`
     is the canonical `juvantlabs/juvant-os`;
   - accepts only files on the sync whitelist;
   - logs one audit row per file.
   The helper is itself a protected file.

6. **The settings files are protected too.**
   - The sandbox already protects `.claude/settings*.json` from Bash writes.
   - Track 2f adds them to the protected set for Write/Edit, which run outside
     the sandbox.
   - The SessionStart integrity check reads the effective `sandbox` block of
     the project settings, and of `settings.local.json` if present. It raises
     `[SANDBOX OFF]` (CSO-routed, alert-delivered) when `enabled` is not true,
     when `allowUnsandboxedCommands` is not false, or when `denyWrite` misses
     an entry of the protected set. No hook signal reports the sandbox state
     at run time, so the check works on the settings.

7. **Rollout.** One release opt-in behind `feature_toggles.bash_sandbox`, then
   default-on. Before default-on, every class listed in Context is verified
   **live** on a throwaway instance (macOS and Linux) and fails with
   `Operation not permitted` / `Read-only file system`. In the same run, the
   ordinary agent workflows keep working: `gh`, `git commit|push`, `turso`,
   helpers and tests. Linux and WSL2 adopters need bubblewrap. The
   company-init wizard checks for it, and boot flags its absence.

## Consequences

**Positive**
- Prevention no longer depends on parsing shell. Every class in Context is
  closed by the OS, including those not imagined yet.
- Track 2f becomes defense-in-depth that explains itself. Its deny message
  still tells the agent *why*; the sandbox is the guarantee.
- Network egress from agent Bash becomes an explicit, compiled allowlist.
  Today it is unrestricted.

**Negative / costs**
- A new failure mode: a legitimate command to an unlisted domain is refused.
  This is mitigated by compiling the list from the tool matrix and by
  surfacing the denial like a Track 2 deny.
- The upstream sync procedure changes (step 7 → the helper).
- Agent `git fetch` stops updating `origin/*`, so remote-tracking freshness
  depends on the scheduled fetch.
- Linux and WSL2 need bubblewrap.

**Neutral**
- The CEO's own `!` commands, hooks and MCP servers are unaffected.
- No schema change.

## Alternatives considered

- **Keep extending the text scanner.** Rejected as the guarantee: it is
  incomplete by construction. It is kept as the explanatory layer.
- **Filesystem permissions (a separate OS user owns the guardrail files, or
  `chflags schg`).** This is strong, but it needs root at install and
  breaks the upstream sync and the CEO's own edits. The macOS `uchg` flag
  can be removed by the same user, so it adds nothing.
- **Managed settings (MDM / `managed-settings.json`) as the carrier.** This
  is the strongest carrier, because no project file can override it. It is
  machine-scoped and outside the repo, so it does not ship with an upstream
  sync. Adopters with MDM may additionally pin the same block there; the
  integrity check accepts either source.

## Open points to settle before Accepted

1. Confirm the exact relative-path and glob syntax of `denyWrite` for paths
   inside the project, using the settings reference "Sandbox path prefixes"
   and a live test.
2. Confirm that a write-denied `.git/refs/remotes/` leaves `git push` usable,
   with only the local tracking ref failing to update.
3. Check the impact on the batch testco driver (`scripts/run-testco-batch.sh`),
   which runs `claude --print` inside a fixture.

## References

- handbook ADR 0004 (Track 2f); ADR 0034 (committed policy); ADR 0025.
- BUG-096/097/098 — `juvantlabs/juvant-os-pm#199`, `#200`, `#201`; ARCH-022 — `#202`.
- Claude Code docs: Sandboxing; Settings (`sandbox.*`).
