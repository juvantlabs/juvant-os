# ADR 0036 — Kernel-enforced protection of guardrail files via the Claude Code Bash sandbox

## Status

**Accepted** — 2026-11-03 (CEO-approved; verified live the same day). Origin:
ARCH-022, the follow-up to BUG-096/097/098. **Extends** handbook ADR 0004
Track 2f (the tamper floor) and ADR 0034 (committed security policy).
It supersedes nothing. Track 2f stays in place.
Opt-in: `feature_toggles.bash_sandbox`.

## Context

The Track 2f tamper floor (`hooks/pre-tool-use.sh`) decides whether a Bash
command writes a protected path by **reading the command text**. Protected
paths are the gate scripts, `helpers/`, `scripts/`, `security/`, the audit
spool and its backups, the git store the policy is read from, and the
guardrail launchd jobs. v1.17.1–v1.17.3 closed every class found so far. Even
so, a text scanner cannot be complete by construction. Three kinds of write
stay out of its reach:
- arguments computed at run time;
- shell expansion;
- tools whose write targets live in data rather than in the command line.

Those writes are **detected** afterwards by the SessionStart integrity check,
not prevented.

Claude Code ships an OS-level Bash sandbox: Seatbelt on macOS, bubblewrap on
Linux and WSL2. Its filesystem rules apply to the command **and every process
it starts**, whatever the command text says.

## Decision

1. **Agent Bash runs in the Claude Code sandbox** when
   `feature_toggles.bash_sandbox` is true. `scripts/sync-sandbox.sh` writes
   the canonical block (`scripts/templates/sandbox.json`) into
   `.claude/settings.json`, replacing only the `sandbox` key:
   - `enabled: true`.
   - `allowUnsandboxedCommands: false`: Claude Code ignores
     `dangerouslyDisableSandbox`, so a denied write cannot be retried outside.
   - `filesystem.denyWrite`: the protected set of
     `hooks/lib/guardrail-paths.sh`, kept in step by a test, plus
     `.juvant/secrets.json`. Of `.git`, it covers what the policy trusts:
     `.git/config`, `.git/refs/remotes/origin/`, `.git/refs/replace/` and
     `.git/packed-refs`. Commits, branches and the index stay writable.
   - `network.allowedDomains`: compiled from a `binary_domains` map, keeping
     the binaries some role is allowed in `hooks/bash-policy.json`, plus
     `sandbox.extra_domains` from the config.
   - `excludedCommands`: exactly two helpers. Claude Code keeps a call
     sandboxed unless **every** command in it matches, and a `cd`, a redirect
     or a `$( )` also keeps it sandboxed, so neither helper can be
     piggy-backed.
     - `helpers/upstream-apply.sh *` is the upstream-sync apply step. It
       accepts only a canonical `upstream` remote and a `sync/…` branch. It
       resolves and fetches upstream main itself, never trusting
       `refs/remotes/upstream/*`, which sandboxed Bash can move. Each file
       must be on that commit's Framework whitelist. Afterwards it reconciles
       the settings.
     - `helpers/fetch-origin.sh` fetches `origin`, because a sandboxed fetch
       cannot update `refs/remotes/origin/*`. `origin` itself cannot be
       repointed, since `.git/config` is write-denied.
2. **What keeps writing.** Hooks, MCP servers and the launchd helpers are not
   sandboxed. The CEO's own `!` commands do not pass through it either.
3. **Project working trees** stay writable through
   `permissions.additionalDirectories`, which the sandbox honours.
   `scripts/sync-project-globs.sh` is **not** excluded, because the paths it
   adds widen the writable area and come from the agent-writable config. With
   the sandbox on, the CEO runs it.
4. **The block protects itself.**
   - Claude Code write-protects `.claude/settings*.json` from sandboxed Bash.
   - Track 2f denies Write and Edit to them while the toggle is on, or while a
     sandbox block is enabled. Flipping the toggle in the agent-writable config
     therefore does not unlock them.
   - Both settings templates, `scripts/templates/sandbox.json` and
     `hooks-registration.json`, are now protected and content-checked against
     upstream. Before this change an edited hook-registration template, run
     through `sync-hooks.sh`, could unregister the gate.
5. **Detection.** No hook input says whether the sandbox is active, so the
   SessionStart integrity check verifies the settings. It raises
   `[SANDBOX OFF]` (a high `security_audit_log` row and a CEO alert) when:
   - the block is not canonical;
   - `settings.local.json` overrides it;
   - the check itself cannot run.

## Verification (live, macOS, Claude Code 2.1.317)

The probe ran in a throwaway instance-shaped repo, using a separate
`claude -p` session with the block generated from the template. Each attack
class from Context, executed through interpreters and child processes as
well as plain shell, was attempted against every protected path, and each
failed with `Operation not permitted`. The same held for:
- disabling the sandbox through `settings.json`;
- overriding it through `settings.local.json`;
- moving `refs/remotes/origin/main`;
- repointing `origin`.

Legitimate work kept succeeding: writes to the work tree, `git commit`,
`git push`, `git fetch upstream`, and reading and running helpers. Hooks
wrote the audit spool. A non-listed domain was refused (proxy 403), and a
listed one passed. Both excluded helpers did their job. The apply helper
chained with a destructive command stayed sandboxed: both failed.

## Consequences

**Positive**
- Prevention of guardrail writes no longer depends on parsing shell.
- Network egress from agent Bash becomes an explicit, compiled allowlist.
- The hook-registration template is protected, closing a gap that
  existed independently of the sandbox.

**Negative / costs**
- **Fetching `origin`** goes through `helpers/fetch-origin.sh`. A plain
  `git fetch origin` or `git pull` fails with "cannot lock ref".
- **Upstream tracking:** `git push -u` pushes but cannot record it, so agents
  name the remote and branch.
- **Unlisted domains** are refused. An adopter adds them to
  `sandbox.extra_domains`, and the CEO re-runs `sync-sandbox.sh`.
- **Upstream sync step 7** goes through the apply helper.
  `sync-project-globs.sh` becomes a CEO command.
- **Linux and WSL2** need bubblewrap.
- **A `claude --settings` override** given at launch is outside what the
  framework can see. Adopters with MDM can pin the same block in managed
  settings.

**Neutral**
- Track 2f stays as the explanatory, defense-in-depth layer.
- No schema change.

## Alternatives considered

- **Keep extending the text scanner.** It is incomplete by construction, so it
  is kept only as the explanatory layer.
- **OS file ownership or immutable flags.** These need root at install, and
  they break the upstream sync and the CEO's own edits.
- **Managed settings only.** This is the strongest carrier, but it is
  machine-scoped and does not ship with an upstream sync. Adopters may add it
  on top of the project block.

## Rollout

The sandbox is opt-in in v1.19. It becomes default-on in a later release,
after it has run on live instances, under a separate CEO decision.

## References

- handbook ADR 0004 (Track 2f); ADR 0034; ADR 0025.
- BUG-096/097/098 (v1.17.1–v1.17.3); ARCH-022.
- Claude Code docs: Sandboxing; Settings (`sandbox.*`).
