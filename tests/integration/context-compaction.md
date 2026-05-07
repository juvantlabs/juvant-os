# Integration: PreCompact → snapshot → PostCompact → continuity

Exercise of context compaction — the mechanism that keeps an agent
operating across long sessions without losing structured state.
Touches: `pre-compact.sh`, `session_snapshots`, `post-compact.sh`, agent
state recovery.

## Prerequisites

- [ ] At least one company-scope agent in `operational_restricted` or
  `operational` (CoS recommended — it has the most structured state).
- [ ] An active Claude Code session for that agent.
- [ ] The session has accumulated enough context to make compaction
  meaningful (e.g. >10 messages exchanged with structured outputs).

## Steps

1. **Snapshot baseline.** Before triggering compaction, capture the
   agent's current view:

   ```sql
   SELECT id, agent, key_observations FROM session_snapshots
    WHERE agent='cos' ORDER BY created_at DESC LIMIT 1;
   ```

   Note the latest `id`. Call it `BASELINE_ID`.

2. **Trigger compaction.** From the Claude Code session, invoke
   `/compact` (Claude Code built-in) or wait until automatic compaction
   fires.

3. **Verify PreCompact wrote a snapshot.** A new row in
   `session_snapshots` with `agent='cos'` and `created_at` later than
   `BASELINE_ID` must be present. The snapshot payload should include
   the agent's structured state per `agents/company/cos.md` § Context
   Awareness — PreCompact (specs in flight, drift findings, module
   catalog state, etc.).

   ```sql
   SELECT id, created_at, length(snapshot) FROM session_snapshots
    WHERE agent='cos' AND id > BASELINE_ID;
   ```

4. **Verify PostCompact reload.** After compaction completes, the next
   agent turn must reference state from the snapshot — visible in the
   first response after compaction. Confirm by asking the agent a
   question whose answer requires the pre-compact context (e.g. "what
   was the topic of the last decision you escalated?").

5. **No structural loss.** Compare the agent's pre-compact and
   post-compact understanding of:
   - In-flight `decisions` rows (count and ids).
   - Pending `messages` to/from the agent.
   - Latest `agents.session_id` pointing to a resumable session.

## Pass criteria

- [ ] New snapshot row written by PreCompact.
- [ ] Snapshot payload contains the agent's canonical structured fields.
- [ ] First post-compact turn answers a question that required the
  pre-compact context, demonstrating successful reload.
- [ ] No drop in count of in-flight `decisions` or `messages`.
- [ ] `agents.session_id` updated to the new session id.

## On failure

If the snapshot is missing → debug `hooks/pre-compact.sh` (likely
Turso write failure or stdin parse error). If the post-compact turn
hallucinates state → debug `hooks/post-compact.sh` SELECT path. File a
`decisions` category `integration-test-failure` per the scenario.
