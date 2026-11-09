# Company memory

Everything the company should remember, as plain files in this repo. Git keeps the history; anyone with access can read it. Agents read it with the digest they get at session start and with search (`grep -ri <word> memory/`).

**Never put here:** passwords, tokens, keys, bank credentials, or personal data the company doesn't need. Point to where a document lives instead of copying it.

| Folder | One file per | Written by |
|---|---|---|
| `decisions/` | decision the CEO took | the `decision` skill |
| `knowledge/` | topic: a client, a supplier, the product, the brand, a procedure | the `knowledge` skill |
| `journal/` | day | the `wrap-up` skill |
| `map.md` | — | where things live, who people are |
| `../docs/` (repo root) | long document: an ADR, a policy, a standard, an evaluation | anyone, with the CEO; decisions link to them |
| `projects/<slug>/` | project | the `new-project` skill: a `README.md` card plus its own `decisions/`, `knowledge/`, `journal/` |

## decisions/`YYYY-MM-DD-<slug>.md`

```
---
date: YYYY-MM-DD
decided_by: <name>
status: active | superseded
tags: [topic, client]
supersedes: <file, if any>
---

# <the decision in one sentence>

## Context
## Decision
## Alternatives considered
## Consequences
```

A decision is never edited to say something else: a new decision supersedes it, and the old one gets `status: superseded`.

## knowledge/`<topic>.md` (or knowledge/`<category>`/`<topic>.md`)

Knowledge may be grouped in one sub-folder per category (`runbook/`, `standards/`, `client/`, …): keep whichever layout the company already uses.

```
---
updated: YYYY-MM-DD
tags: [topic]
sources: [where the facts come from: a document, a meeting, the CEO]
---

# <Topic>

- <fact> (<source, date>)
```

Facts change: update the line, keep the source and date. If a fact was a decision, record it as a decision instead.

## journal/`YYYY-MM-DD.md`

One section per session: done, decided, waiting for the CEO, open.

## projects/`<slug>`/

One folder per project, same formats as above, plus `README.md`: the project card (frontmatter `status: active | paused | closed`; goal, people, where things live, status). A decision or fact about one project goes in its folder; one that applies to the company goes in the company's.

## map.md

Where documents, systems and accounts live (never their credentials), and the people the company works with and their role.
