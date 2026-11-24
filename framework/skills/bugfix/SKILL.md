---
name: bugfix
description: "Send a fix for a juvant-os framework defect upstream as a draft pull request (or a private security report), so it ships in the next release. Use when a framework file under .claude/ (a hook, a skill, an agent, the dashboard, the update script) misbehaves, blocks legitimate work, or has a bug: not for company content, which you fix here directly."
---

# Send a framework fix upstream

The framework under `.claude/` is installed by `update` and overwritten by the next one, so a local edit is lost (and the hooks ask before any write there). A framework defect is fixed **upstream**, in the public juvant-os repository. When the fix is released, `update` brings it here.

**What is a framework defect?** Something wrong in a file juvant-os installs: a hook that blocks what it shouldn't, a skill that can't do what it says, a script that breaks. Company content (CLAUDE.md, the manifesto, role cards, memory) is yours: fix it here.

## 1. Classify

- **Security weakness** (a hard limit that can be bypassed, a path that leaks private files or secrets): **never a public PR or issue**. Draft a private report for the CEO. Use GitHub's private vulnerability reporting on juvantlabs/juvant-os: title, what can happen, how to reproduce in generic terms, a proposed fix. With the CEO's ok, send it:

  `gh api -X POST repos/juvantlabs/juvant-os/security-advisories/reports -f summary="<title>" -f description="$(cat <file>)"`

  Then stop here.
- **Anything else:** go on.

## 2. Fix it in a clean clone

1. `python3 .claude/skills/bugfix/bugfix.py prepare` clones juvant-os into a temp folder and prints the folder and the base branch.
2. In that clone: `git checkout -b fix/<short-slug>`. Change `framework/` (the source of what is installed here: `framework/hooks/` → `.claude/hooks/`, `framework/skills/` → `.claude/skills/`, …). Add or extend a test in `tests/` that fails without the fix. A new framework file goes in `framework/FILES`.
3. Run `bash tests/run.sh` in the clone and make it pass. If you changed the example's framework files, run `bash tests/sync-example.sh` too.
4. Commit with a message that says what was wrong and why the fix is right.

## 3. Make it generic

The juvant-os repository is public: everyone reads the PR. Write as for a reader outside the company: describe the defect and its effect ("the dashboard skill can't publish under the default limits"), never the company, people, clients, documents or numbers that led you to it.

Write the PR text to a file (what was wrong, how it showed up in generic terms, what the fix does, how it's tested). Then:

`python3 .claude/skills/bugfix/bugfix.py check <clone> --body <pr-text-file>`

It checks the change, the commit messages and the PR text for the company's name, the CEO's and the agents' names, this machine's user and home path, the company's GitHub owner and secret-shaped text. Add `--term <word>` for other names that must not leave (a client, a project). Rewrite until it's clean.

## 4. The CEO sends it

Show the CEO the diff (`git -C <clone> diff origin/<base>`) and the PR text. Opening a PR on juvant-os is outbound: the hook asks, and the CEO's confirmation is the send.

- If the CEO can push to juvantlabs/juvant-os (`gh api repos/juvantlabs/juvant-os --jq .permissions.push` says `true`): `git -C <clone> push -u origin fix/<slug>`.
- Otherwise: `cd <clone> && gh repo fork --remote` first, then push the branch to the fork.

Then, from the clone: `gh pr create --draft --base <base> --label adopter-fix --title "<what it fixes>" --body-file <pr-text-file>`. If the label doesn't exist on a fork's PR, leave it out and write "adopter-fix" in the first line of the body.

## 5. After

- Record it in today's journal with the PR link, and in one line tell the CEO what was sent.
- The maintainers review and release it. When a release that includes it is out, `update` brings it here (the update skill). Until then, if the defect blocks work, tell the CEO the workaround, and never edit `.claude/` to patch it locally.
- Delete the temp clone when the PR is merged.
