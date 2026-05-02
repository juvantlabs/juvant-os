# ADR 0002 — Turso as the cloud state store

## Status

Accepted (2026-04-23). Promoted from `juvantlabs/juvant-os-pm#2` (ARCH-002) on
2026-05-02.

## Context

Juvant OS state has two consumers: internal agents running on the CEO's Mac, and
External Portal agents running on Azure (v1.1). Storing state on a local SQLite
file would either:

- Couple the portal to the Mac (over Tailscale/VPN, with the Mac as a single
  point of failure), or
- Require a separate sync layer between the two surfaces.

LibSQL (Turso) is SQLite, distributed at the edge, with the same schema and the
same `@libsql/client` driver locally and remotely. It dissolves the two-tier
problem into one tier.

## Decision

`state.db` lives on Turso (LibSQL). The same schema applies whether running
locally for testing or in the cloud for production. `@libsql/client` is the
canonical driver. There is one DB per scope:

- `company-<slug>` — company scope (e.g. `company-acme`).
- `project-<slug>` — per-project scope (e.g. `project-hardys`).

Database provisioning happens through the `JUVANT_OS.md` company-setup wizard
(Step 2: Database setup) — CLI path uses the provider's CLI; Manual path
captures an existing endpoint and token. Local SQLite is supported for testing
but disables the v1.1 portal.

## Consequences

Positive:

- The External Portal reads agent status (`agents.status`) without depending on
  the Mac being online.
- Migrations apply identically to local and remote; `scripts/migrate.sh` is the
  single tool.
- Provider choice is open: Turso Cloud, Azure, AWS, GCP, or local — set per
  instance in `.juvant/config.json`.

Negative:

- A network round-trip per write. Bounded by edge replicas and the embedded
  reader pattern; not material for the system's per-second write rate.
- Credentials must be managed. They live in `.juvant/config.json` (gitignored)
  and are loaded by hooks and MCP servers — they are never written into the
  context window.

## Implementation

- `scripts/schema.sql` — 20 tables.
- `scripts/migrate.sh` — applies the schema to a configured DB.
- `.juvant/config.json` — endpoint + token per scope (gitignored).
- `JUVANT_OS.md` § "Company setup" Step 2 — DB wizard (CLI / Manual).
- `agents/**/*.md` — every agent reads/writes Turso via the `turso` MCP server.

## References

- `SYSTEM_INVARIANTS.md` — multi-DB architecture per scope.
- `juvantlabs/juvant-os-pm/docs/session-commit-p1.md` — Database Setup Wizard
  rationale.
