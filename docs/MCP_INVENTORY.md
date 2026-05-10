# MCP Inventory

Normative manifest of every MCP server the Juvant OS template references.
The `agent_tool_matrix` v0 default seed binds agents to abstract roles
listed here; each adopter binds the abstract role to a concrete server at
company init.

This file is the source of truth for the wizard's Step 8.5 cross-check
(see `JUVANT_OS.md`): any agent referencing an MCP server not in this
inventory triggers a build-fail with a remediation hint.

## Inventory

| Server | Scope | Owning agent(s) | Distribution | Auth env vars | Status |
|---|---|---|---|---|---|
| `turso` | rw | all agents | `turso` CLI / `@libsql/client` | `TURSO_URL`, `TURSO_AUTH_TOKEN` | shipped |
| `ms-graph` | r | CFO, CLO, CMO, CCO, Design Lead, CoS, CRO | claude.ai connector (read tools) | OAuth delegated (claude.ai-managed) | shipped (read-only) |
| `m365-graph` | rw | CFO, CLO, CMO, CCO, Design Lead, CoS, CRO | [`@juvantlabs/m365-graph-mcp-server@0.1.3`](https://www.npmjs.com/package/@juvantlabs/m365-graph-mcp-server) (FEAT-014) | `M365_CLIENT_ID`, `M365_CLIENT_SECRET`, `M365_TENANT_ID` | shipped |
| `github:read` | r | CTO, CSO, PCA, Product Lead, Design Lead, VPE (if enabled), eng-platform, eng-* | `@modelcontextprotocol/server-github` | `GITHUB_TOKEN` | shipped |
| `github:write` | w | **eng-platform** (company repos) + **each project's Eng Lead** (that project's repos) per §4 single-writer-per-scope (ADR 0014) | `@modelcontextprotocol/server-github` | `GITHUB_TOKEN` | shipped |
| `cloud:write` | w | **eng-platform only** — abstract MCP entry resolved at adoption per `feature_toggles.cloud_provider` ∈ {azure, aws, gcp, none}; dropped when `none` | provider-specific (Azure: `azure-platform-mcp-server`; AWS/GCP: TBD) | pending (per-provider FEATs) |
| `npm:publish` | w | **eng-platform only** — canonical-helper publication (FEAT-024 path) | `npm` CLI + OIDC trusted publishing | shipped |
| `bank` | r | **CFO only** | provider-specific MCP, abstract-bound at company init (Finom: `juvantlabs/finom-mcp-server`, FEAT-011) | provider-specific (Finom: `FINOM_API_KEY`) | pending FEAT-011 (Finom) |
| `fattura_elettronica` | r | CFO | provider-specific MCP (Italy: `juvantlabs/aruba-fattura-mcp-server`, FEAT-012) | provider-specific (Aruba: `ARUBA_*`) | pending FEAT-012 (Aruba) |
| `buffer` | rw | CMO | TBD (third-party SaaS scheduler) | `BUFFER_ACCESS_TOKEN` | not yet specified |

## Abstract roles vs. concrete servers

Three of the rows above are **abstract roles** that bind to provider-specific
servers at company init. The pattern lets the agent template stay
provider-agnostic while adopters pick whichever provider matches their stack.

| Abstract role | Provider examples |
|---|---|
| `bank` | Finom (FEAT-011), Mercury, Revolut Business, Wise, others |
| `fattura_elettronica` | Aruba (FEAT-012, Italy SDI), Spain SII, France Chorus Pro, Mexico CFDI, Poland KSeF |
| `buffer` | Buffer.com, Hootsuite, Sprout Social (whichever the company uses) |

Per `feedback_lean_canonical_mcp.md` (project memory): Juvant OS prefers
shipping a single canonical MIT-licensed `juvantlabs/*-mcp-server` per
provider, lean (read-only by default; helper layers in the agent template
not in the server). Community alternatives are evaluated as architectural
inspiration only — never bound directly without a security audit
(see the 2026-05-03 audit of `ftaricano/mcp-onedrive-sharepoint` published
at https://gist.github.com/juvantlabs/a9fe0a76a23b0c1260b1e0ad3194a6da
for the canonical case).

## Universal Boundaries (per `SYSTEM_INVARIANTS.md` §4)

