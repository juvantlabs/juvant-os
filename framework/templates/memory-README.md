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

## private.md

Files marked **private**: one row each, readable only by the agents listed (`cos` is the Chief of Staff; the CEO can always read).

```
| File | Readers | Why | Added |
|---|---|---|---|
| docs/legal/settlement-2026.md | legal, cos | settlement terms | 2026-11-09 |
| https://contoso.sharepoint.com/sites/legal/Shared%20Documents/nda-x.docx | legal | NDA under negotiation | 2026-11-09 |
```

The hooks block anyone else from opening the file (reading, editing, Bash, the Microsoft 365 connector by its address). A broad search can still show a line of it in its results. Changing this file asks the CEO. Mark files, never whole folders or libraries.

## authorizations/`YYYY-MM-DD-<name>.md`

Long-task authorizations (`long-task` skill): what an unattended task may do that would otherwise ask the CEO — which actions, where, how many, until when, which subagents. Writing one asks the CEO, and that confirmation activates it for that session only. Any later change ends it. The task closes it when done (`status: closed`, with the outcome). Money, outbound, secrets and shared-repo merges can never be authorized.

## map.md

Where documents, systems and accounts live (never their credentials), and the people the company works with and their role.
