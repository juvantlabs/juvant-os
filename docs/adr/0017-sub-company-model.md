# ADR 0017 — Sub-company model: master/sub topology with global-scoped decisions

**Status**: Proposed  
**Date**: 2026-05-16  
**Deciders**: CEO (Antonio Gatti)

---

## Context

A single Juvant OS instance maps 1:1 to a legal entity or operational unit.
When one entity governs another (e.g. a holding company and its subsidiaries,
or an OSS maintainer org and the commercial entity that funds it), running
two fully independent instances creates sync overhead for decisions that are
genuinely shared (architectural standards, security posture, infra choices).

The naive alternative — sharing agents across instances — creates tight
coupling and makes physical separation impossible without surgery.

---

## Decision

Introduce a **master / sub / single** topology at the company level.

### Pillar 1 — No shared agents

A sub-company is a **complete** Juvant OS instance: all C-suite and
project agents exist and operate independently. If the sub-company is ever
detached from its master, it becomes a `single` company with no schema
changes — only the `company_type` key in `master_context` changes and the
`master_db_url` / `master_db_token` keys are nulled out.

### Pillar 2 — Global-scoped decisions as the only cross-instance link

The master company may mark certain decisions as `scope='global'`. These are
the canonical cross-entity truths (e.g. "we use Turso for all DBs", "security
baseline is ADR 0004 Track 2"). Sub-company CoS reads the master's
`decisions WHERE scope='global'` at boot — read-only, via a dedicated
read-only token. Sub-companies can only write `scope='company'` decisions.

---

## Schema changes

### `master_context` — three new keys

| key | value | notes |
|---|---|---|
| `company_type` | `'single'` \| `'master'` \| `'sub'` | default `'single'` at init |
| `master_db_url` | libSQL URL or NULL | NULL for single/master |
| `master_db_token` | read-only token or NULL | NULL for single/master; never write-capable |

### `decisions` — one new column

```sql
ALTER TABLE decisions ADD COLUMN scope TEXT DEFAULT 'company';
-- 'company' | 'global'
-- Only master companies may INSERT scope='global' rows.
-- Sub-companies read master's global rows; cannot write them.
```

**Sub-company decisions are always `scope='company'`.** A sub-company
has no authority to produce global decisions — that authority belongs
exclusively to master companies. This is both a governance rule and a
technical invariant:

- The `decisions` table in a sub-company DB will never contain a row
  with `scope='global'`. If a sub-company agent wants a decision to
  become global, it uses the upstream proposal flow (see below).
- Enforcement: `pre-tool-use.sh` deny-list blocks any agent in a
  sub-company instance from writing `scope='global'` to `decisions`
  (pattern: `INSERT.*decisions.*scope.*global` when `company_type=sub`).
- The column default `scope='company'` provides a second layer: even if
  the deny-list were bypassed, omitting the scope field produces a
  company-scoped row, never a global one.

### Disclosure policy alignment

| Company type | Allowed `disclosure_policies.scope` | Can read master global decisions? |
|---|---|---|
| `single` | `company` only | — |
| `master` | `company` or `global` | n/a (is the master) |
| `sub` | `company` only | yes, read-only |

A sub-company's disclosure policies govern only its own agents and
counterparties. Master `global` decisions are surfaced to sub-company agents
as **read-only context** — they cannot be cited in a sub-company disclosure
policy as justification for a `global`-scope action (that would require
promoting to master).

---

## Wizard changes

### Company init (new step, after Step 1 identity)

```
Step 1.5 — Company topology
  Is this company a:
    [1] Single company (default — no master/sub relationship)
    [2] Master company (will have sub-companies reading its global decisions)
    [3] Sub-company (reads global decisions from a master)
```

If **[3]**, the wizard runs a sub-wizard to resolve the master DB connection:

```
Step 1.5a — Master company name
  What is the name (slug) of your master company?
  e.g. "juvant"

  The wizard derives the master URL by extracting org and region from
  the sub-company's own db.url and substituting the master slug:
    own URL:    libsql://company-<own-slug>-<org>.<region>.turso.io
    master URL: libsql://company-<master-slug>-<org>.<region>.turso.io
  This assumes both companies share the same Turso org and region group
  (the common case). Override in step 1.5b if not.

Step 1.5b — Confirm or override DB URL
  Derived URL: libsql://company-<master-slug>-<org>.<region>.turso.io
  Press Enter to confirm, or type a custom URL to override.
  (Override needed when master is on a different Turso org, region, or provider.)

Step 1.5c — Read-only auth token
  Provide the read-only auth token for the master DB.
  (The master company owner generates this via: turso db tokens create
   company-<master-slug> --read-only)
  Token is stored in master_context.master_db_token and never logged.

Step 1.5d — Verify connection
  CoS runs: SELECT value FROM master_context WHERE key='company_type'
  against the master DB with the provided token.
  - If result is 'master': confirmed. Store master_db_url + master_db_token.
  - If result is 'sub': rejected — flat hierarchy violated (max one level).
  - If result is 'single' or unreachable: warn + ask CEO to confirm intent.
```

### Topology transitions (new Skill operations)

#### Detach from master (Sub → Single)

Recognized phrasings: *"Detach from master"*, *"Diventa company singola"*,
*"Staccati dalla master"*.

**Step-by-step flow** (CoS executes, CEO confirms each gate):

1. **Confirm intent** — CoS presents the consequence: "This will permanently
   break the link with the master. Global decisions will no longer be
   available from the next boot. Proceed?"
2. **Knowledge snapshot offer** — CoS asks: *"Do you want to absorb the
   master's current global decisions into your local knowledge base before
   detaching?"*
   - If **yes**: CoS fetches all `decisions WHERE scope='global'` from the
     master DB, then for each row CRO synthesises a `knowledge_base` entry
     (`category='strategic'`, `source_ref='master-global:<decision_id>'`,
     `promoted_by='cos'`). CEO confirms the KB entries before proceeding.
   - If **no**: skip. Global decisions remain accessible only for the
     remainder of the current session.
3. **Sever link** — CoS executes:
   ```sql
   UPDATE master_context SET value='single'  WHERE key='company_type';
   UPDATE master_context SET value=''        WHERE key='master_db_url';
   UPDATE master_context SET value=''        WHERE key='master_db_token';
   ```
4. **Confirm detachment** — CoS reports: "Link severed. This company is now
   single. It can be promoted to master at any time via *'Promote to master
   company'*."

#### Other transitions

Recognized phrasings: *"Promote to master company"*, *"This company is now a
master"*, *"Add a sub-company"*.

- **Single → Master**: set `company_type='master'` in `master_context`.
  No other changes. Future sub-companies can now point to this instance.
- **Single → Sub**: same sub-wizard as company init (steps 1.5a–d above).
  Sets `company_type='sub'`, stores `master_db_url` + `master_db_token`.
- **Sub → Master**: not a valid direct transition. Must detach first
  (Sub → Single via the Detach operation above), then promote (Single → Master).

#### Promote a decision to global (master only)

Recognized phrasings: *"Make decision #X global"*, *"Globalizza la decision
#X"*, *"Promuovi la decision #X a global"*.

Any existing `scope='company'` decision in the master DB can be promoted to
`scope='global'` at any time. The promotion follows the standard
approval gate (CEthO validation + CEO approval) and uses the immutable-row
pattern: a new row is inserted with `scope='global'` and the original row
is superseded (`superseded_by = <new_id>`). Sub-companies will see the new
global row at their next boot.

---

### Upstream proposal — sub to master handoff

A sub-company cannot write to the master DB. When a sub identifies a
decision that should become global, the flow is:

**Step 1 — Sub marks the decision as upstream candidate**

New column on `decisions`:
```sql
ALTER TABLE decisions ADD COLUMN upstream_candidate INTEGER DEFAULT 0;
-- 1 = CEO has flagged this for proposal to master
```

Recognized phrasing (sub-company): *"Mark decision #X for upstream"*,
*"Proponi la decision #X alla master"*.

CoS sets `upstream_candidate=1` on the row and surfaces it in the boot
summary under *"Decisions pending upstream proposal"*.

**Step 2 — Sub generates handoff document**

Recognized phrasing: *"Genera l'upstream proposal per la decision #X"*,
*"Prepare upstream handoff for decision #X"*.

CoS produces a structured text block ready to be sent out-of-band
(email, Teams message) to the master CEO:

```
UPSTREAM PROPOSAL — <sub-company-name>
Decision ID : <id> (local to <sub-slug> DB — not portable)
Date        : <created_at>
Proposed by : <agent>

Title       : <title>
Category    : <category>
Rationale   : <rationale>

Why global  : <one sentence — why this should apply across all sub-companies>
```

**Step 3 — Master CEO receives and acts**

The master CEO reads the proposal out-of-band and decides independently.
If approved, the master CEO tells the master CoS:
*"Crea global decision da questo upstream proposal"*.

CoS creates a new `decisions` row in the master DB:
- `scope='global'`
- `rationale` = original rationale + *"Upstream proposal from <sub-slug>
  decision #<original-id>"*
- `source_ref` = `upstream:<sub-slug>:<original-id>`

Standard CEthO + CEO approval gate applies before the row is activated.

**Step 4 — Sub clears the candidate flag**

Once the master global decision is live, the sub-company CEO clears the
flag: *"Clear upstream candidate on decision #X"*. CoS sets
`upstream_candidate=0`. The sub will read the new global decision at the
next boot.

### Flat hierarchy invariant

**The topology is strictly one level deep.** A master company may have
sub-companies; those sub-companies may not themselves have sub-companies
while remaining subs. Concretely:

- A `sub` instance cannot set `master_db_url` pointing to another `sub`.
  The wizard and the promotion Skill operation both validate that the target
  `company_type` in the pointed-to DB is `master` — if it is `sub` or
  `single`, the operation is rejected with an explicit error.
- There is no grandparent, no chain, no DAG. Depth = 1 max.

**Consequence of promoting a sub to master**: the moment a sub-company
transitions to `single` or `master`, the link to its former master is
severed. The former master's `decisions WHERE scope='global'` are no longer
fetched. There is no cascading re-link. If the now-master wants to expose
its own global decisions to new sub-companies, it does so from scratch.

---

## Single point of connection invariant

**The master DB (via `master_db_url` + `master_db_token`) is the only link
between master and sub-company.** Every other integration is configured
independently on each instance:

| Integration | Master | Sub-company |
|---|---|---|
| GitHub org / repos | own | own — separate org or repos |
| M365 tenant / SharePoint | own | own — separate tenant or shared with independent credentials |
| Turso project DBs | own | own |
| MCP servers (ms-graph, bank, etc.) | own config | own config |
| Webhook endpoints | own | own |
| `.juvant/config.json` | own | own — no inheritance from master |

There is no credential sharing, no config inheritance, no MCP server
delegation. A sub-company that appears to "use the same GitHub org" as its
master does so because a human configured it that way — not because the
framework links the two. This is intentional: it keeps the detachment
clean (severing `master_db_url` truly severs the only programmatic link)
and avoids cross-instance privilege escalation.

---

## Boot sequence impact (sub-company only)

After step 4 (read pending state), CoS adds:

```
4b. If company_type='sub': read master_db global decisions
    SELECT id, agent, title, category, rationale, created_at
    FROM decisions
    WHERE scope='global'
      AND superseded_by IS NULL      -- active rows only; skip superseded
    ORDER BY created_at DESC
    -- executed against master_db_url with master_db_token (read-only)
```

These are surfaced in the boot summary under a distinct **"Global decisions
(from master)"** section. They are informational — sub-company agents do not
act on them without explicit CEO instruction.

If the master DB is **unreachable** (token expired, network, outage): boot
proceeds with a warning — *"Master DB unavailable — global decisions not
loaded this session."* The sub-company operates on its own decisions only.
This is a degraded but valid state; it must not block boot.

**Token rotation**: when the master rotates its read-only token, the
sub-company CEO must update `master_db_token` via the Skill operation
*"Update master token"* (recognized phrasing: *"Aggiorna il token della
master"*). CoS re-runs step 1.5d (verify connection) with the new token
before storing it.

---

## Disclosure policy enforcement

The master company's CLO is responsible for marking decisions `scope='global'`
only after CEthO validation and CEO approval (same flow as any
Universal-CONFIDENTIAL edit per SYSTEM_INVARIANTS.md §5). The global scope is
an **additional** approval gate, not a shortcut.

The sub-company's CLO is responsible for ensuring that no sub-company policy
references a global decision as if the sub-company had authority over it.

---

## Master has no registry of its sub-companies

This is **intentional**. The master does not know who is pointing at it.
A sub-company can connect to a master without the master's knowledge or
consent — the read-only token is the only gate, and that token is generated
by the master owner and handed to the sub deliberately. The absence of a
registry keeps the master simple and avoids a dependency inversion where
the master must maintain state about its dependents.

If a master owner wants to track their sub-companies, they can do so with
a `knowledge_base` entry or a `decisions` row — both are outside the
framework's purview.

---

## What this does NOT cover

- Cross-instance messaging (agents in sub talking directly to agents in
  master) — deferred to FEAT-022 or later.
- Multi-master topologies (two peers each with global decisions) — not in
  scope; would require a consensus layer.
- Sub-company writing back to master — explicitly forbidden; the read-only
  token is the technical enforcement.

---

## Consequences

**Positive**
- Physical detachment is a single `master_context` key change — no agent
  surgery, no schema migration.
- Infra/arch decisions stay in one place (master global scope) without
  forcing a full company sync operation.
- Disclosure boundary is clean: sub-company agents cannot accidentally
  expose master company-scoped decisions.

**Negative / risks**
- Master DB read at every sub-company boot adds a Turso round-trip.
- If master DB is unavailable, boot proceeds with a warning (stale global
  context) — this must be handled gracefully in the boot sequence.
- CLO discipline required: promoting a decision to `global` is irreversible
  without a supersession row (immutable-row pattern applies).
