# hooks/

Lifecycle bash scripts called by Claude Code hooks.
Registered in `.claude/settings.json`.

| Script | Hook | What it does |
|---|---|---|
| `pre-tool-use.sh` | PreToolUse | Track 2 (Bash deny-list + per-agent allow-list with escalation to CoS on miss) + Track 3 (audit log row written before tool runs). Reads `bash-policy.json`. |
| `session-start.sh` | SessionStart | `agents.status = 'active'` in Turso |
| `session-end.sh` | SessionEnd | `agents.status = 'inactive'` in Turso + finalize main-session token-usage row (FEAT-024) |
| `stop.sh` | Stop | Per-turn UPSERT of cumulative main-session token usage (FEAT-024) |
| `subagent-start.sh` | SubagentStart | Mark subagent active in Turso |
| `subagent-stop.sh` | SubagentStop | Mark subagent inactive + INSERT subagent-invocation token-usage row (FEAT-024) |
| `pre-compact.sh` | PreCompact | Commit pending memory + produce Session Snapshot |
| `post-compact.sh` | PostCompact | Reload critical context from Turso |
| `notification.sh` | Notification | Push to Telegram + Teams webhook |

`lib/track-tokens.sh` is a shared library sourced by Stop, SessionEnd, and
SubagentStop. It parses the session transcript JSONL, aggregates `usage` per
model, looks up `model_pricing`, computes denormalized `computed_cost_usd`,
and UPSERTs (main session) or INSERTs (subagent) into `agent_token_usage`.

`bash-policy.json` is the source of truth for Track 2 enforcement:
universal `deny_patterns` (regex; HARD deny, no escalation) and per-agent
`agent_allow` (positive scope; allow-list miss → escalation to CoS via
`messages` row of type `tool_authorization_request`, not hard deny).
Mutated only via the standard `tool-matrix-change` decision flow
(CA proposes → CSO reviews → CEO approves → COO installs).

See Phase 3 of the build plan.
