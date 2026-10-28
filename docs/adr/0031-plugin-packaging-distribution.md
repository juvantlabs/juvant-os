# ADR 0031 — Package Juvant OS as a Claude Code plugin for distribution + updates (hybrid with compile-templates)

## Status

**Accepted** — 2026-10-28 (CEO-ratified). The one technical gate (do plugin agents honour per-agent `mcpServers`?) was verified and resolved — they do not, so agents stay filesystem-compiled (§ Decision 3). Resolves juvant-os-pm#172 (ARCH-018). Part of the 2026-Q4 platform-modernization backlog.

## Context

Today an adopter stands up Juvant OS by forking the framework repo and running
`scripts/compile-templates.sh` (placeholder substitution of `{{COMPANY_NAME}}`
etc. across 21 agent manifests, symlink wiring of `.claude/agents/*.md` →
`agents/company|projects|components/*.md`, per-project / per-component compiled
output), then pulls framework updates over time via the Skill's "upstream sync"
(a whitelist-driven reconcile — e.g. `scripts/sync-hooks.sh` for the hooks block).

Claude Code's plugin system (GA through 2026) is now a first-class distribution
channel: a plugin bundles `agents/`, `skills/`, `commands/`, `hooks/`,
`mcpServers` (incl. `.mcp.json` / `.mcpb`), `channels`, and `settings` (only
`agent` + `subagentStatusLine` take effect), installable via
`/plugin install <name>@<marketplace>`, versioned, with **`userConfig`** that
prompts the adopter for typed values at enable time and substitutes
`${user_config.KEY}` into MCP/LSP config, exec-form hook args, and **skill and
agent content** (non-sensitive only; sensitive → secure store + placeholder).

The question (FEAT-064 sibling / ARCH-018): should Juvant OS be repackaged as a
plugin, and if so, wholesale or partially?

## Decision drivers (verified against the live plugin-manifest reference)

Favourable — several earlier worries do **not** apply:

- **No top-level `bin/`.** Our executables live in `scripts/` and `helpers/` and
  are invoked as `bash scripts/x.sh`, never as bare PATH commands — so the
  "claude.ai / Cowork refuse a plugin with a top-level `bin/`" rule does not bite.
- **`userConfig` substitutes into agent + skill content**, so company-init values
  (`COMPANY_NAME`, domain, agent names, mailboxes) can be captured at enable time
  instead of baked by `compile-templates`.
- **Plugins bundle `mcpServers` and `channels`.** A `channels` entry bound to an
  MCP server with a `userConfig` token is a near-exact fit for our Telegram/Teams
  notification + `bank`/`ms-graph`/`social` bindings.
- **Versioned updates** via the marketplace could replace the hand-rolled
  upstream-sync reconcile with a cleaner `/plugin update`.
- **Plugin-root `CLAUDE.md` is not loaded** — fine for us; our orchestrator is a
  Skill (`JUVANT_OS.md`, ADR 0001), not `CLAUDE.md`.

Constraints — two load-bearing limits:

1. **`userConfig` ≠ structural compilation.** It substitutes scalar values into
   content, but it does **not** do what `compile-templates` does beyond that:
   symlink wiring, per-project / per-component compiled directories, and
   placeholder substitution spread across 21 manifests with per-role agent names.
   A plugin alone cannot bootstrap an instance; a setup step remains.
2. **Plugin-provided subagents ignore per-agent `mcpServers` — VERIFIED, and it
   is decisive.** The plugin-components reference states verbatim that a plugin
   agent's **ignored fields** are "`permissionMode`, `hooks`, `mcpServers`, and
   `initialPrompt`" — *"An agent file can't add hooks or MCP servers on its own,
   so add those as plugin hooks and MCP servers instead."* A plugin's MCP servers
   are plugin-wide (`plugin:<plugin>:<server>`), not per-agent. Our governance
   **depends** on per-agent `mcpServers:` (e.g. `cfo → m365-graph`; mail-enabled
   agents bind their own mailbox MCP) — the one-MCP-per-threat-boundary model
   (handbook MCP-scope ADR). Shipping agents via the plugin would collapse that
   into a flat, plugin-wide pool. (Our session hooks are registered in
   `.claude/settings.json`, not per-agent frontmatter, so the ignored-`hooks`
   rule does not bite — only `mcpServers` does, and it bites hard.)

## Decision

Adopt plugin packaging as a **hybrid**, not a wholesale replacement:

1. **Distribute + update via a plugin + marketplace.** Ship a `juvantlabs`
   marketplace entry. The plugin carries the parts that are flat and
   value-parameterizable — `commands`, `skills`, `hooks`, and `channels`/
   `mcpServers` templates — with `userConfig` capturing company-init values.
   Adopters install with `/plugin install`, update with `/plugin update`
   (superseding the bespoke upstream-sync for those components).

2. **Keep a bootstrap step for structural compilation.** The Skill (or a thin
   `juvant-init`) still performs the symlink wiring, per-project/component
   compilation, and multi-manifest agent-name substitution that `userConfig`
   cannot express. `compile-templates.sh` is retained and invoked by that step.

3. **Agents stay filesystem-compiled — NOT plugin-provided.** Resolved by the
   verified fact in driver 2: because plugin agents ignore `mcpServers:`, keeping
   the 21 agent manifests on the `compile-templates` + symlink path is the only
   way to preserve per-agent MCP scoping (one MCP per threat boundary). The
   plugin therefore carries only `commands`, `skills`, session-level `hooks`,
   `channels`, and plugin-level `mcpServers` templates — never the agents.

## Consequences

- **Positive:** a real "second-adopter" on-ramp (install + answer userConfig
  prompts); cleaner versioned updates; notifications/MCP via `channels`.
- **Negative / watch:** two distribution surfaces to keep in sync (plugin +
  bootstrap step) until/unless plugins can express the structural compilation;
  a new **supply-chain / threat-model boundary** — a third-party-installable
  plugin is an attack surface (align with the handbook one-MCP-per-threat-boundary
  ADR; CSO reviews the marketplace entry).
- **Reversible:** the hybrid leaves `compile-templates` + fork-based adoption
  intact; the plugin is additive. Abandoning it costs only the marketplace entry.

## Implementation

1. ~~Verify plugin-provided-subagent frontmatter honouring.~~ **Done
   (2026-10-28)** — the plugin-components reference is authoritative and explicit:
   plugin agents ignore `mcpServers`/`hooks`/`permissionMode`/`initialPrompt`.
   Decision 3 (agents stay filesystem-compiled) is settled; no live probe needed.
2. Author `.claude-plugin/plugin.json` + a marketplace entry; map company-init
   fields to `userConfig`; move notification/MCP bindings to `channels`
   (plugin-level). Agents are explicitly excluded from the plugin.
3. Keep `compile-templates.sh` as the bootstrap step for the 21 agent manifests.
4. Document the install path in README alongside the existing fork path.

## References

- ADR 0001 (Skill-first architecture), ADR 0027 (compiled-output split),
  handbook one-MCP-per-threat-boundary ADR.
- Plugin manifest reference: `code.claude.com/docs/en/plugins-reference`.
- juvant-os-pm#172 (ARCH-018); backlog `docs/modernization-2026q4-claude-platform.md`.
