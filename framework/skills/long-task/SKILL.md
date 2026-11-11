---
name: long-task
description: "Run a long task unattended (overnight, while the CEO is away) under an authorization the CEO approves once, at the start. Use when the CEO says 'long task' or asks for something big to run while they're away, and propose it when a request is long (every invoice, a whole folder, a big batch) or the CEO says they're leaving. Not for work the CEO will follow live: that's a plain collaborator session."
---

# Long task

Some work needs actions that normally ask the CEO each time (overwriting, deleting, moving documents or mail), and the CEO won't be there to answer. A confirmation prompt blocks a session until someone answers, so the task would stop at the first one. Instead, the CEO approves an **authorization** once, before leaving: which actions, where, how many, until when. Inside it, the agent's judgment replaces the CEO's confirmation. It doesn't switch judgment off.

Creating things never needs an authorization: uploads with the conflict behaviour set to `fail` or `rename`, new folders and copies don't ask. Many long tasks need nothing more. Check that first.

**Never authorizable:** money, outbound (sending, sharing, publishing), secrets, force pushes, merges and non-draft PRs on shared repositories. Those stay denied.

## 1. Propose (Chief of Staff)

When the CEO asks, or when you notice a long request, propose the task in a few lines and wait for an ok. A proposal is only a proposal: the CEO decides.
- the goal, and the plan in three or four steps;
- what it will create (no authorization needed);
- what it needs authorized, if anything: which actions (`overwrite`, `delete-move`), where (the exact drive, folder or mailbox), how many at most, for how long (12 hours unless the CEO says otherwise, 24 at most), and which subagents need it;
- what the agent will set aside for the CEO instead of doing.

## 2. Start it as a collaborator session (Chief of Staff)

Long tasks run by default in a collaborator session, so the CEO keeps working with you. Use the `start-collaborator` skill. In the brief, add these two sections:

```
## Long task
This runs unattended. First write the authorization below with the Write tool, exactly as drafted, before anything else.
The CEO confirms it in this session: that confirmation activates it. If it's declined, do only what needs no confirmation.
Keep a log in state/long-tasks/<name>.md: one line per action that used the authorization, with the reason, and one line per item set aside, with why.

## Authorization
<the full file content, see below>
```

Then tell the CEO: "open *<name>* (`←`, then `Enter`) and confirm the authorization before you go."

## 3. The authorization file

`memory/authorizations/<YYYY-MM-DD>-<name>.md`:

```
---
status: active
actions: overwrite, delete-move
scope_drive_id: <exact id>
scope_parent_item_id|expected_parent_id: <exact folder id>
tools: upload|update_file
max: 200
expires: 2026-11-12T08:00:00Z
agents: finance
---
# <name>

Goal: <one or two lines>.
Set aside when in doubt: <what the CEO wants to see first>.
```

- `actions`: the hard-limit rule ids that would otherwise ask (`overwrite`, `delete-move`). Nothing else can be authorized.
- `scope_<argument>`: the tool arguments that must have exactly this value, comma-separated if several are allowed. At least one is required: an authorization says where, or it covers nothing. Use the ids the tools take (drive, folder, mailbox folder), not names. Argument names compare exactly, ignoring case and punctuation (`driveId` = `drive_id`, but `parent_id` is not `target_parent_id`).
  - `scope_a|b`: one thing that tools name differently. The folder is `parent_item_id` for an upload and `expected_parent_id` for a delete or move. The call must carry one of them, with an allowed value.
  - **One folder for moves and deletes** (m365-graph 0.8.0 or later): pass `expected_parent_id` with the folder's id on every `delete_file` (both calls) and `move_file`. The server refuses if the item isn't really in that folder, so the scope above holds. Without it, the call isn't covered and asks.
  - **The claude.ai Microsoft 365 connector** has no such argument, so moves and deletes there can only be scoped to a drive, or to a list of item ids (`scope_itemId: id1, id2`). Keep `max` small.
- `tools` (optional): narrows it to tool names matching this pattern.
- `max`: how many authorized calls at most. Past it, a call the authorization would otherwise cover is **denied**, not asked: set the item aside and carry on. Count calls, not files: some servers take two calls for one action (with m365-graph a delete is a preview that returns a token, then the confirmation with that token).
- `expires`: UTC. It never counts for more than 24 hours after the CEO approved it. Past it, calls it would cover are denied too, until it's closed.
- `agents` (optional): the subagents of this session it also covers. The session itself is always covered; other sessions never are.

The hooks count each use and log it. Any change to the file after the CEO approved it ends it; a new version needs the CEO again.

## 4. Work (collaborator session)

Before each action that uses the authorization, ask yourself whether it makes sense for the goal. Is it really what the task is about (an invoice, not a payslip)? Is it a duplicate? Is it unusual in size, sender, date or name? Would it overwrite something that looks newer or edited by a person?
- If the doubt is real, **don't act**. Note it in your log and in "Waiting for the CEO", then carry on with the rest.
- You may be stricter than the authorization, never wider. If you need more than it allows, set it aside; don't ask mid-task, nobody is there.
- If something blocks you (a denial, a prompt you can't avoid), stop calling that tool, note it, and finish what you can.

## 5. Close

When the work is done, or you stop:
1. Close the authorization: `python3 .claude/hooks/juvant_hooks.py close-authorization memory/authorizations/<file>.md "<one-line outcome>"`.
2. Report as the brief says: what was done (counts), what was set aside and why, where the log is. The Chief of Staff carries the summary and the set-aside items into the journal ("Waiting for the CEO") at wrap-up.

Closing never needs the CEO. Widening an authorization always does: write a new one and let the CEO confirm it.
