# Batch testco run — single-project (2026-11-08)

- Skill version: `a446496`
- Fixture version: 3
- Run timestamp (UTC): 2026-11-08T08:41:13Z
- Verdict: `WARN-WITH-CONDITIONS`
- Assertions: 34 total, 0 failed

## Run analytics (from stream-json)

- Total cost: $5.5743864
- API duration: 772635 ms
- Wall duration: 874954 ms
- Assistant turns: 219
- Stop reason: end_turn, errors: 0

### Tool calls

| Tool | Count |
|------|-------|
| Agent | 2 |
| Bash | 113 |
| Edit | 15 |
| Read | 9 |
| Skill | 1 |
| Write | 3 |

### Hook events

| Event | Count |
|-------|-------|
| PostToolUse | 128 |
| PostToolUseFailure | 2 |
| PreToolUse | 143 |
| SessionStart | 1 |
| Stop | 1 |
| SubagentStart | 2 |
| SubagentStop | 2 |

### Token + cost breakdown by model

- **claude-opus-5-5**: input=236, output=76029, cache_read=11017262, cache_create=263910, cost=$5.5743864

## Per-step durations + tokens (from [BATCH] event stream)

| Step | Duration | Tokens in | Tokens out |
|------|----------|-----------|------------|
| 1 | 30s | - | - |
| 1.5 | 20s | - | - |
| 1.5b | 10s | - | - |
| 1.6 | 15s | - | - |
| 2 | 20s | - | - |
| 2.5 | 10s | - | - |
| 3 | 5s | - | - |
| 4 | 20s | - | - |
| 4.5 | 20s | - | - |
| 5 | 10s | - | - |
| 6 | 15s | - | - |
| 7 | 30s | - | - |
| 7.5 | 10s | - | - |
| 7.6 | 15s | - | - |
| 8 | 15s | - | - |
| 8.5 | 20s | - | - |
| 9 | 230s | - | - |
| 10 | 60s | - | - |
| 10.5 | 5s | - | - |
| proj.1 | 5s | - | - |
| proj.1.gh | 5s | - | - |
| proj.1.doc | 3s | - | - |
| proj.2 | 20s | - | - |
| proj.3 | 3s | - | - |
| proj.4 | 15s | - | - |
| proj.5 | 200s | - | - |
| proj.6 | 5s | - | - |

