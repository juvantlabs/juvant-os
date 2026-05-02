# hooks/

Lifecycle bash scripts called by Claude Code hooks.
Registered in `.claude/settings.json`.

| Script | Hook | What it does |
|---|---|---|
| `session-start.sh` | SessionStart | `agents.status = 'active'` in Turso |
| `session-end.sh` | SessionEnd | `agents.status = 'inactive'` in Turso |
| `pre-compact.sh` | PreCompact | Commit pending memory + produce Session Snapshot |
| `post-compact.sh` | PostCompact | Reload critical context from Turso |
| `notification.sh` | Notification | Push to Telegram + Teams webhook |

See Phase 3 of the build plan.
