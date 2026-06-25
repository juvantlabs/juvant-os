# ADR 0024 — Outbound action queue (**outbox**): one durable queue for side-effecting MCP operations

## Status

Proposed (2026-06-25). The architectural core (single canonical outbox table;
approval inside the queue; per-operation activation via a rubric; drain by a
scheduled helper) is ratified by the CEO. Schema, the `Adding a new MCP server`
rubric, and the drain helper are deferred and tracked in **ARCH-014**
(`juvantlabs/juvant-os-pm`).

## Context

A standing invariant: **agents draft, they never execute autonomously; the CEO
commits via CoS.** Today that draft → commit happens *in-conversation* and is
**ephemeral** — there is no durable, auditable record of "what is staged and
awaiting commit".

Several outbound operations to external systems (reached via MCP servers) need
more than a fire-and-return call. They need *staging*:

- **accumulation / batch** — items accrue before a batched send (e.g. invoices
  collected before the Aruba submission window);
- **approval gate** — the CEO must approve before any external effect (the
  default for anything touching money, legal, or public visibility);
- **throttle / quota** — an external rate limit or plan cap (e.g. a free social
  scheduler capped at ~10 queued posts per channel);
- **retry / durability** — a send can fail and the *intent* must survive;
- **scheduling** — the send must occur at a specific future time (scheduled
  posts, a payment on its due date).

The schema already has **half** of this pattern:

- `inbound_queue` (FEAT-015) — external event → Turso → agent reads. The
  **inbound** half.
- `adapter_dead_letters` — `adapter IN ('m365-mail','bank','fiscal')`, a single
  `payload TEXT`, `retry_count`, `last_retry`. A **partial outbound** primitive:
  only the *failure* branch (what to retry after a push fails).

What is missing is the **happy-path outbound staging** — the queue an item sits
in *before* and *during* dispatch, not only after it fails.

A concrete trigger exposed the mis-modeling: a CEO-approval gate for batched
social posts was first built as a spreadsheet, then "upgraded" to a SharePoint
List for typed status + audit + views. But *typed status + audit trail + views =
a database table* — and the company already has a database (Turso), where
`decisions` and `security_audit_log` already live. The List was a **third copy**
of state that already had two legitimate homes (the posts in the scheduler, the
decision in Turso), and it re-opened the provider-coupling problem (a Google
adopter has no List). The lesson generalizes: **operational / transactional state
belongs in the company DB, not in doc-storage** (the 4-way taxonomy in ADR 0023:
document → space; canon/skill/code → repo; **operational state → company DB**;
regenerable → nothing).

## Decision

1. **One canonical `outbox` table** — *not* a `<domain>_queue` per MCP. It is the
   durable, auditable materialization of the existing `draft → approve → execute`
   invariant. Heterogeneous operations share it via a `target_mcp` / `operation`
   discriminator plus a JSON `payload` — exactly the shape `adapter_dead_letters`
   already uses (one `payload TEXT` across all adapters).

2. **Status lifecycle:** `draft → approved → sent → failed`. The `failed`
   terminal feeds the existing dead-letter retry semantics.

3. **Approval lives inside the queue.** The CEO commit (via CoS) sets
   `status='approved'` + `approved_by`. The outbox **is** the register of "what
   awaits the CEO commit" — no separate approval store. Autonomous external effect
   on a row that is not `approved` is forbidden.

4. **Per-operation, not per-MCP.** An MCP server does not get a queue; a
   *side-effecting operation* enters the outbox when the **rubric** fires —
   *any* of: accumulation, approval gate, throttle/quota, retry/durability,
   scheduling. Read-only operations and genuinely fire-and-forget low-stakes calls
   bypass the outbox with a direct MCP call. This is why "every MCP creates a
   `*_queue`" is the wrong unit: the unit is the *action*, and most MCPs have zero
   or one action that qualifies.

