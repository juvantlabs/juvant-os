# ADR 0022 — Remote authenticated MCP servers wired via `mcp-remote` + `dotenv-cli` stdio bridge (not `type: http` + launcher wrapper)

## Status

Accepted (2026-06-23). Applies to every `.mcp.json` entry that targets a
**remote** MCP endpoint (HTTP or SSE transport) which requires an
**authenticated header** (e.g. `Authorization: Bearer <token>`).

## Context

Claude Code's `.mcp.json` accepts two main entry shapes for an MCP server:

1. A **stdio** server — a local `command` whose stdin/stdout speaks MCP.
2. A **remote** server — an `http` (or `sse`) entry with a `url` and an
   optional `headers` block.

When a remote MCP server is authenticated by a static secret (the common
case for third-party SaaS MCP endpoints today), the natural first attempt
is to declare it as `type: http` and place the secret in `headers`:

```json
{
  "mcpServers": {
    "<server>": {
      "type": "http",
      "url": "https://example.com/mcp",
      "headers": { "Authorization": "Bearer ${MCP_TOKEN}" }
    }
  }
}
```

This shape interpolates `${MCP_TOKEN}` against **Claude Code's parent
process environment**. There is no per-server env-file loading on the
`type: http` path. Consequences:

- The operator must export `MCP_TOKEN` in the shell that launches
  `claude` — every shell, every machine, every time. Forgetting it means
  Claude Code starts and the MCP fails silently or with an opaque header
  error.
- Persisting the secret in `~/.zshrc` / `~/.bashrc` leaks it into every
  unrelated process the operator runs, widens the blast radius of a
  shell history dump, and entangles the company instance with the
  operator's personal shell config.
- The workaround that follows naturally — a `scripts/start.sh` launcher
  that sources `.env.local` and then `exec`s `claude` — is itself an
  anti-pattern: operators lose the canonical `claude` / `claude --chrome`
  invocation, every Claude Code CLI flag must be re-plumbed through the
  wrapper, IDE / shell integrations that spawn `claude` directly bypass
  the wrapper (and therefore the secret), and muscle memory breaks.

The framework already has a stdio-with-per-server-env pattern that works
correctly for command-style servers, using `dotenv-cli` to load a
gitignored `.env.local` into the **child** process — no parent-shell
dependency, no wrapper script. Example (`@juvantlabs/m365-graph-mcp-server`):

```json
{
  "mcpServers": {
    "m365-graph": {
      "command": "npx",
      "args": ["-y", "dotenv-cli", "-e", ".env.local", "--",
               "npx", "-y", "@juvantlabs/m365-graph-mcp-server"]
    }
  }
}
```

The question is how to bring remote authenticated servers under the same
discipline.

