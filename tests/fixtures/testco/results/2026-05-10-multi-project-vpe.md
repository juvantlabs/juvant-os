# Batch testco run — multi-project-vpe (2026-05-10)

- Skill version: `08b1b3a`
- Fixture version: 1
- Run timestamp (UTC): 2026-05-10T21:07:25Z
- Verdict: `PASS`
- Assertions: 27 total, 3 failed

## Run analytics (from stream-json)

- Total cost: $3.966285750000001
- API duration: 558232 ms
- Wall duration: 581353 ms
- Assistant turns: 89
- Stop reason: end_turn, errors: 0

### Tool calls

| Tool | Count |
|------|-------|
| Bash | 44 |
| Grep | 1 |
| Read | 6 |
| TodoWrite | 7 |
| ToolSearch | 1 |

### Hook events

| Event | Count |
|-------|-------|
| PostToolUse | 57 |
| PostToolUseFailure | 2 |
| PreToolUse | 59 |
| SessionStart | 1 |
| Stop | 1 |

### Token + cost breakdown by model

- **claude-opus-4-7**: input=58, output=41532, cache_read=4143779, cache_create=136929, cost=$3.966285750000001

## Per-step durations + tokens (from [BATCH] event stream)

| Step | Duration | Tokens in | Tokens out |
|------|----------|-----------|------------|
| 1 | 1.0s | - | - |
| 1.5 | 1.0s | - | - |
| 1.5b | 1.0s | - | - |
| 1.6 | 1.0s | - | - |
| 2 | 2.0s | - | - |
| 3 | 1.0s | - | - |
| 4 | 1.0s | - | - |
| 4.5 | 1.0s | - | - |
| 5 | 1.0s | - | - |
| 6 | 1.0s | - | - |
| 7.5 | 1.0s | - | - |
| 7.6 | 1.0s | - | - |
| 7 | 3.0s | - | - |
| 8 | 1.0s | - | - |
| 8.5 | 1.0s | - | - |
| 9 | 3.0s | - | - |
| 9 | 4.0s | - | - |
| 10 | 2.0s | - | - |
| 10.5 | 0.5s | - | - |
| P | 4.0s | - | - |
| P | 4.0s | - | - |

