# ADR 0007 — PreCompact hook for context management

## Status

Accepted (2026-04-23). Promoted from `juvantlabs/juvant-os-pm#7` (ARCH-007) on
2026-05-02.

## Context

Every Claude Code conversation eventually hits the context window limit and
compaction occurs. Earlier drafts asked agents to **self-report** when their
context was approaching saturation (heuristics at 75% / 90% token estimates).
Self-report has two failure modes:

- It is non-deterministic — the agent can fail to notice or miscount.
- It is consumed by behavioral degradation — the same context pressure that
  threatens output quality also threatens the agent's ability to flag context
  pressure.

Claude Code provides `PreCompact` and `PostCompact` lifecycle hooks. They fire
deterministically: PreCompact fires immediately before compaction; PostCompact
fires immediately after.

## Decision

Use `PreCompact` and `PostCompact` hooks for context management, replacing
agent self-report.

- **`PreCompact` hook** — `hooks/pre-compact.sh` reads the agent's structured
  Session Snapshot from stdin (Claude Code event payload) and writes it to
  `session_snapshots` in Turso. The snapshot is structured JSON (active task
  list, open questions, last decision, delegations in flight, cascade timer
  state, pointers to `master_context`) — never narrative prose.
- **`PostCompact` hook** — `hooks/post-compact.sh` selects the latest
  `session_snapshots` row for the agent and emits it to stdout, which Claude
  Code injects as fresh context after compaction.

Context resume on session reopen has three-level redundancy:

1. Agent SDK session resume via `agents.session_id` (full conversation history).
2. `session_snapshots` (operational state at last boundary).
3. Structured Turso memory (`counterparty_history`, `messages`,
   `knowledge_base`, `master_context`, `decisions`).

## Consequences

Positive:

- Context management is deterministic and observable. A snapshot either landed
  in Turso or it did not — there is no judgment call.
- Compaction does not lose load-bearing state because the schema, not narrative
  prose, holds it.
- Context resume works the same way across the Mac, the v1.1 portal, and the
  post-v1.0 Azure 24/7 deployment (OP-004).

Negative:

- The Session Snapshot must be expressive enough to reconstitute working state
  — agents must discipline their snapshot writes. Per-template anti-pattern
  lists call out narrative-summary commits as a CSO Layer 5 finding.
- Compaction frequency is determined by Claude Code, not by the system. That is
  acceptable; the redundancy layers (1) (2) (3) above tolerate any cadence.

## Replaces

- Token-estimation heuristics → PreCompact hook.
- Behavioral-degradation monitoring → PreCompact hook.
- Agent self-report at 75% / 90% context fill → PreCompact hook.

## Implementation

- `hooks/pre-compact.sh` — snapshot writer.
- `hooks/post-compact.sh` — snapshot reader.
- `scripts/schema.sql` — `session_snapshots` table.
- `JUVANT_OS.md` § "Context resume" — three-level redundancy.
- `agents/**/*.md` — every agent's "Context Awareness — PreCompact" section.

## References

- `SYSTEM_INVARIANTS.md` — context-management invariants.
- ADR 0003 (Turso as shared persistent memory).
