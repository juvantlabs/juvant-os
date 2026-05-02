# ADR 0004 — M365 mail as a native Claude Code Channel plugin

## Status

Accepted (2026-04-23). Promoted from `juvantlabs/juvant-os-pm#4` (ARCH-004) on
2026-05-02.

## Context

Inbound M365 mail must reach the right agent (CFO for invoices, CLO for legal
correspondence, CCO for sales, CMO for press). The earlier design proposed a
separate MCP server with its own daemon for polling Microsoft Graph, marking
messages as read, and pushing into agent sessions.

Claude Code subsequently shipped the **Channel plugin** primitive
(`defineChannel` API). It manages plugin lifecycle, polling, and session push
inside the Claude Code runtime — the same pattern used by the native Telegram
plugin.

## Decision

The M365 mail integration is a native Claude Code Channel plugin
(`plugins/m365-mail/index.ts`), NOT a separate MCP server or daemon.

- `pollInterval`: 300,000 ms (5 minutes).
- Marks messages as read after emission to avoid reprocessing.
- Sender confidence is read from Turso (`counterparty_routing`,
  `counterparty_contacts`) and dictates routing:
  - **Whitelisted sender** → emit automatically to the owning agent's session.
  - **Known domain, unknown sender** → emit with `confidence='unverified'`.
  - **Unknown** → escalate to CoS via `inbound_queue` for CEO decision.
- Registered in `.claude/settings.json` `channels` array alongside the Telegram
  plugin.
- CMO scope is press-only — the plugin only routes mail from the configured
  press mailbox (e.g. `press@<company-domain>`) to CMO. Other inbound classes go
  to their respective owners.

## Consequences

Positive:

- Zero infrastructure overhead: no daemon, no separate process, no MCP server
  to install.
- Uniform with the Telegram channel plugin pattern; future inbound channels
  (e.g. SMS, Slack) follow the same shape.
- Lifecycle and retry are managed by Claude Code, not by the plugin author.

Negative:

- The plugin is dependent on Claude Code Channel APIs remaining stable. The
  Channel API is currently in research preview; OK for internal use, monitored
  monthly per Migration Watch.
- Polling cadence is bounded at 5 minutes; near-real-time mail handling is not
  in scope for v1.0.

## Implementation

- `plugins/m365-mail/index.ts` — TypeScript Channel plugin (Phase 6 / Beta).
- `.claude/settings.json` — channel registration alongside Telegram.
- `agents/company/cmo.md` — press-scope receive only.
- `agents/company/cfo.md`, `clo.md`, `cco.md` — receive scopes for their
  respective inbound classes.

## References

- `SYSTEM_INVARIANTS.md` — Universal Boundaries (no `m365-mail` send except to
  v1.1 portal variants).
- `juvantlabs/juvant-os-pm/docs/build-plan.md` Phase 6.
