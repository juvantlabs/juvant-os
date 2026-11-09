---
name: project-repo
description: "Give a project's repository the company's hard limits and manifesto, or change who outside the company reads it. Use when the CEO links a repository to a project, says a repository is now shared with someone (partners, clients, co-founders) or no longer is, or asks how a project repository is set up."
---

# Project repositories

A project's memory lives in the company repo (`memory/projects/<slug>/`); its documents and code live in its own repositories. This skill sets those repositories up and keeps track of who reads them. The CEO never needs to run it by hand: they tell you, you run it, they confirm (writing to a repository's `.claude/` always asks the CEO).

All commands run from the company repo:

| The CEO says | You run |
|---|---|
| "Link `<repo>` to project `<slug>`" | `bash .claude/skills/project-repo/project-repo.sh install <repo> --project <slug>` |
| …and people outside the company read it | add `--shared-with "<who, in the CEO's words>"` |
| "`<repo>` is now shared with `<who>`" / "they now read it too" | `bash .claude/skills/project-repo/project-repo.sh sharing <repo> "<who>"` |
| "`<repo>` is internal again" | `bash .claude/skills/project-repo/project-repo.sh sharing <repo> none` |
| "How is `<repo>` set up?" | `bash .claude/skills/project-repo/project-repo.sh status <repo>` |

`<repo>` is the local path of the repository's checkout. If it isn't checked out on this machine, ask the CEO where it is, or to clone it.

After each change:

1. Update **Repositories and audience** in the project card (`memory/projects/<slug>/README.md`).
2. Tell the CEO what changed in one line, and that the change in the repository is not committed: commit it there on a branch with a draft PR if the repository is shared.
3. If `install` stops because the repository already has `.claude/settings.json` or `.claude/CLAUDE.md`, show the CEO what's there and propose a merge by hand.

**What "shared" changes** in that repository: pushing to the default branch, merging pull requests and opening non-draft pull requests are blocked; sessions there are told who reads it and never copy the company's memory into it. "Shared with" is the CEO's statement of who reads it, not a list of accounts: the session-start check warns when GitHub shows outside collaborators on a repository that isn't marked shared.
