# plugins/

Claude Code Channel plugins shipped with the Juvant OS template family.

This directory hosts plugins that integrate Juvant OS with the Claude Code
runtime via the `defineChannel` API. MCP servers that wrap external vendor
APIs live in their own repos under `juvantlabs/*-mcp-server` (referenced
from this template at `.juvant/config.json` rather than embedded here);
see `docs/MCP_INVENTORY.md` for the canonical list.

## Plugin categories

### Channel plugins (this directory)

Channels in Claude Code are MCP servers that declare the
`claude/channel` capability and emit `notifications/claude/channel`
events (per
[Claude Code channels reference](https://code.claude.com/docs/en/channels-reference.md)).
They handle reactive inbound message routing.

Currently shipped: `telegram` (the built-in Claude Code plugin,
referenced in `.claude/settings.json` `channels`).

Planned (v1.1):

- `portal-bridge/` — External Portal ↔ agent sessions with
  disclosure filtering. Awaits FEAT-009.
- `teams-meeting/` — Teams meeting bot, CoS as silent co-pilot during
  client calls. Awaits FEAT-010.

**Inbound mail is NOT a Channel plugin.** Per the FEAT-006 closure
(2026-05-04): in v1.0 inbound mail is on-demand read by mail-enabled
agents (CFO/CLO/CCO/CMO) via the existing `ms-graph` claude.ai
connector, dispatched by CoS — no polling, no auto-emit. v1.1+
reactive mail uses the FEAT-016 `m365-mail-mcp-server` consumed by
cloud-running agents (OP-004) reacting to FEAT-015 webhook receiver
events. See `project_mail_enabled_agents` auto-memory for the
pattern, or
[juvant-os-pm#14](https://github.com/juvantlabs/juvant-os-pm/issues/14)
for the closure rationale.

### Helpers (separate directory: `helpers/`)

Scheduled scripts (NOT agent sessions) that fetch data, classify by
rules, populate Turso queues, and notify on threshold. Agents drain
queues only during interactive sessions. See FEAT-007 + `helpers/README.md`.

### MCP servers (separate repos)

Each MCP server wrapping a vendor REST API lives in its own
`juvantlabs/*-mcp-server` repository. Examples:

- `juvantlabs/finom-mcp-server` — Finom banking (FEAT-011)
- `juvantlabs/aruba-fattura-mcp-server` — Italian SDI e-invoicing (FEAT-012)
- `juvantlabs/m365-graph-mcp-server` — Microsoft Graph (FEAT-014)

This separation lets each MCP server be independently versioned,
npm-publishable, audit-isolated, and shareable across Juvant OS adopters
without coupling to the template release cadence.

## Conventions for new plugins

When contributing a new Channel plugin in this directory:

- **Language**: TypeScript with `@modelcontextprotocol/sdk`.
- **Polling cadence**: 5 minutes (`300_000` ms) for inbound channels unless
  the provider mandates faster. Prefer slower over faster — agents are
  not real-time systems.
- **Sender confidence pattern**: at emit time, look up
  `counterparty_routing` and `counterparty_contacts` in Turso to classify
  the inbound (whitelisted / unverified / unknown). Pass the classification
  to the agent as part of the event payload; agent decides routing per
  manifesto.
- **Dead-letter pattern**: write failures to the `adapter_dead_letters`
  Turso table (existing schema). Never block the receiver loop on a
  failed delivery.
- **Auth env vars**: per-plugin prefix (`M365_*`, `TELEGRAM_*`,
  `TEAMS_BOT_*`). Loaded by Claude Code from `.juvant/config.json` at
  plugin startup. Never logged. Never written to Turso.
- **Registration**: add to `.claude/settings.json` `channels` array.
- **Stdout discipline**: MCP / Channel plugins multiplex protocol frames
  on stdout. Use `console.error` for diagnostics; never `console.log`.
  This is non-negotiable — see the 2026-05-03
  [security review of ftaricano/mcp-onedrive-sharepoint](https://gist.github.com/juvantlabs/a9fe0a76a23b0c1260b1e0ad3194a6da)
  finding C6 for what happens when you ignore this.

## Adding a new plugin

1. Create `plugins/<name>/` with `index.ts`, `package.json`, `README.md`.
2. Implement per the conventions above.
3. Register in `.claude/settings.json` `channels` array.
4. Add a row to `docs/MCP_INVENTORY.md` if the plugin grants new
   capabilities to agents.
5. CTO + CSO joint review (per `SYSTEM_INVARIANTS.md` §4 + §6).
6. Update this README.
7. Bump `agent_tool_matrix` v0 seed if the plugin affects default tool
   grants (CTO-proposed `tool-matrix-change` decision).
