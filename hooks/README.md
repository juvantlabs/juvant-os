# hooks/

Lifecycle bash scripts called by Claude Code hooks.
Registered in `.claude/settings.json`.

| Script | Hook | What it does |
|---|---|---|
| `pre-tool-use.sh` | PreToolUse | Deny-list + per-role allow-list + single-writer gate (handbook ADR 0004 Track 2) |
| `post-tool-use.sh` | PostToolUse | Append-only audit log (Track 3) |
| `config-change.sh` | ConfigChange | Forensic log of every config/skill change to the audit log (FEAT-062, log-only) |
| `session-start.sh` | SessionStart | `agents.status = 'active'` in Turso |
| `session-end.sh` | SessionEnd | `agents.status = 'inactive'` in Turso |
| `pre-compact.sh` | PreCompact | Commit pending memory + produce Session Snapshot |
| `post-compact.sh` | PostCompact | Reload critical context from Turso |
| `notification.sh` | Notification | Push to Telegram + Teams webhook |

See Phase 3 of the build plan.

## Fail-closed PreToolUse gate (FEAT-061)

The `PreToolUse` registration in `scripts/templates/hooks-registration.json`
(synced into `.claude/settings.json` by `scripts/sync-hooks.sh`) sets
**`"onFailure": "block"`** on the hook handler. If `pre-tool-use.sh` cannot start,
times out, or exits with any code other than `0` (allow) or `2` (the explicit
deny path), Claude Code **blocks the tool call** instead of letting it through.
This closes the silent fail-open class: a crashing guard (missing `jq`, an
unbound-variable abort, a parse error) no longer yields "no decision → tool runs"
(the BUG-053 / BUG-073 family). The deny decision itself is still emitted in the
`hookSpecificOutput` wrapper **and** via exit code 2 (BUG-053); `onFailure` is the
third layer, for the case where the script never gets to emit anything.

- **Requires Claude Code v2.1.295+.** On older clients the field is silently
  ignored (inert, not harmful) — the exit-2 / hookSpecificOutput layers still apply.
- `onFailure` only has effect on decision-capable events (PreToolUse,
  UserPromptSubmit, PermissionRequest). It is intentionally **absent** on the
  observational hooks (PostToolUse, Session*, Subagent*, *Compact, Notification),
  where Claude Code does not honor it — a CI check in `lint.yml` enforces both this
  and the `onFailure:"block"` on PreToolUse.
- **Live smoke (run once in a real session, per the "verify gates live" rule):**
  temporarily make `pre-tool-use.sh` `exit 1` at the top, attempt a trivially
  allowed Bash command, confirm it is **blocked** (not run), then revert.
- **Missing script fails closed (decisions#298).** `onFailure` only covers a
  script that starts and fails. The registration wrapper used to be
  `[[ -f script ]] && exec script; exit 0`, so a *deleted or renamed*
  `pre-tool-use.sh` made the wrapper itself return 0 (allow) and every gate
  (allow-lists, single-writer, scope, Track 3) went dark. The PreToolUse wrapper
  now prints a message to stderr and `exit 2` when the script is absent. The
  observational hooks keep `exit 0` (a missing session hook must not wedge a session).

## ConfigChange forensics (FEAT-062)

`config-change.sh` records a forensic row in `agent_actions_log` for every
configuration/skill change during a session (`source` + `file_path`, verified
event schema). It is deliberately **log-only / non-blocking**: a ConfigChange
`decision:"block"` does **not** revert the on-disk write — it only stops the
running session from hot-reloading the change (verified live, 2026-10-28). So
blocking here is not tamper *prevention*; this hook's job is **detection** (every
change is recorded even when it isn't prevented). Tamper *prevention* belongs at
the PreToolUse write-deny layer (deny `Write`/`Edit` of the guardrail files),
which is already fail-closed — see the guardrail tamper floor below.

## Guardrail tamper floor (FEAT-064)

`pre-tool-use.sh` **Track 2f** denies `Write`/`Edit` (and Bash writes — output
redirect, `tee`, in-place `sed`) that target the structural-safety files: the
hook gate scripts (`hooks/*.sh`, `hooks/lib/*.sh`) and the universal deny-list
(`hooks/bash-policy.json`). In a deployed instance those arrive via upstream
sync, never by a live agent edit, so an agent cannot weaken its own guardrails
mid-session. The deny is itself audit-logged (Track 3). It inherits the Track 2f
= fail-closed behavior of the `onFailure:"block"` registration above.

`.claude/settings.json` is **not** covered — the Skill legitimately edits its
`permissions.allow` / `additionalDirectories` at bootstrap/project-add; its
changes are instead *recorded* by the ConfigChange hook (prevention for the hook
files, detection for settings.json).

**Adopter-scoped.** Framework development of these very files happens in the
upstream repo, so it is exempt. `JUVANT_FRAMEWORK_DEV` is tri-state: `1` = exempt
(framework dev / fork contributor), `0` = enforce (used by the test suite to
simulate an adopter), unset = auto (exempt iff `origin` is the canonical upstream
`juvantlabs/juvant-os`).
