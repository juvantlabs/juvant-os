---
name: update
description: "Update juvant-os in this company repo to a newer official release. Use when the CEO asks to update juvant-os or the framework, asks whether there's an update, or names a release."
---

# Update juvant-os

juvant-os installs **only official GitHub releases** (`https://github.com/juvantlabs/juvant-os/releases`), never a branch or `main`. If no release is newer than the installed one, there is nothing to update: say so and stop. Don't look for another way (a clone, a branch, a local folder).

1. Read the installed version in `.claude/juvant-os.json`, and the latest release on the releases page.
2. If there's a newer release, show the CEO its release notes. The latest is the default; a pre-release only if the CEO names it.
3. Run `bash .claude/skills/update/update.sh` (latest release) or `bash .claude/skills/update/update.sh <tag>` (that release). It replaces only framework files under `.claude/` (agents, hooks, skills, dashboard). It never touches `CLAUDE.md`, `manifesto.md`, `roles/`, `memory/`, `state/` or `.claude/settings.json`.
4. Show the CEO `git diff --stat` and anything that looks surprising, especially changes to `.claude/hooks/`: they are the hard limits.
5. Commit only with the CEO's ok: `git add .claude && git commit -m "Update juvant-os to <tag>"`.
6. If the release notes ask for changes to the company's own files (for example a new permission rule in `.claude/settings.json`), propose them as a separate change. Writes to `.claude/` ask the CEO.

If the script refuses because `.juvant/` exists, this is a juvant-os v1 instance: stop and tell the CEO.
