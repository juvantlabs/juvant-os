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
| [0010](0010-compiled-agent-registration.md) | Compiled agent templates register in `.claude/agents/` via symlinks | Accepted | 2026-05-08 |
| [0011](0011-ceo-direct-channel-class.md) | `<channel>:send-ceo-only` carve-out from the §4 disclosure boundary | Proposed | 2026-05-09 |
| [0012](0012-batch-testco-mode.md) | Batch testco mode + CI integration | Accepted | 2026-05-09 |
| [0013](0013-script-scope-flag-uniformity.md) | Script scope-flag uniformity (`--project=<slug>` canonical pattern) | Accepted | 2026-05-10 |
| [0014](0014-tech-leadership-restructure.md) | Tech leadership restructure (CTO promotion, project-scope rename, VPE toggle) | Proposed | 2026-05-09 |
| [0015](0015-design-brand-ownership.md) | Design & brand ownership (CMO ↔ Design Lead split, 3-mode brand-spec pattern) | Proposed | 2026-05-09 |
| [0016](0016-framework-scope-position.md) | Framework scope position (Juvant OS as software-development-flavored opinionated stack) | Proposed | 2026-05-09 |
| [0017](0017-sub-company-model.md) | Sub-company model: master/sub topology with global-scoped decisions | Proposed | 2026-05-16 |
| [0018](0018-descope-bash-escalation.md) | De-scope FEAT-025 dynamic bash escalation; self-remediating deny message is the durable design | Accepted | 2026-06-16 |
| [0019](0019-juvantlabs-as-self-developing-project.md) | Modeling `juvantlabs` as a project that develops the framework — source-of-truth, upstream-sync, recursion mechanics | Accepted | 2026-06-18 |
| [0020](0020-component-scope.md) | Component-scope: lightweight third tier (one `<slug>-maintainer`, state on GitHub, registry in config) for library/MCP/toolbox repos | Accepted | 2026-06-22 |
| [0021](0021-single-identity-branch-protection.md) | Branch protection for single-identity agent-maintained repos (administrators exempt) | Accepted | 2026-06-23 |
| [0022](0022-remote-mcp-stdio-bridge.md) | Remote authenticated MCP servers wired via `mcp-remote` + `dotenv-cli` stdio bridge (not `type: http` + launcher wrapper) | Accepted | 2026-06-23 |
| [0023](0023-document-spaces-third-party-access.md) | Provider-neutral document **spaces**: scoped third-party access via org-owned containers (SharePoint site / Shared Drive), surgical not wholesale; agent→space pointing under the existing principal | Proposed | 2026-06-25 |
| [0024](0024-outbound-action-queue.md) | Outbound action queue (**outbox**): one durable Turso queue for side-effecting MCP operations; approval inside the queue; per-operation activation via rubric, not per-MCP mandate | Proposed | 2026-06-25 |
| [0025](0025-document-space-access-control.md) | Document-space access control (extends 0023): MCP-scope-reaches-container as a sequenced prerequisite; don't-promote-UC-without-external; access-aware `resolve_space`; sensitive-space perimeter at the pre-tool-use hook (not the spoofable MCP server); instance-local policy | Proposed | 2026-06-25 |
| [0026](0026-authorization-is-a-record-not-a-message.md) | CEO authorization is a verifiable record (approved decision / `juvant:decision` issue / confirmation token), never a "direct CEO message" (no such channel — deadlock); own-scope writes self-authorize; anti-manipulation is scoped to untrusted data, not the CoS relay | Proposed | 2026-06-27 |

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
