---
name: decision
description: "Record a decision the CEO has taken in memory/decisions/. Use right after the CEO decides something that should be remembered: a choice between options, a policy, a commitment, a no."
---

# Record a decision

Only decisions the CEO took. A recommendation, an agent's verdict or an open question is not a decision: if you're not sure the CEO decided, ask.

1. **Company or project?** A decision about one project goes in `memory/projects/<slug>/decisions/`; everything else in `memory/decisions/`. Ask the CEO if it isn't clear.
2. Pick a short slug (3–6 words, lowercase, hyphens) and today's date.
3. Check the same `decisions/` folder for an earlier decision on the same topic. If this one replaces it, say so in both files (`supersedes:` here, `status: superseded` there).
4. Write `<decisions folder>/<YYYY-MM-DD>-<slug>.md`:

```
---
date: YYYY-MM-DD
decided_by: <CEO name>
status: active
tags: [<topic>, <client or project if any>]
supersedes: <file, if any>
---

# <The decision, as one sentence>

## Context
<What prompted it, in two or three sentences. Link the documents.>

## Decision
<What was decided, precisely enough that someone could act on it.>

## Alternatives considered
<The options not taken, and why, in one line each.>

## Consequences
<What changes now, who does what, and any deadline.>
```

5. Tell the CEO the file name. Commit with the rest of the session's work at wrap-up, or now if the CEO asks.

Never put secrets or personal data beyond what the decision needs.
