---
name: start-collaborator
description: "Start a collaborator in its own background session, which the CEO can open from the agent view and talk to directly. Use when the CEO says 'start an agent for…', when work is long enough to run alongside the conversation, or when the CEO may want to join it. Not for quick reviews: those are subagents."
---

# Start a collaborator session

A collaborator session is a full Claude Code session in the background, in this repo, with the same hard limits. The CEO reaches it from the agent view (`←` on an empty prompt, then `Enter` on its name) and talks to it; `←` brings them back to you.

1. **Name it** so the CEO recognises it in the list: a short topic in lowercase with hyphens, e.g. `social-campaign`, `frontend-project-x`, `legal-ferrolino`. Check with `ListAgents` that the name is free.
2. **Pick the agent.** For legal, finance or ethics work the CEO wants to discuss, run the dedicated agent as the session's main agent (`--agent legal`). For everything else, no `--agent`.
3. **Write the brief** to `state/briefs/<name>.md`:

```
# <name>

Started by <CoS name> for <CEO name>, <YYYY-MM-DD>.

## Goal
<what the CEO wants, in their words where possible>

## Material
<files, links, facts from memory/>

## Constraints
<manifesto points that matter here, deadlines, what not to do>

## Done means
<the deliverable and where to save it, e.g. drafts/<name>.md>

## Talking to the CEO
The CEO may open this session and talk to you directly. Their word overrides this brief.
When you finish, say so in one line, then stop and wait.
```

4. **Start it** (one Bash command):
   `claude --bg --name <name> [--agent <id>] "You are a collaborator session named <name>, not the Chief of Staff. Read state/briefs/<name>.md and do the work it describes."`
   If it fails with `Workspace not trusted`, tell the CEO to run `claude` once in this repo and accept the trust prompt, then retry.
5. **Ask to be told when it's done**: with `SendMessage` to `<name>` and `notify_when_idle`, without a message.
6. **Tell the CEO** in one line: the name, what it's doing, and how to reach it ("press `←`, then `Enter` on *<name>*").
7. **When it's done**, read its deliverable, tell the CEO what's ready, and note it for wrap-up. If the session asks you something through a message, answer only within what the CEO already decided; route anything else to the CEO.

Each session uses the CEO's plan quota like a normal conversation: don't start more than the work needs.
