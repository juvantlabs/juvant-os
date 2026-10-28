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

## ConfigChange forensics (FEAT-062)

`config-change.sh` records a forensic row in `agent_actions_log` for every
configuration/skill change during a session (`source` + `file_path`, verified
event schema). It is deliberately **log-only / non-blocking**: a ConfigChange
`decision:"block"` does **not** revert the on-disk write — it only stops the
running session from hot-reloading the change (verified live, 2026-10-28). So
blocking here is not tamper *prevention*; this hook's job is **detection** (every
change is recorded even when it isn't prevented). Tamper *prevention* belongs at
the PreToolUse write-deny layer (deny `Write`/`Edit` of the guardrail files),
which is already fail-closed — tracked as a separate adopter-scoped issue.
