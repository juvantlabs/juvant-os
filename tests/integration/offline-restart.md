# Integration: agent offline → queued → restart → processed

Exercise the offline-tolerance contract: when an agent (or the whole
Mac) is offline, inbound counterparty messages must queue durably, and
on restart the right agent must pick them up in order. Touches:
`portal_offline_messages`, `inbound_queue`, SessionStart hook,
`session-start.sh`-driven boot processing.

## Prerequisites

- [ ] Company bootstrapped.
- [ ] At least one external-facing agent (CFO, CMO, or CCO) in
  `operational_restricted`+ status.
- [ ] At least one counterparty configured with routing to that agent
  (`counterparty_routing.agent_owner` matches).
- [ ] Portal or mail adapter configured to deposit inbound messages
  into `portal_offline_messages` when the agent is unreachable.

## Steps

1. **Take the agent offline.** Either (a) close the Claude Code
   session for that agent (the `SessionEnd` hook flips
   `agents.status='inactive'`), or (b) directly mark
   `agents.status='inactive'` for the role under test:

   ```sql
   UPDATE agents SET status='inactive' WHERE role='cfo';
   ```

2. **Generate an inbound while offline.** Send a counterparty message
   to that agent (mail / portal / simulated). Verify it lands in
   `portal_offline_messages` (or a vendor-equivalent queue) with
   `status='pending'`:

   ```sql
   SELECT id, agent, counterparty, status, created_at
     FROM portal_offline_messages
    WHERE agent='cfo' AND status='pending'
    ORDER BY created_at DESC LIMIT 5;
   ```

3. **Send a second inbound.** While still offline, generate a second
   message from the same counterparty. Both rows must coexist with
   `status='pending'` and the original timestamps preserved (no
   reordering).

4. **Bring the agent online.** Open a new Claude Code session for the
   agent. The `SessionStart` hook flips `agents.status='active'`.

5. **First post-restart turn.** Prompt the agent to "process pending
   inbound queue" (or invoke the agent's Session Start Protocol per
   its `agents/<scope>/<role>.md`). The agent must:

   - Read `portal_offline_messages WHERE agent=<role> AND status='pending' ORDER BY created_at ASC`.
   - Process each row in order (oldest first).
   - For each, update `status='processed'`, `processed_at=NOW`.
   - Mirror to `inbound_queue` if vendor adapter dictates.
   - Produce drafts as appropriate (which then routes through the
     consult-draft-approve loop — see `mail-inbound-cfo-draft.md`).

6. **Verify ordering and completeness.** All `portal_offline_messages`
   rows for this agent that were `pending` before restart are now
   `processed`. No row was skipped, no row was processed twice.

   ```sql
   SELECT COUNT(*) AS still_pending
     FROM portal_offline_messages
    WHERE agent='cfo' AND status='pending'
      AND created_at < (SELECT MAX(created_at) FROM session_snapshots WHERE agent='cfo');
   -- Expected: 0
   ```

## Pass criteria

- [ ] Step 2 + 3 rows present, both `status='pending'`, ordered by
  `created_at`.
- [ ] Step 4 `agents.status='active'` after restart.
- [ ] Step 5 processes both rows in order; each transitions to
  `status='processed'` with `processed_at` set.
- [ ] No `inbound_queue` row created without a corresponding
  `portal_offline_messages` source.
- [ ] No CONFIDENTIAL string leaks into any external-facing draft.

## On failure

If queued rows do not appear during offline period → debug the portal
or mail adapter writing path. If rows remain `pending` after the
post-restart prompt → debug the agent's Session Start Protocol read
of `portal_offline_messages`. File a `decisions` category
`integration-test-failure` per the scenario.
