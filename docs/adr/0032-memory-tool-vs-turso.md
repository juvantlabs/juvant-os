# ADR 0032 — Agent memory stays on Turso; the API memory tool is deferred to the Agent-SDK path

## Status

**Accepted** — 2026-10-28 (CEO-ratified). Reaffirms ADR 0003 and defers the client-side API memory tool to the Agent-SDK path; not adopted within the current Claude-Code-hosted architecture. Resolves juvant-os-pm#173 (ARCH-019). Part of the 2026-Q4 platform-modernization backlog.

## Context

Anthropic's **memory tool** (`memory_20250818`) is a client-side tool: the model
issues `view/create/str_replace/insert/delete/rename` operations under a
`/memories` path, and the **client** supplies the handler that maps those onto
storage it owns. The 2026-Q4 backlog asked (ARCH-019) whether to back such a
handler on Turso, giving agents durable model-managed working memory "behind the
single-writer boundary," with Turso remaining the system-of-record.

Juvant OS already has a memory architecture:

- **ADR 0003** — Turso is the shared persistent memory; the context window is
  temporary. Agents read/write structured state (`decisions`, `messages`,
  `knowledge_base`, `session_snapshots`, …) through `hooks/lib/db.sh`, and every
  write is governed (single-writer per §4) and auditable (Track 3 log).
- **ADR 0007** — the PreCompact / PostCompact hooks commit memory to Turso before
  a context compaction and reload critical context after, replacing agent
  self-report. This is the durable-continuity mechanism.

## Decision drivers

1. **We don't own the API client loop.** Juvant OS runs *on* Claude Code, not on
   the raw Messages API. The memory tool's defining feature is a
   **client-provided handler** — but in the Claude-Code-hosted harness, Claude
   Code owns the API loop; the framework has no seam to install a Turso-backed
   `/memories` handler. The premise "our handler maps `/memories` onto Turso" is
   not realizable here. It becomes realizable only on the **Agent SDK / Managed
   Agents** path (the cloud-migration target tracked in FEAT-015 / the
   Agent-Teams notes), where the framework would own the loop.
2. **It would be a model-managed, parallel store.** The memory tool's contents
   are chosen autonomously by the model. A second, model-managed memory beside
   Turso's governed system-of-record adds surface without clear need — and the
   governance value ("behind the single-writer boundary") only materializes if
   the handler enforces scope + audits writes, which (per driver 1) we can't host
   in-harness anyway.
3. **Continuity is already solved.** Turso (ADR 0003) + the compact hooks
   (ADR 0007) + `knowledge_base` already provide durable cross-session memory.
   There is no continuity gap the memory tool would close today.
4. **A CC-native alternative exists** if a per-agent scratch layer is ever wanted:
   the Claude Code subagent `memory:` frontmatter field (`user`/`project`/`local`,
   persists across conversations). That is in-harness and does not require owning
   the API loop — but it is still a model-managed store outside the Turso audit
   trail, so it would need its own governance evaluation before use.

## Decision

1. **Reaffirm ADR 0003**: Turso remains the memory architecture and system-of-
   record; the PreCompact/PostCompact hooks remain the continuity mechanism. Do
   **not** adopt the API memory tool as a parallel store in the current
   Claude-Code-hosted architecture.
2. **Defer, don't reject.** Revisit the Turso-backed `/memories` handler **if and
   when** Juvant OS moves agents onto the Agent SDK / Managed Agents (where the
   framework owns the API loop). At that point a successor ADR designs the handler
   so every memory write enforces the single-writer scope and lands in the audit
   trail — the one framing under which the memory tool is a net gain.
3. **Pair for context economy regardless of store.** Independently of the memory
   tool, adopt server-side **compaction** + **context editing** to keep long CoS
   orchestration sessions under the 1M ceiling — these reduce tokens without
   changing where durable state lives (Turso). (Tracked for a separate, smaller
   change; not gated on this ADR.)

## Consequences

- **Positive:** no second, model-managed memory competing with the governed Turso
  record; the single-writer + audit invariants stay intact; zero new surface now.
- **Negative / watch:** agents don't get autonomous scratch memory today — judged
  a non-loss, since ADR 0003 + 0007 already cover durable continuity.
- **Reversible:** deferral, not rejection — the Agent-SDK path reopens it cleanly.

## Implementation

None now (reaffirmation). The compaction/context-editing pairing (Decision 3) is
a separate lightweight change. A successor ADR is written only on the Agent-SDK
migration.

## References

- ADR 0003 (Turso as shared persistent memory), ADR 0007 (PreCompact context
  management). FEAT-015 webhook/cloud path. Memory-tool docs:
  `platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool`.
- juvant-os-pm#173 (ARCH-019); backlog `docs/modernization-2026q4-claude-platform.md`.
