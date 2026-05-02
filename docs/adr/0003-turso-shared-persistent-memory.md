# ADR 0003 — Turso as shared persistent memory; context window is temporary

## Status

Accepted (2026-04-23). Promoted from `juvantlabs/juvant-os-pm#3` (ARCH-003) on
2026-05-02.

## Context

Each Claude Code session has a finite context window that is emptied at
SessionEnd. If the system relied on context for cross-session memory, every new
session would start blank — including counterparty history, in-flight queue
items, decision rationale, and disclosure policies.

The same agent role can run in two surfaces (internal CFO on the Mac and the
v1.1 portal CFO on Azure). Both surfaces must operate on the same memory; a
context-bound design cannot satisfy that requirement.

## Decision

Turso is the canonical persistent memory for Juvant OS. The Claude Code context
window is treated as temporary session memory only.

Every agent applies the **Memory Commit Protocol** after every meaningful
exchange:

1. `UPDATE counterparty_history` — rolling summary, max 2,000 chars.
2. `INSERT INTO messages` when an action is needed.
3. `UPDATE inbound_queue` status as work progresses.
4. `INSERT INTO decisions` when a commitment is made.

The **SessionEnd hook** is the boundary — anything not in Turso by SessionEnd is
lost. The **PreCompact hook** enforces the same boundary inside long sessions
by writing a deterministic Session Snapshot before context truncation.

## Consequences

Positive:

- Internal and portal variants of the same role share state by construction —
  no sync layer.
- Context resume on reopen has three-level redundancy: Agent SDK `session_id`
  → `session_snapshots` → structured Turso memory.
- Operational invariants (manifesto state, disclosure policies, agent_tool_matrix
  versions) survive any session restart.

Negative:

- Agents must discipline themselves to commit. The `JUVANT_OS.md` security rule
  set and per-template anti-pattern lists make non-commit a CSO Layer 5 audit
  finding.
- The `session_snapshots` payload is structured JSON, not free text. Narrative
  drifts between sessions; rows do not.

## Shared tables (canonical)

`counterparty_history`, `inbound_queue`, `messages`, `disclosure_policies`,
`session_snapshots`, `master_context`, `decisions`, `manifests`,
`agent_tool_matrix`, `knowledge_base`, `security_audit_log`,
`portal_offline_messages`. See `scripts/schema.sql` for full enumeration.

## Implementation

- `JUVANT_OS.md` § "Memory commit protocol" — SQL templates per exchange type.
- `JUVANT_OS.md` § "Context resume" — three-level redundancy.
- `hooks/pre-compact.sh` — Session Snapshot writer.
- `hooks/post-compact.sh` — Session Snapshot reader.
- `hooks/session-end.sh` — `agents.status='inactive'` boundary.

## References

- `SYSTEM_INVARIANTS.md` — Memory invariants and PreCompact protocol.
- ADR 0007 (PreCompact hook for context management).
