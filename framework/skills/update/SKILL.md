---
name: update
description: "Update juvant-os in this company repo to a newer version. Use when the CEO asks to update juvant-os or the framework, or names a version tag."
---

# Update juvant-os

1. Read the installed version in `.claude/juvant-os.json`.
2. Ask the CEO which version to install if they didn't say, and show what changed: the release notes on GitHub (`https://github.com/juvantlabs/juvant-os/releases` or the CHANGELOG at that tag).
3. Run `bash .claude/skills/update/update.sh <tag>`. It replaces only framework files under `.claude/` (agents, hooks, skills, dashboard). It never touches `CLAUDE.md`, `manifesto.md`, `roles/`, `memory/`, `state/` or `.claude/settings.json`.
4. Show the CEO `git diff --stat` and anything that looks surprising, especially changes to `.claude/hooks/`: they are the hard limits.
5. Commit only with the CEO's ok: `git add .claude && git commit -m "Update juvant-os to <tag>"`.
6. If the release notes ask for changes to the company's own files (for example a new permission rule in `.claude/settings.json`), propose them as a separate change. Writes to `.claude/` ask the CEO.

If the script refuses because `.juvant/` exists, this is a juvant-os v1 instance: stop and tell the CEO.
