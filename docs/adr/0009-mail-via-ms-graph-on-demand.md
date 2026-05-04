# ADR 0009 — Mail integration via on-demand `ms-graph` connector dispatched by CoS

## Status

Accepted (2026-05-04). **Supersedes [ADR 0004](0004-m365-mail-channel-plugin.md)**
(M365 mail as a native Claude Code Channel plugin via `defineChannel`).

## Context

ADR 0004 specified that inbound M365 mail integration would ship as a native
Claude Code **Channel plugin** at `plugins/m365-mail/index.ts`, using a
`defineChannel` API to poll Microsoft Graph every 5 minutes, mark messages as
read after emission, and push into agent sessions with sender confidence
scoring.

While prototyping FEAT-006 (the implementation issue for ADR 0004), three
structural problems surfaced and could not be reconciled within the original
design:

1. **`defineChannel` is not a Claude Code API.** What the docs actually
   describe ([code.claude.com/docs/en/channels-reference.md](https://code.claude.com/docs/en/channels-reference.md))
   is an MCP server pattern: channels declare a `claude/channel` capability
   and emit `notifications/claude/channel`. ADR 0004 was written against an
   API that does not exist.
2. **Spawning a fresh agent session on a schedule introduces a concurrency
   bug** with any concurrent interactive session for the same role. A launchd-
   or webhook-fired CFO instance reads stale Turso state if an interactive
   CFO session is mid-task; the two CFOs then act on inconsistent views.
   Solving this would require lease / lock infrastructure on Turso (per-role
   `agent_session_locks`, TTL coordination), which is non-trivial and not
   warranted for v1.0.
3. **A standalone polling helper would need its own `Mail.Read` OAuth
   scope** — either a separate Azure AD app or extending the
   `m365-graph-mcp-server` (FEAT-014) Azure AD app to include `Mail.Read`.
   The latter violates handbook
   [ADR 0003 — Scope boundaries for MCP servers](https://github.com/juvantlabs/handbook/blob/main/docs/adr/0003-mcp-server-scope-boundaries.md):
   files+calendar and mail have materially different threat models (mail
   broadcasts externally, irreversible, SPF/DKIM/DMARC reputation impact).

ADR 0004 cannot be implemented as written. A different pattern is needed.

## Decision

Mail integration in **v1.0 / Beta is on-demand, not reactive**.

### Mechanism

- Mail-enabled agents (CFO, CLO, CCO, CMO) call
  `mcp__claude_ai_Microsoft_365__outlook_email_search` — the **existing
  `ms-graph` claude.ai-managed connector** — when CoS dispatches them.
- Each agent's assigned mailbox is captured at company init in
  `.juvant/config.json` `mail_enabled_agents.<role>` (Step 1.5b of the
  wizard).
- **Single-dispatcher pattern**: only CoS calls `outlook_email_search` via a
  `Task` fan-out to mail-enabled subagents. Agents never poll the connector
  on their own initiative. This eliminates the concurrency bug structurally
  (single consumer of the mailbox + classification at any given time).
- No new Azure AD app, no new OAuth scope, no `Mail.Read` extension to the
  `m365-graph` app, no helper script, no `plugins/m365-mail/` directory, no
  Channel plugin.

### Mail-enabled is a per-agent characteristic

Captured in `.juvant/config.json`:

```json
{
  "mail_enabled_agents": {
    "cfo": "finance@<domain>",
    "clo": "legal@<domain>",
    "cco": "hello@<domain>",
    "cmo": "press@<domain>"
  }
}
```

Empty value or absent key = agent is not mail-enabled. Agent templates
surface `[<ROLE> MAILBOX UNBOUND]` if dispatched without a binding. Agents
not in this list (CSO, CA, COO, CoS, CDO, CHRO, CRO, CEthO, CTO, CPO, VPE,
eng-\*) are never mail-enabled — adding mail to a new role is a
`tool-matrix-change` decision per `SYSTEM_INVARIANTS.md` §6 (CA proposes,
CSO reviews, CEO approves), not a wizard knob.

### Reactive push deferred to v1.1+

Reactive push (webhook → agent fires immediately on inbound mail) is
**explicitly v1.1+ scope**, requiring three independent pieces:

- [FEAT-016](https://github.com/juvantlabs/juvant-os-pm/issues/30) —
  dedicated `juvantlabs/m365-mail-mcp-server` (read + send), separate Azure
  AD app for `Mail.Read` + `Mail.Send`, two-phase confirmation token on
  send (per ADR 0002 of the handbook).
- [FEAT-015](https://github.com/juvantlabs/juvant-os-pm/issues/29) —
  webhook receiver (cloud-deployed), translates Microsoft Graph
  subscription events into Turso queue rows or `RemoteTrigger.run` calls.
- [OP-004](https://github.com/juvantlabs/juvant-os-pm/issues/21) /
  [FEAT-009](https://github.com/juvantlabs/juvant-os-pm/issues/17) —
  cloud always-on agents that can react to events without the CEO's Mac
  being online.

Until those land, on-demand is the supported path.

### Send capability remains forbidden in v1.0

The Universal Boundary on mail-send is preserved: no agent has
mail-send capability in v1.0. The CEO sends manually from Outlook UI when
approving drafts. v1.1+ portal variants (`cfo-portal`, `clo-portal`,
`cco-portal`, `cmo-portal`) gain send capability via FEAT-016, but only
under explicit two-phase confirmation. Autonomous send is never granted.

## Consequences

### Positive

- **Zero infrastructure overhead.** No new MCP server, no Azure AD app, no
  helper script, no Channel plugin. The integration is a pattern in agent
  prompts plus a config schema in `.juvant/config.json`.
- **Concurrency-correct by construction.** Single-dispatcher (CoS) means
  there's only ever one consumer of the mailbox + classification at a time.
  No lease infrastructure needed.
- **Threat-model boundary preserved.** The `m365-graph` Azure AD app is not
  extended with `Mail.Read`. ADR 0003 stays clean.
- **Adopter-portable.** Any Juvant OS adopter who has a claude.ai
  subscription with the M365 connector enabled gets mail integration for
  free — no per-adopter app registration.

### Negative

- **No reactive push in v1.0.** Mail status is "next time you ask" or "next
  Morning Brief". For single-CEO use case this is acceptable; for larger
  teams it becomes a real limitation. v1.1+ unblocks proper reactive flow.
- **Read-only.** No agent can send mail in v1.0. The CEO sends manually
  from Outlook UI when approving drafts. Adds a manual step to every reply.
- **Latency.** A mail arriving at 11:00 isn't surfaced until the CEO
  prompts CoS for mail status, or until the next Morning Brief — could be
  hours.
- **Adopter dependency on claude.ai connector availability.** If the
  `mcp__claude_ai_Microsoft_365__outlook_email_search` connector goes down
  or is not enabled in the adopter's claude.ai session, mail integration
  is unavailable. Surface as Normal priority and defer.

### Considered alternatives

- **Build a `juvantlabs/m365-mail-mcp-server` for v1.0.** Rejected because
  it requires a separate Azure AD app + Mail.Read scope (per ADR 0003); the
  build is non-trivial (~1 day); and it doesn't actually solve the
  concurrency bug (a polling MCP that spawns agents has the same issue).
  Re-scoped as FEAT-016 for v1.1+ when cloud agents make it worth building.
- **Extend `m365-graph-mcp-server` to include Mail.Read tools.** Rejected
  per ADR 0003 — cross-threat-model expansion of a shipped MCP server is
  a Universal-Boundary-adjacent move that shouldn't be normalized.
- **Daemon polling helper script** (FEAT-007 Helpers pattern, applied to
  mail). Rejected because it would also need its own `Mail.Read` Azure AD
  app — the same auth question the dedicated MCP raises, just packaged
  differently. The Helpers pattern still applies to Finom polling, fiscal
  deadlines, and Morning Brief assembly (none of which have the
  claude.ai-managed-connector constraint mail does).

## Implementation

- **`.juvant/config.json` schema** — `mail_enabled_agents` block with
  per-role mailbox bindings. Wizard Step 1.5b in `JUVANT_OS.md` captures
  it at company init; CEO can re-run the step standalone via *"Configure
  mail-enabled agents"*.
- **Agent templates updated**:
  - CFO, CLO, CCO, CMO frontmatter: `channels: m365-mail` removed,
    `mail_enabled: true` flag added.
  - Each gains an "Email Triage (on dispatch)" section describing the
    confidence-classification table and the per-agent processing steps.
  - Communication Map "m365-mail (receive)" rows replaced with
    "ms-graph (read-only, on-demand)" rows.
  - Anti-patterns updated to reflect the on-demand model.
- **CoS template**: new "Mail Dispatch Protocol" section codifying the
  single-dispatcher rule, the parallel/scoped fan-out, the aggregation
  pattern, and the unbound-mailbox handling.
- **`plugins/README.md`** explicitly notes inbound mail is NOT a Channel
  plugin in v1.0; Channel plugins now scoped to `telegram` (built-in)
  and v1.1 entries (`portal-bridge/`, `teams-meeting/`).
- **`docs/MCP_INVENTORY.md`** Universal Boundary on mail-send updated to
  reference FEAT-016 mechanism.
- **`agents/company/ca.md`** Default Agent Tool Matrix `Channels` column
  cleared of `m365-mail (receive)` rows; mail-enabled status documented
  separately.

## References

- [ADR 0004 — M365 mail as a native Claude Code Channel plugin](0004-m365-mail-channel-plugin.md)
  — superseded by this ADR.
- [Handbook ADR 0003 — Scope boundaries for MCP servers](https://github.com/juvantlabs/handbook/blob/main/docs/adr/0003-mcp-server-scope-boundaries.md)
  — the threat-model rule that makes a Mail.Read extension to the
  `m365-graph` app unacceptable.
- [FEAT-006 closure (juvant-os-pm#14)](https://github.com/juvantlabs/juvant-os-pm/issues/14)
  — the issue where the original Channel-plugin spec was retired.
- [FEAT-007 (re-scoped) — Agent Helpers pattern](https://github.com/juvantlabs/juvant-os-pm/issues/15)
  — the helpers framework that handles non-mail scheduled work.
- [FEAT-016 — m365-mail MCP server + cloud automation](https://github.com/juvantlabs/juvant-os-pm/issues/30)
  — v1.1+ work that delivers reactive mail.
- `project_mail_enabled_agents.md` (auto-memory) — operating notes for
  this pattern.
