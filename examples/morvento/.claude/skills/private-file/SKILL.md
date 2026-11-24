---
name: private-file
description: "Mark a single file as private (readable only by the agents listed) or make it ordinary again. Use when the CEO says a file is private or only for some roles, or when you or another agent think a file should be, and the CEO agrees."
---

# Private files

Some files are for some roles only: a settlement, a salary review, an NDA under negotiation. They are listed in `memory/private.md` (format in `memory/README.md`); the hooks stop everyone else from opening them.

**Files, never folders or libraries.** Marking whole folders brings back the heaviness juvant-os v2 left behind. If many files in one place are private, that's a question for the CEO about where those files should live.

## Mark a file private

1. Identify the file exactly: a repo path (`docs/legal/settlement-2026.md`), an absolute path, or the SharePoint/OneDrive address or item id the Microsoft 365 connector uses for it.
2. Agree the readers with the CEO: agent ids (`legal`, `finance`, `ethics`, a collaborator's session name), and `cos` if the Chief of Staff should read it too. The CEO can always read it.
3. Add one row to `memory/private.md` (create it with the table header if missing): file, readers, why in a few words, today's date. The write asks the CEO: that confirmation is the decision.
4. Tell the CEO in one line who can now read it.

## Make it ordinary again

Remove its row (again the CEO confirms).

## When you hit a private file

If a task needs a file you can't open, don't look for another way to read it: tell whoever asked which file it is and that it's private, and ask the CEO or one of its readers to pass on what the task needs.

**Searching around it:** a search that prints lines from a folder holding a private file is stopped, and the message says how to leave the file out. Listing file names (`grep -l`) isn't.

**Limit to know:** this is a guardrail, not isolation. The hook reads the text of each call; it can't follow scripts, interpreters or every shell construction, and a tenant-wide SharePoint search can still show a line. Git history keeps earlier versions. What must never be seen by others belongs outside the repo.
