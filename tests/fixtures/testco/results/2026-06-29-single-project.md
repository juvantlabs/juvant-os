# Batch testco run — single-project (2026-06-29)

- Skill version: `62a538c`
- Fixture version: 3
- Run timestamp (UTC): 2026-06-29T14:01:12Z
- Verdict: `WARN-WITH-CONDITIONS`
- Assertions: 34 total, 0 failed

## Run analytics (from stream-json)

- Total cost: $4.51970275
- API duration: 355828 ms
- Wall duration: 365520 ms
- Assistant turns: 112
- Stop reason: end_turn, errors: 0

### Tool calls

| Tool | Count |
|------|-------|
| Agent | 2 |
| Bash | 40 |
| Read | 5 |
| Skill | 1 |
| TaskCreate | 9 |
| TaskUpdate | 18 |
| ToolSearch | 1 |

### Hook events

| Event | Count |
|-------|-------|
| PostToolUse | 76 |
| PreToolUse | 76 |
| SessionStart | 1 |
| Stop | 3 |
| SubagentStart | 2 |
| SubagentStop | 2 |

### Token + cost breakdown by model

- **claude-opus-4-7**: input=73, output=37042, cache_read=4660312, cache_create=379910, cost=$7.055671
- **claude-opus-4-7[1m]**: input=20, output=6857, cache_read=191002, cache_create=45220, cost=$0.5496510000000001

## Per-step durations + tokens (from [BATCH] event stream)

| Step | Duration | Tokens in | Tokens out |
|------|----------|-----------|------------|
| 1 | 1.0s | - | - |
| 1.5 | 0.5s | - | - |
| 1.5b | 0.5s | - | - |
| 1.6 | 0.5s | - | - |
| 2 | 0.5s | - | - |
| 4 | 0.4s | - | - |
| 4.5 | 0.4s | - | - |
| 5 | 0.4s | - | - |
| 6 | 0.5s | - | - |
| 7 | 2.0s | - | - |
| 7.5 | 0.5s | - | - |
| 7.6 | 0.5s | - | - |
| 8 | 0.8s | - | - |
| 8.5 | 0.3s | - | - |
| 9 | 60.0s | - | - |
| 10 | 2.0s | - | - |
| 10.5 | 0.3s | - | - |
| proj.1.gh | 0.3s | - | - |
| proj.1.doc | 0.2s | - | - |
| proj.1 | 0.3s | - | - |
| proj.2 | 0.6s | - | - |
| proj.3 | 0.3s | - | - |
| proj.4 | 1.5s | - | - |
| proj.5 | 50.0s | - | - |
| proj.6 | 1.5s | - | - |

