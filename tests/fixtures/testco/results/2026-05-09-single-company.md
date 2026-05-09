# Batch testco run — single-company (2026-05-09)

- Skill version: `84ad549`
- Fixture version: 1
- Run timestamp (UTC): 2026-05-09T21:46:10Z
- Verdict: `PASS`
- Assertions: 27 total, 0 failed

## Run analytics (from stream-json)

- Total cost: $1.9566029999999996
- API duration: 219518 ms
- Wall duration: 226401 ms
- Assistant turns: 44
- Stop reason: end_turn, errors: 0

### Tool calls

| Tool | Count |
|------|-------|
| Bash | 17 |
| Read | 5 |
| TodoWrite | 1 |
| ToolSearch | 1 |

### Hook events

| Event | Count |
|-------|-------|
| PostToolUse | 23 |
| PostToolUseFailure | 1 |
| PreToolUse | 24 |
| SessionStart | 1 |
| Stop | 1 |

### Token + cost breakdown by model

- **claude-opus-4-7[1m]**: input=28, output=17770, cache_read=1146651, cache_create=150222, cost=$1.9566029999999996

## Per-step durations + tokens (from [BATCH] event stream)

| Step | Duration | Tokens in | Tokens out |
|------|----------|-----------|------------|
| 1 | 0.5s | - | - |
| 1.5 | 0.3s | - | - |
| 1.5b | 0.3s | - | - |
| 1.6 | 0.3s | - | - |
| 2 | 0.3s | - | - |
| 3 | 0.3s | - | - |
| 4 | 0.3s | - | - |
| 4.5 | 0.3s | - | - |
| 5 | 0.3s | - | - |
| 6 | 0.3s | - | - |
| 7 | 1.5s | - | - |
| 7.5 | 0.5s | - | - |
| 7.6 | 1.0s | - | - |
| 8 | 1.0s | - | - |
| 8.5 | 0.5s | - | - |
| 9 | 3.0s | - | - |
| 10 | 0.1s | - | - |
| 10.5 | 0.1s | - | - |

