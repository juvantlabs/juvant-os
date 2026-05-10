# Batch testco run — single-project (2026-05-09)

- Skill version: `ff08da3`
- Fixture version: 1
- Run timestamp (UTC): 2026-05-09T23:50:55Z
- Verdict: `PASS`
- Assertions: 34 total, 0 failed

## Run analytics (from stream-json)

- Total cost: $4.376699750000002
- API duration: 764868 ms
- Wall duration: 787573 ms
- Assistant turns: 125
- Stop reason: end_turn, errors: 0

### Tool calls

| Tool | Count |
|------|-------|
| Agent | 2 |
| Bash | 80 |
| Grep | 2 |
| Read | 10 |
| Write | 1 |

### Hook events

| Event | Count |
|-------|-------|
| PostToolUse | 91 |
| PostToolUseFailure | 3 |
| PreToolUse | 94 |
| SessionStart | 1 |
| Stop | 1 |
| SubagentStart | 2 |
| SubagentStop | 2 |

### Token + cost breakdown by model

- **claude-opus-4-7[1m]**: input=193, output=50397, cache_read=3854882, cache_create=190139, cost=$4.376699750000002

## Per-step durations + tokens (from [BATCH] event stream)

| Step | Duration | Tokens in | Tokens out |
|------|----------|-----------|------------|
| 1 | 0.5s | - | - |
| 1.5 | 0.5s | - | - |
| 1.5b | 0.5s | - | - |
| 1.6 | 0.5s | - | - |
| 2 | 0.5s | - | - |
| 3 | 0.5s | - | - |
| 4 | 0.5s | - | - |
| 4.5 | 0.5s | - | - |
| 5 | 0.5s | - | - |
| 6 | 0.5s | - | - |
| 7 | 2.0s | - | - |
| 7.5 | 0.5s | - | - |
| 7.6 | 1.0s | - | - |
| 8 | 1.5s | - | - |
| 8.5 | 0.5s | - | - |
| 9 | 3.0s | - | - |
| 9.7 | 56.0s | - | - |
| 10 | 1.0s | - | - |
| 10.5 | 0.5s | - | - |
| proj.1 | 0.5s | - | - |
| proj.1.gh | 0.3s | - | - |
| proj.1.doc | 0.3s | - | - |
| proj.2 | 1.0s | - | - |
| proj.3 | 0.5s | - | - |
| proj.4 | 1.5s | - | - |
| proj.4 | 1.0s | - | - |
| proj.5 | 1.5s | - | - |
| proj.5.cso | 204.0s | - | - |
| proj.6 | 1.0s | - | - |

