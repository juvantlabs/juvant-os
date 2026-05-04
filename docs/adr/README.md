# Architecture Decision Records — Juvant OS framework

This directory contains ADRs (Architecture Decision Records) for the **Juvant OS
framework** — load-bearing architectural decisions about how the framework itself
works, captured in Nygard form: **Status / Context / Decision / Consequences /
Implementation / References**.

> **Org-level governance ADRs live elsewhere.** Decisions about how `juvantlabs` (the
> OSS arm) operates as an organization — namespace structure, contribution policy,
> security disclosure process, MCP-server-naming convention, etc. — live in the
> separate handbook repository: [`juvantlabs/handbook/docs/adr/`](https://github.com/juvantlabs/handbook/tree/main/docs/adr).
> The distinction is load-bearing: framework architecture stays here; org governance
> stays there.

ADRs are immutable. An ADR is `Accepted` when it is in force; if a later decision
overrides it, both the new ADR and the original remain — the old one is annotated
`Superseded by NNNN`. Decisions never disappear from the record.

## Index

| # | Title | Status | First decided |
|---|---|---|---|
| [0001](0001-skill-first-architecture.md) | Skill-first architecture — `JUVANT_OS.md` as the orchestrator | Accepted | 2026-04-23 |
| [0002](0002-turso-cloud-state-store.md) | Turso as the cloud state store (LibSQL) | Accepted | 2026-04-23 |
| [0003](0003-turso-shared-persistent-memory.md) | Turso as shared persistent memory; context window is temporary | Accepted | 2026-04-23 |
| [0004](0004-m365-mail-channel-plugin.md) | M365 mail as a native Claude Code Channel plugin (not an MCP server) | **Superseded by 0009** | 2026-04-23 |
| [0005](0005-portal-agent-variants.md) | Portal agent variants — internal vs. portal subagent segregation | Accepted | 2026-04-23 |
| [0006](0006-ca-owns-agent-tool-matrix.md) | CA owns the agent tool matrix; matrix is compiled into subagent frontmatter | Accepted | 2026-04-23 |
| [0007](0007-precompact-hook-context-management.md) | PreCompact hook for context management; replaces agent self-report | Accepted | 2026-04-23 |
| [0008](0008-manifesto-fast-start.md) | Manifesto fast-start — Tier 1 blocking, Tier 2 async 7-day | Accepted | 2026-04-23 |
| [0009](0009-mail-via-ms-graph-on-demand.md) | Mail integration via on-demand `ms-graph` connector dispatched by CoS (supersedes 0004) | Accepted | 2026-05-04 |

## Modification governance

Amendments to an Accepted ADR follow the standard versioning flow per
`SYSTEM_INVARIANTS.md` §4 + §6 + Appendix B:

1. Proposer drafts a successor ADR (CA, or any agent acting through CoS).
2. CoS routes to the CEO; the CEO approves.
3. CA designs a `pr-spec` for the successor + supersession annotation on the original.
4. COO opens the PR; review involves CHRO + CA + CSO + CEthO when relevant.
5. After merge, CHRO triggers system-wide manifesto re-validation if the change
   touches `SYSTEM_INVARIANTS.md` §1, §3, §4, §5, or §6.

Trivial fixes (typos, broken links, formatting) are out-of-band and do not require
a successor ADR.

## Conventions

- Numbering is monotonic, zero-padded to four digits.
- Filenames are kebab-case, prefixed with the ADR number.
- Decisions name **roles** (CEO, CFO, CoS, etc.), never personal or instance-specific
  identifiers — this template is generic by design.
- All ADR text is in English. No exceptions.

## Origin

ADRs 0001–0008 were promoted from GitHub issues
[ARCH-001 through ARCH-008](https://github.com/juvantlabs/juvant-os-pm/issues?q=label%3AARCH)
on `juvantlabs/juvant-os-pm` (2026-05-02). The closing comment on each origin issue
points back to the corresponding ADR file in this directory.
