---
name: new-project
description: "Start a new project's memory: memory/projects/<slug>/ with its card, decisions, knowledge and journal. Use when the CEO starts a project, or when work keeps coming back to a project that has no folder yet."
---

# Start a project

A project's memory lives in `memory/projects/<slug>/`, apart from the company's own memory, so it can be closed or handed over by moving one folder.

1. Agree a short slug with the CEO (lowercase, hyphens: `assist-2-launch`, `website-redesign`). Check `memory/projects/` for an existing one.
2. Create `memory/projects/<slug>/README.md` from `.claude/skills/new-project/project-README.md`, filling the name, today's date and what the CEO has told you of the goal, people and where things live. Leave unknown sections with their comment.
3. Create `decisions/`, `knowledge/` and `journal/` inside it (an empty `.gitkeep` in each).
4. Add the project to `memory/map.md` (one line: name, folder, code repo if any).
5. If the project has its own code repository, offer to give it the hard limits and the manifesto: from a clone of juvant-os, `bash setup.sh --project-repo <code-repo> --company-dir <this repo> --project <slug>`.
6. Record the start with the `decision` skill, in the project's `decisions/`.

When a project ends: set `status: closed` in its card, write a last journal entry, and record the decision. The folder stays for the history.
