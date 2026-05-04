# ADR 0006 — CA owns the agent tool matrix

## Status

Accepted (2026-04-23). Promoted from `juvantlabs/juvant-os-pm#6` (ARCH-006) on
2026-05-02. Refined 2026-05-01 by SYSTEM_INVARIANTS.md §4 (single-writer
invariant for `github:write`).

## Context

Tools (MCP servers, Skills, Channels) are an architectural concern — they
determine what each agent can read, write, send, or receive. Earlier drafts
considered placing tool ownership with CHRO (people / role definitions). That
conflated *who an agent is* with *what an agent can do* and split governance
across two roles.

Tool boundaries are also security boundaries: granting `bank:write` or
`github:write` to the wrong agent is not a procedural mistake, it is an
incident.

## Decision

The Chief Architect (CA) owns the agent tool matrix. The matrix has three
categories per agent:

- **MCP servers** — `turso`, `ms-graph`, `github:read` / `github:write`,
  `bank:read` (abstract, bound to a concrete provider at company init), `buffer`.
- **Claude Code Skills** — `pdf`, `docx`, `frontend-design`, `data-analysis`.
- **Channels** — `telegram`. (Inbound mail is NOT a channel — it's
  on-demand read via the `ms-graph` connector dispatched by CoS to
  mail-enabled agents per [ADR 0009](0009-mail-via-ms-graph-on-demand.md);
  v1.1+ portal-bridge and teams-meeting are planned channels.)

The matrix is **compiled into each subagent's frontmatter at company init** and
mirrored into the `agent_tool_matrix` Turso table. Rows in `agent_tool_matrix`
are immutable: changes happen by supersession only (new row, `superseded_by`
on the previous row). Every change is CEO-approved.

Governance flow for tool changes:

```
requestor agent → CoS → CA review → COO install → CEO approval → matrix updated
```

Universal Boundaries — CA cannot grant under any rationale:

- `bank:write` to any agent except a future ratified `treasury` role.
- Mail-send capability (FEAT-016 `m365-mail-mcp-server`, v1.1+) to any
  agent except v1.1 portal variants. Autonomous send is never granted.
- `github:write` to any agent except COO (single-writer invariant; `SYSTEM_INVARIANTS.md` §4).
- Both `state.db` read and external-channel send in the same matrix row.
- `Bash` unrestricted to any external-facing agent (portals / demo).

## Consequences

Positive:

- Tool grants are centrally reviewed; CA holds the load-bearing knowledge of
  which capabilities create which risks.
- Compilation into frontmatter means Claude Code's native subagent tool
  restrictions enforce the matrix — there is no separate runtime check that can
  drift.
- Every grant has a paper trail in `agent_tool_matrix` with the approving CEO,
  the version, and the supersession chain.

Negative:

- A new tool requires a multi-step flow rather than a quick grant. By design —
  speed is not a virtue at security boundaries.
- The compiled frontmatter is regenerated when the matrix changes; the
  `install-spec` from CA → COO drives that regeneration.

## Implementation

- `agents/company/ca.md` — CA manifesto, tool-matrix authority.
- `scripts/schema.sql` — `agent_tool_matrix` table (immutable, supersession only).
- `JUVANT_OS.md` § "Spec-driven single-writer model" — `install-spec` flow.
- Each subagent file's YAML frontmatter — the compiled matrix output.

## References

- `SYSTEM_INVARIANTS.md` §4 (Single-Writer Invariant) and §6 (Spec
  Authorization Matrix).
- `juvantlabs/juvant-os-pm/docs/session-commit-p1.md` — Agent Tool Matrix v0
  default seed.
