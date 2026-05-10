# Batch testco run — single-project (2026-05-10)

- Skill version: `4d453de`
- Fixture version: 2
- Run timestamp (UTC): 2026-05-10T20:51:29Z
- Verdict: `WARN-WITH-CONDITIONS`
- Assertions: 34 total, 1 failed

## Run analytics (from stream-json)

- Total cost: $5.604147500000001
- API duration: 708878 ms
- Wall duration: 731801 ms
- Assistant turns: 117
- Stop reason: end_turn, errors: 0

### Tool calls

| Tool | Count |
|------|-------|
| Agent | 2 |
| Bash | 56 |
| Read | 11 |
| TodoWrite | 8 |
| ToolSearch | 1 |
| Write | 1 |

### Hook events

| Event | Count |
|-------|-------|
| PostToolUse | 77 |
| PostToolUseFailure | 2 |
| PreToolUse | 79 |
| SessionStart | 1 |
| Stop | 1 |
| SubagentStart | 2 |
| SubagentStop | 2 |

### Token + cost breakdown by model

- **claude-opus-4-7**: input=91, output=39596, cache_read=6297507, cache_create=145622, cost=$5.049246000000001
- **claude-opus-4-7[1m]**: input=21, output=8344, cache_read=230818, cache_create=36926, cost=$0.5549014999999998

## Per-step durations + tokens (from [BATCH] event stream)

| Step | Duration | Tokens in | Tokens out |
|------|----------|-----------|------------|
| 1 | 1.0s | - | - |
| 1.5 | 1.0s | - | - |
| 1.5b | 1.0s | - | - |
| 1.6 | 1.0s | - | - |
| 2 | 1.0s | - | - |
| 3 | 1.0s | - | - |
| 4 | 1.0s | - | - |
| 4.5 | 1.0s | - | - |
| 5 | 1.0s | - | - |
| 6 | 1.0s | - | - |
| 7 | 3.0s | - | - |
| 7.5 | 1.0s | - | - |
| 7.6 | 2.0s | - | - |
| 8 | 1.0s | - | - |
| 8.5 | 1.0s | - | - |
| 9 | 120.0s | - | - |
| 10 | 3.0s | - | - |
| 10.5 | 1.0s | - | - |
| proj.1 | 1.0s | - | - |
| proj.2 | 2.0s | - | - |
| proj.3 | 1.0s | - | - |
| proj.4 | 2.0s | - | - |
| proj.5 | 60.0s | - | - |
| proj.6 | 2.0s | - | - |

