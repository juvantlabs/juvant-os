# Batch testco run — single-project (2026-05-10)

- Skill version: `74d7786`
- Fixture version: 1
- Run timestamp (UTC): 2026-05-10T08:04:58Z
- Verdict: `PASS`
- Assertions: 34 total, 0 failed

## Run analytics (from stream-json)

- Total cost: $5.183735500000001
- API duration: 636685 ms
- Wall duration: 647258 ms
- Assistant turns: 97
- Stop reason: end_turn, errors: 0

### Tool calls

| Tool | Count |
|------|-------|
| Agent | 2 |
| Bash | 47 |
| Edit | 2 |
| Read | 13 |
| TodoWrite | 4 |
| ToolSearch | 1 |
| Write | 1 |

### Hook events

| Event | Count |
|-------|-------|
| PostToolUse | 68 |
| PostToolUseFailure | 2 |
| PreToolUse | 70 |
| SessionStart | 1 |
| Stop | 1 |
| SubagentStart | 2 |
| SubagentStop | 2 |

### Token + cost breakdown by model

- **claude-opus-4-7**: input=65, output=35591, cache_read=5105652, cache_create=199516, cost=$4.689901000000001
- **claude-opus-4-7[1m]**: input=20, output=6565, cache_read=204294, cache_create=36394, cost=$0.4938345

## Per-step durations + tokens (from [BATCH] event stream)

| Step | Duration | Tokens in | Tokens out |
|------|----------|-----------|------------|
| 1 | 1.0s | - | - |
| 1.5 | 0.5s | - | - |
| 1.5b | 0.5s | - | - |
| 1.6 | 0.5s | - | - |
| 2 | 1.5s | - | - |
| 3 | 0.4s | - | - |
| 4 | 0.4s | - | - |
| 4.5 | 0.4s | - | - |
| 5 | 1.0s | - | - |
| 6 | 0.5s | - | - |
| 7 | 2.0s | - | - |
| 7.5 | 1.0s | - | - |
| 7.6 | 1.0s | - | - |
| 8 | 1.0s | - | - |
| 8.5 | 0.5s | - | - |
| 9 | 35.0s | - | - |
| 10 | 2.0s | - | - |
| 10.5 | 0.5s | - | - |
| proj.1 | 0.3s | - | - |
| proj.1.gh | 0.3s | - | - |
| proj.1.doc | 0.2s | - | - |
| proj.2 | 1.5s | - | - |
| proj.3 | 0.4s | - | - |
| proj.4 | 1.5s | - | - |
| proj.5 | 58.0s | - | - |
| proj.6 | 1.0s | - | - |

