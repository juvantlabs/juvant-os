# Batch testco run — single-project (2026-11-06)

- Skill version: `8642a0e`
- Fixture version: 3
- Run timestamp (UTC): 2026-11-06T21:51:50Z
- Verdict: `WARN-WITH-CONDITIONS`
- Assertions: 34 total, 2 failed

## Run analytics (from stream-json)

- Total cost: $9.6880442
- API duration: 1671610 ms
- Wall duration: 1778640 ms
- Assistant turns: 287
- Stop reason: end_turn, errors: 0

### Tool calls

| Tool | Count |
|------|-------|
| Agent | 2 |
| Bash | 141 |
| Edit | 7 |
| Read | 53 |
| Skill | 1 |
| Write | 10 |

### Hook events

| Event | Count |
|-------|-------|
| PostToolUse | 193 |
| PostToolUseFailure | 1 |
| PreToolUse | 214 |
| SessionStart | 1 |
| Stop | 1 |
| SubagentStart | 2 |
| SubagentStop | 2 |

### Token + cost breakdown by model

- **claude-opus-5-5**: input=176, output=187360, cache_read=12172451, cache_create=559509, cost=$9.6880442

## Per-step durations + tokens (from [BATCH] event stream)

| Step | Duration | Tokens in | Tokens out |
|------|----------|-----------|------------|
| 1 | 0s | - | - |
| 1.5 | 0s | - | - |
| 1.5b | 0s | - | - |
| 1.6 | 0s | - | - |
| 2 | 0s | - | - |
| 2.5 | 0s | - | - |
| 3 | 0s | - | - |
| 4 | 0s | - | - |
| 4.5 | 0s | - | - |
| 5 | 0s | - | - |
| 6 | 0s | - | - |
| 7 | 0s | - | - |
| 7.5 | 0s | - | - |
| 7.6 | 0s | - | - |
| 8 | 0s | - | - |
| 8.5 | 0s | - | - |
| 9 | 0s | - | - |
| 10 | 0s | - | - |
| 10.5 | 0s | - | - |
| proj.1 | 0s | - | - |
| proj.1.gh | 0s | - | - |
| proj.1.doc | 0s | - | - |
| proj.2 | 0s | - | - |
| proj.3 | 0s | - | - |
| proj.4 | 0s | - | - |
| proj.5 | 0s | - | - |
| proj.5.cso | 0s | - | - |
| proj.6 | 0s | - | - |