The community tool [`mcp-remote`](https://www.npmjs.com/package/mcp-remote)
bridges a remote MCP endpoint into a local stdio server. Critically, its
`--header` flag performs `${VAR}` substitution against the **child
process** `process.env` at invocation time. This means wrapping
`mcp-remote` in `dotenv-cli -e .env.local` produces the same per-server,
gitignored, no-parent-shell secret model the command-style entries already
use — for any HTTP/SSE remote endpoint, regardless of provider.

## Decision

Remote authenticated MCP servers are wired into `.mcp.json` as a **stdio
`command`** that invokes `dotenv-cli` → `mcp-remote` → the remote endpoint,
with the secret substituted into the header at child-process invocation:

```json
{
  "mcpServers": {
    "<server>": {
      "command": "npx",
      "args": [
        "-y", "dotenv-cli", "-e", ".env.local", "--",
        "npx", "-y", "mcp-remote", "https://<remote-endpoint>/mcp",
        "--header", "Authorization: Bearer ${MCP_TOKEN}"
      ]
    }
  }
}
```

Where:

- `<server>` is the MCP_INVENTORY row name (e.g. the abstract role name).
- `https://<remote-endpoint>/mcp` is the remote MCP URL published by the
  provider.
- `${MCP_TOKEN}` is the secret env-var name documented for that row in
  `docs/MCP_INVENTORY.md` (e.g. the provider's `<PROVIDER>_ACCESS_TOKEN`).
- `.env.local` is the gitignored per-instance env file at the repo root.

The shape mirrors the canonical stdio+`dotenv-cli` shape already used for
command-style servers; the only new dependency is the `mcp-remote` bridge
package (auto-fetched by `npx -y` at first run, version-pinnable when a
specific bridge release is required).

The following alternative shapes are **rejected** for remote authenticated
servers:

- `type: http` + `headers.${SECRET}` — requires parent-shell secret
  export (see Context).
- A `scripts/start.sh` (or equivalent) launcher that sources `.env.local`
  and `exec`s `claude` — breaks the canonical `claude` / `claude --chrome`
  invocation and the IDE-spawn path.
- Hard-coding the token in `.mcp.json` — `.mcp.json` is committed to the
  company repo; secrets must not be.

This decision does **not** apply to:

- Remote MCP endpoints that are **unauthenticated** (no secret to load —
  a plain `type: http` entry is fine).
- Remote MCP endpoints that authenticate via **OAuth interactive flow**
  (e.g. claude.ai connectors managed by Claude Code itself) — those are
  not configured in `.mcp.json` at all.
- Command-style stdio servers — they already use the
  `dotenv-cli -e .env.local --` prefix directly (no `mcp-remote`).

## Consequences

**Positive**
- One coherent pattern in `.mcp.json` regardless of whether the underlying
  MCP is a local command or a remote endpoint: `npx -y dotenv-cli -e
  .env.local -- <…>`. Operators learn one shape.
- No parent-shell secret export, no launcher script. The canonical
  `claude` / `claude --chrome` invocation continues to work as-is, every
  CLI flag and IDE integration included.
- Secrets stay in the gitignored, per-instance `.env.local` — same file
  the command-style servers already read — keeping the secret surface
  consolidated and out of shell rc files.
- Header substitution is performed by `mcp-remote` against the child
  `process.env`, so a missing or malformed token surfaces as a clear
  `InvalidTokenError` (or equivalent) at MCP startup rather than as a
  silent header omission.

**Negative / trade-offs**
- Adds `mcp-remote` as a community-maintained dependency in the call
  chain. Mitigated by `npx -y` (fetched on demand, pinnable per server),
  and by the dependency being narrow-purpose (a stdio↔HTTP/SSE MCP bridge,
  nothing else). License + maintenance posture should be checked in the
  CTO + CSO joint review when a new MCP_INVENTORY row chooses this shape
  (per the inventory's "Adding a new MCP server" §).
- A small startup overhead per session: one extra `npx` resolution +
  one extra Node process in the stdio chain. Bounded; not user-visible
  in normal operation.
- Lock-in to `mcp-remote`'s `--header` substitution semantics. If a
  provider needs more elaborate auth (signed requests, OAuth flows,
  rotating tokens), the right path is a dedicated `juvantlabs/*-mcp-server`
  wrapper, not a more elaborate `mcp-remote` invocation — consistent with
  the lean-canonical-MCP preference.

## Implementation

- `docs/MCP_INVENTORY.md` carries the canonical wiring shape under
  **"Wiring a remote authenticated MCP server"** (added in the same PR
  as this ADR). Each inventory row whose distribution column points at a
  remote endpoint references that section.
- New `.mcp.json` entries proposed via the `tool-matrix-change` decision
  path use this shape when the target is a remote authenticated MCP.
  CTO rejects `type: http` + `headers.${SECRET}` drafts and asks for the
  stdio-bridge rewrite before approval.

## References

- ADR 0001 — Skill-first architecture (defines the `.mcp.json` surface as
  the project-shared server registry).
- `docs/MCP_INVENTORY.md` — § "Wiring a remote authenticated MCP server"
  (new subsection added with this ADR).
- [`mcp-remote`](https://www.npmjs.com/package/mcp-remote) — community
  stdio↔HTTP/SSE bridge; performs `${VAR}` substitution on `--header`
  values from the child `process.env`.
- [`dotenv-cli`](https://www.npmjs.com/package/dotenv-cli) — per-command
  env-file loader; the canonical shape `dotenv-cli -e .env.local -- <cmd>`
  is already in use across command-style MCP entries.
