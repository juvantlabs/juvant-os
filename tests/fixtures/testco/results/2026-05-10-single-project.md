# Batch testco run — single-project (2026-05-10)

- Skill version: `835b236`
- Fixture version: 1
- Run timestamp (UTC): 2026-05-10T06:26:11Z
- Verdict: `PASS`
- Assertions: 34 total, 1 failed

## Run analytics (from stream-json)

- Total cost: $3.8446762499999996
- API duration: 493408 ms
- Wall duration: 502042 ms
- Assistant turns: 74
- Stop reason: end_turn, errors: 0

### Tool calls

| Tool | Count |
|------|-------|
| Bash | 37 |
| Edit | 1 |
| Read | 8 |
| TodoWrite | 3 |
| ToolSearch | 1 |
| Write | 1 |

### Hook events

| Event | Count |
|-------|-------|
| PostToolUse | 50 |
| PostToolUseFailure | 1 |
| PreToolUse | 51 |
| SessionStart | 1 |
| Stop | 1 |

### Token + cost breakdown by model

- **claude-opus-4-7**: input=50, output=39736, cache_read=3385965, cache_create=185287, cost=$3.8446762499999996

## Per-step durations + tokens (from [BATCH] event stream)

| Step | Duration | Tokens in | Tokens out |
|------|----------|-----------|------------|
| 1 | 1.0s | - | - |
| 1.5 | 0.5s | - | - |
| 1.5b | 0.5s | - | - |
| 1.6 | 0.5s | - | - |
| 2 | 0.3s | - | - |
| 3 | 0.3s | - | - |
| 4 | 0.3s | - | - |
| 4.5 | 0.3s | - | - |
| 5 | 0.3s | - | - |
| 6 | 0.3s | - | - |
| 7 | 2.0s | - | - |
| 7.5 | 1.0s | - | - |
| 7.6 | 1.0s | - | - |
| 8 | 1.0s | - | - |
| 8.5 | 0.5s | - | - |
| 9 | 3.0s | - | - |
| 10 | 1.0s | - | - |
| 10.5 | 0.3s | - | - |
| proj.1 | 0.5s | - | - |
| proj.2 | 0.3s | - | - |
| proj.3 | 0.3s | - | - |
| proj.4 | 1.0s | - | - |
| proj.5 | 2.0s | - | - |
| proj.6 | 0.5s | - | - |