The following MCP grants are **forbidden** under any rationale, even at
CTO's discretion. The wizard's Step 8.5 cross-check rejects any matrix
binding that violates these:

- **`bank:write`** to any agent — would require ratifying a future
  `treasury` role with joint approval per §4. Not on the roadmap.
- **Mail-send capability** (FEAT-016 `m365-mail-mcp-server`, v1.1+) to any
  agent except v1.1 portal variants
  (`cfo-portal`, `clo-portal`, `cco-portal`, `cmo-portal`). Autonomous
  send is never granted; portal variants use two-phase confirmation per
  handbook ADR 0002.
- **`github:write`** to any agent except `eng-platform` at company scope
  (company repos only) and each project's `eng-lead` at that project's
  scope per §4 single-writer-per-scope (ADR 0014). Cross-scope writes
  are forbidden — `eng-platform` cannot write to a project repo;
  `eng-lead` cannot write to a company repo.
- **`cloud:write`** to any agent except `eng-platform` (per ADR 0014 §3).
- **`npm:publish`** to any agent except `eng-platform` for the
  canonical-helper publication path (FEAT-024). Every publish requires
  CEO approval per the spec routing — autonomous publishing forbidden.
- **`state.db` read AND external-channel send in the same matrix row** —
  collapses the disclosure boundary. **Exception**: channels of class
  `<channel>:send-ceo-only` (e.g. `telegram:send-ceo-only`) are not
  external-channel sends for the purposes of this clause; they are
  operator-direct notifications bound to a config-resolved recipient
  that is the human principal already in the trust loop. CoS holding
  `[turso, telegram:send-ceo-only]` does not violate this boundary.
  See [ADR 0011](adr/0011-ceo-direct-channel-class.md) for the
  channel-class definition and the Step 4 confirmation gate that
  enforces the operator-recipient contract.
- **Unrestricted `Bash`** to any external-facing agent (portal / demo
  variants).

## Wizard Step 8.5 cross-check

After seeding `agent_tool_matrix` v0 (Step 8), the wizard validates each
matrix row against this inventory. Failure modes:

- **Server not in inventory** → build-fail, hint: "Add a new row to
  `docs/MCP_INVENTORY.md` and open a `tool-matrix-change` decision per
  `SYSTEM_INVARIANTS.md` §6."
- **Universal Boundary violation** → build-fail, hint: "This grant is
  forbidden by `SYSTEM_INVARIANTS.md` §4. The wizard cannot proceed."
- **Status `pending FEAT-XXX`** → warn, allow pass: "MCP server is
  not yet shipped. Agent will operate in restricted mode for this
  capability until the FEAT lands."

## Adding a new MCP server

When a new MCP server enters the system (typically as a FEAT-XXX
deliverable):

1. Update this file with a new row (server, scope, owner, distribution,
   auth env vars, status).
2. Update `agent_tool_matrix` v0 default seed if the new server affects
   default tool grants (CTO proposes via `tool-matrix-change` decision).
3. **CTO + CSO joint review** — additions to the inventory require both.
   CSO checks the security posture of the new server (license, audit
   status if community-built, dependency tree). CTO checks architectural
   fit (lean canonical, scope qualifier appropriate, no Universal
   Boundary violation, scope boundaries per
   [handbook ADR 0003](https://github.com/juvantlabs/handbook/blob/main/docs/adr/0003-mcp-server-scope-boundaries.md)
   — one MCP per threat-model boundary; outbound-only notifications go
   through webhooks not MCP).
4. CEO approves.
5. `eng-platform` executes the matrix change via `install-spec` at
   company scope (or each project's `eng-lead` at project scope)
   per `SYSTEM_INVARIANTS.md` §6 + §4 single-writer-per-scope (ADR 0014).

## Status legend

- **shipped** — production-ready, integrated in agent_tool_matrix v0 seed.
- **shipped (read-only)** — read tools available; write tools pending a
  named FEAT.
- **pending FEAT-XXX** — referenced by agent templates but the server
  itself is not yet built. Adopters operate in restricted mode for this
  capability until the FEAT lands.
- **not yet specified** — referenced in design intent but no FEAT opened.
  Adopters who need the capability open a request issue on
  `juvantlabs/juvant-os-pm`.
