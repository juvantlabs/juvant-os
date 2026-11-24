# framework/

Everything `setup` and `update` copy into a company repo. Generic: nothing here names a company.

| Folder | Holds | In a company repo |
|---|---|---|
| `agents/` | `legal`, `finance`, `ethics` | `.claude/agents/` |
| `skills/` | our skills and the vendored ones | `.claude/skills/` |
| `hooks/` | hard limits, culture injection, self-check, activity log | `.claude/hooks/` |
| `dashboard/` | the read-only page generator | `.claude/dashboard/` |
| `templates/` | `CLAUDE.md`, `manifesto.md`, `roles/`, `settings.json` | copied once by `setup`, then owned by the company |

`FILES` lists the framework-owned paths. Templates are copied by `setup` only; `update` never overwrites what the company has made its own.
