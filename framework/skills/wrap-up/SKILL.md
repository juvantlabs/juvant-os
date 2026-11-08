---
name: wrap-up
description: "Close a work session: journal entry, open items, what waits for the CEO, activity log, commit. Use when the CEO says the session is over, or asks to wrap up or save the work."
---

# Wrap up the session

1. **Journal.** Append a section to `memory/journal/<YYYY-MM-DD>.md` (create the file if needed):

```
## <HH:MM> — <one-line summary of the session>

- Done: <what was completed, with links to files>
- Decided: <decision files written, if any>
- Waiting for the CEO: <drafts to send, approvals, questions>
- Open: <what's left, and who has it>
```

2. **Decisions.** If the CEO decided something that isn't recorded yet, use the `decision` skill first.
3. **Knowledge.** Facts learned that will matter later (a client's preference, a supplier's terms, where a document lives) go into `memory/knowledge/` or `memory/map.md`. No secrets.
4. **Activity.** Record the outcome of the session for the dashboard:
   `python3 .claude/hooks/juvant_hooks.py log-outcome "<one line: what was achieved>"`
   For each collaborator you used whose result matters, add one line too:
   `python3 .claude/hooks/juvant_hooks.py log-outcome --agent <type> "<one line>"`
5. **Commit.** `git add memory state && git commit -m "Wrap-up <YYYY-MM-DD>: <summary>"`, then `git push` if the repo has a remote. Don't commit drafts meant for the CEO's review unless they belong in the repo.
6. Tell the CEO, in two or three lines, what was saved and what is waiting for them.
