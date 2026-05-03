# plugins/

Claude Code Channel plugins shipped with the Juvant OS template family.

This directory hosts plugins that integrate Juvant OS with the Claude Code
runtime via the `defineChannel` API. MCP servers that wrap external vendor
APIs live in their own repos under `juvantlabs/*-mcp-server` (referenced
from this template at `.juvant/config.json` rather than embedded here);
see `docs/MCP_INVENTORY.md` for the canonical list.

## Plugin categories

### Channel plugins (this directory)

Implement the Claude Code `defineChannel` API. Used for inbound message
routing into agent sessions:

- `m365-mail/` — M365 email → CFO / CLO / CCO / CMO press routing.
- `portal-bridge/` — v1.1 External Portal ↔ agent sessions with disclosure
  filtering.
- `teams-meeting/` — v1.1 Teams meeting bot, CoS as silent co-pilot during
  client calls.

Lifecycle (start, poll, stop) is managed entirely by Claude Code — no
daemon, no separate process, no infrastructure overhead. Same pattern as
the built-in Telegram plugin.

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
5. CA + CSO joint review (per `SYSTEM_INVARIANTS.md` §4 + §6).
6. Update this README.
7. Bump `agent_tool_matrix` v0 seed if the plugin affects default tool
   grants (CA-proposed `tool-matrix-change` decision).