5. **Activation is a guideline, not a mandate.** The decision rubric lives in
   `docs/MCP_INVENTORY.md` § "Adding a new MCP server": when an MCP is added, each
   side-effecting operation is evaluated against the rubric; if it fires, the
   operation routes through the shared `outbox` — no new table is created.

6. **The drain worker is a scheduled helper** — the inverse of the FEAT-007
   inbound-population helpers. It picks the next `approved` row, checks
   quota/slot/`scheduled_for`, calls the MCP, and marks `sent` or `failed`
   (+retry). Written **once**, reused across every domain (social, invoicing,
   banking, …). The free-plan cap (e.g. ~10/channel) is enforced by the drain
   throttle, not by the size of the store — the outbox holds the full backlog;
   only the ≤cap live items reach the external system.

7. **§4 disclosure boundary is preserved.** The drain worker is a helper, not an
   agent holding `[state.db read + external-channel send]` in one
   `agent_tool_matrix` row — so it does not collapse the disclosure boundary
   (MCP_INVENTORY § Universal Boundaries). The CEO commit is the gate.

### Schema sketch (final shape in ARCH-014)

```
outbox(
  id            INTEGER PK AUTOINCREMENT,
  scope         TEXT NOT NULL,         -- company | <project-slug>
  target_mcp    TEXT NOT NULL,         -- e.g. the social / invoicing / bank server
  operation     TEXT NOT NULL,         -- e.g. 'publish' | 'submit-invoice'
  payload       TEXT NOT NULL,         -- JSON, op-specific
  status        TEXT DEFAULT 'draft',  -- draft | approved | sent | failed
  created_by    TEXT NOT NULL,         -- drafting agent
  approved_by   TEXT,                  -- set on CEO commit via CoS
  scheduled_for DATETIME,              -- NULL = send asap (subject to throttle)
  retry_count   INTEGER DEFAULT 0,
  created_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
  approved_at   DATETIME,
  sent_at       DATETIME
);
```

## Consequences

**Positive**
- The drain worker, approval surface, audit trail, and retry are written **once**
  and reused — no N divergent ad-hoc per-domain queues.
- `draft → approve → execute` becomes **persistent and auditable** instead of
  ephemeral conversation state.
- Provider/plan caps (the social free-tier limit, API rate limits) are handled by
  the drain throttle; the backlog is unbounded in the DB.
- Reuses the existing dead-letter retry semantics for the `failed` branch.

**Negative / trade-offs**
- Heterogeneous payloads share one table — mitigated by the JSON `payload`,
  exactly as `adapter_dead_letters` already does.
- One always-present table even when empty — but it is **one** table per instance,
  not one per MCP, so there is no per-server clutter (the anti-pattern that
  "mandate a queue per MCP" would create).
- Requires drain-scheduling infrastructure (a helper on a timer) — reuses the
  FEAT-007 helper mechanism rather than introducing a new one.

## Implementation

Deferred to **ARCH-014**. Expected work:
- `scripts/schema.sql` — add the `outbox` table.
- `docs/MCP_INVENTORY.md` § "Adding a new MCP server" — add the activation rubric.
- A drain helper under `helpers/` (FEAT-007 pattern, inverted).
- First consumer: the social-scheduler approval flow (the trigger that motivated
  this ADR). Invoice→Aruba and bank dispatch are noted as future consumers of the
  **same** table, not new tables.

## References

- `scripts/schema.sql` — `inbound_queue` (FEAT-015) and `adapter_dead_letters`
  (the existing inbound half and partial-outbound primitive this ADR completes).
- FEAT-007 — scheduled helpers that populate Turso queues (the drain worker is the
  inverse).
- `SYSTEM_INVARIANTS.md` §4 — single-writer-per-scope + disclosure boundary.
- `docs/MCP_INVENTORY.md` § Universal Boundaries, § "Adding a new MCP server".
- [ADR 0023](0023-document-spaces-third-party-access.md) — sibling: the 4-way
  taxonomy that places operational/transactional state in the company DB (this
  outbox), not in doc-storage.
