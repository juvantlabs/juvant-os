# Integration: inbound mail → CFO draft → CEO approval → reply

End-to-end exercise of the consult-draft-approve-send loop, the most
common operating cycle in Juvant OS. Touches: mail adapter, CFO subagent,
`decisions` row, CoS proxying, Teams Approval card, and the audit log.

## Prerequisites

- [ ] Company bootstrapped (CFO manifesto in `operational_restricted` minimum).
- [ ] `counterparties`, `counterparty_routing`, `counterparty_contacts`
  rows exist for at least one accountant counterparty (e.g.
  `commercialista-rossi`).
- [ ] `disclosure_policies` reachable.
- [ ] `m365-mail` adapter configured (or whichever mail adapter is
  active; Telegram/Teams stub is acceptable for the simulation).
- [ ] At least one Teams Approval card webhook is configured under
  `.juvant/config.json` → `teams_webhooks.approvals`.

## Steps

1. **Trigger.** Send (or simulate) an inbound mail from the configured
   accountant counterparty to the CFO mailbox, asking for a list of
   issued invoices for the last quarter.

2. **Verify the inbound queue.** `inbound_queue` should contain a row
   with `agent_owner='cfo'`, `confidence='whitelisted'`, and
   `status='pending'`.

   ```sql
   SELECT id, content, confidence, status FROM inbound_queue
    WHERE agent_owner='cfo' ORDER BY created_at DESC LIMIT 1;
   ```

3. **Drive the CFO turn.** From a Claude Code session, prompt the CFO
   subagent to process its pending inbound queue. The CFO must:

   - Read `counterparty_history` for the sender.
   - Read `disclosure_policies` for the disclosure level.
   - Compose a draft reply.
   - Insert a `decisions` row category `eng-output-held` (CFO does not
     send; see SYSTEM_INVARIANTS.md §3 Tier 4 routing analog).
   - Surface the draft to CoS via `messages` (`type='deliverable'`,
     `priority='normal'` or `'high'`, `notify_ceo=1`).

4. **Verify CoS surfacing.** The CoS message queue should contain the
   draft as a `messages` row addressed to `cos`. CoS posts a Teams
   Approval card on the `Approvals` channel containing the draft, the
   counterparty identity, and the disclosure level.

   ```sql
   SELECT id, from_agent, content, priority FROM messages
    WHERE to_agent='cos' AND notify_ceo=1
    ORDER BY created_at DESC LIMIT 1;
   ```

5. **Approve.** As CEO, click "Approve" on the Teams card. CoS records
   `approved_by='ceo'`, `approved_at=NOW` on the original `decisions`
   row, and dispatches the reply via the project COO (single-writer
   §4) — or directly via the mail adapter if no COO is in the loop.

6. **Verify the send.** The mail adapter logs the outbound message.
   `agent_actions_log` shows a `Bash` (or tool=`mail`) row tied to the
   COO's send. `decisions` row status updates to `executed`.

7. **No unauthorized side effects.** Confirm:
   - No outbound message was sent before the CEO clicked Approve.
   - No row in `messages` carries CONFIDENTIAL content (per
     SYSTEM_INVARIANTS.md §5).
   - The `agent_actions_log` row count for this run matches the number
     of distinct tool calls observed.

## Pass criteria

- [ ] Step 2 row exists with status=`pending`.
- [ ] Step 3 produces a `decisions` row + `messages` row to CoS.
- [ ] Step 4 Teams card visible on `Approvals` channel.
- [ ] Step 5 records CEO approval; reply dispatched.
- [ ] Step 6 `agent_actions_log` complete; `decisions.status='executed'`.
- [ ] Step 7 confirms no auto-send and no confidential leak.

## On failure

Capture the offending row (or its absence) and file a `decisions`
category `integration-test-failure` with the scenario name, the failing
step number, and the expected vs observed state. Block any further v1.0
release work until the cause is understood.
