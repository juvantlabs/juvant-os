# Batch testco run — single-project (2026-11-05)

- Skill version: `19dc01f`
- Fixture version: 3
- Run timestamp (UTC): 2026-11-05T22:22:29Z
- Verdict: `WARN-WITH-CONDITIONS`
- Assertions: 34 total, 2 failed

## Run analytics (from stream-json)

- Total cost: $6.919937999999999
- API duration: 1264075 ms
- Wall duration: 1342908 ms
- Assistant turns: 178
- Stop reason: end_turn, errors: 0

### Tool calls

| Tool | Count |
|------|-------|
| Agent | 2 |
| Bash | 119 |
| Edit | 2 |
| Read | 7 |
| Skill | 1 |
| Write | 7 |

### Hook events

| Event | Count |
|-------|-------|
| PostToolUse | 113 |
| PostToolUseFailure | 1 |
| PreToolUse | 138 |
| SessionStart | 1 |
| Stop | 1 |
| SubagentStart | 2 |
| SubagentStop | 2 |

### Token + cost breakdown by model

- **claude-opus-5-5**: input=158, output=145623, cache_read=7720125, cache_create=393800, cost=$6.919937999999999

## Per-step durations + tokens (from [BATCH] event stream)

| Step | Duration | Tokens in | Tokens out |
|------|----------|-----------|------------|
| 1 | nulls | - | - |
| 1.5 | nulls | - | - |
| 1.5b | nulls | - | - |
| 1.6 | nulls | - | - |
| 2 | nulls | - | - |
| 2.5 | nulls | - | - |
| 3 | nulls | - | - |
| 4 | nulls | - | - |
| 4.5 | nulls | - | - |
| 5 | nulls | - | - |
| 6 | nulls | - | - |
| 7 | nulls | - | - |
| 7.5 | nulls | - | - |
| 7.6 | nulls | - | - |
| 8 | nulls | - | - |
| 8.5 | nulls | - | - |
| 9 | nulls | - | - |
| 10 | nulls | - | - |
| 10.5 | nulls | - | - |
| proj.1 | nulls | - | - |
| proj.1.gh | nulls | - | - |
| proj.1.doc | nulls | - | - |
| proj.2 | nulls | - | - |
| proj.3 | nulls | - | - |
| proj.4 | nulls | - | - |
| proj.5 | nulls | - | - |
| proj.5.cso | nulls | - | - |
| proj.6 | nulls | - | - |

