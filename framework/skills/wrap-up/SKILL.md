---
name: wrap-up
description: "Close a work session: journal entry, open items, what waits for the CEO, activity log, commit. Use when the CEO says the session is over, or asks to wrap up or save the work."
---

# Wrap up the session

1. **Journal.** Append a section to `memory/journal/<YYYY-MM-DD>.md` (create the file if needed). If the session was about one project, write it in `memory/projects/<slug>/journal/<YYYY-MM-DD>.md` instead and update the Status section of the project's `README.md`:

```
## <HH:MM> — <one-line summary of the session>

- Done: <what was completed, with links to files>
- Decided: <decision files written, if any>
- Waiting for the CEO: <drafts to send, approvals, questions>
- Open: <what's left, and who has it>
```

"Waiting for the CEO" is the **whole current list**, one line, not just what's new: carry over what's still open from earlier sections, drop what's done. The CEO sees this line on screen when the next session starts.

2. **Collaborator sessions.** For each brief in `state/briefs/` started today, check the session with `ListAgents`: done, working or waiting for the CEO. Add it to the journal (deliverable and where it is) and log its outcome with `--agent <name>` (step 5). Sessions still working stay as they are; say so to the CEO.
3. **Decisions.** If the CEO decided something that isn't recorded yet, use the `decision` skill first.
4. **Knowledge.** Facts learned that will matter later (a client's preference, a supplier's terms, where a document lives) go into `memory/knowledge/` or `memory/map.md`. No secrets.
5. **Activity.** Record the outcome of the session for the dashboard:
   `python3 .claude/hooks/juvant_hooks.py log-outcome "<one line: what was achieved>"`
   For each collaborator you used whose result matters, add one line too:
   `python3 .claude/hooks/juvant_hooks.py log-outcome --agent <type> "<one line>"`
6. **Commit.** `git add memory state && git commit -m "Wrap-up <YYYY-MM-DD>: <summary>"`, then `git push` if the repo has a remote. Don't commit drafts meant for the CEO's review unless they belong in the repo.
7. Tell the CEO, in two or three lines, what was saved and what is waiting for them.
