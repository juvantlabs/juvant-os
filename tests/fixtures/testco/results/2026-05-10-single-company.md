# Batch testco run — single-company (2026-05-10)

- Skill version: `4d453de`
- Fixture version: 2
- Run timestamp (UTC): 2026-05-10T20:43:00Z
- Verdict: `WARN-WITH-CONDITIONS`
- Assertions: 27 total, 0 failed

## Run analytics (from stream-json)

- Total cost: $4.4622744999999995
- API duration: 456053 ms
- Wall duration: 471555 ms
- Assistant turns: 88
- Stop reason: end_turn, errors: 0

### Tool calls

| Tool | Count |
|------|-------|
| Agent | 1 |
| Bash | 50 |
| Read | 8 |
| TodoWrite | 3 |
| ToolSearch | 1 |

### Hook events

| Event | Count |
|-------|-------|
| PostToolUse | 62 |
| PostToolUseFailure | 1 |
| PreToolUse | 63 |
| SessionStart | 1 |
| Stop | 1 |
| SubagentStart | 1 |
| SubagentStop | 1 |

### Token + cost breakdown by model

- **claude-opus-4-7**: input=63, output=32302, cache_read=4369442, cache_create=185499, cost=$4.15195475
- **claude-opus-4-7[1m]**: input=10, output=3925, cache_read=91602, cache_create=26615, cost=$0.31031975

## Per-step durations

_No [BATCH] step_done events emitted; Skill produced final summary instead._
_(Event protocol persistence: file-persistence rule per JUVANT_OS.md § Batch mode.)_

