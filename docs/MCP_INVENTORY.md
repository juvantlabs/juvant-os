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
| ~~`github` (MCP)~~ | — | **removed (FEAT-052)** — GitHub access is now the `gh` CLI, not an MCP | ~~`@modelcontextprotocol/server-github`~~ (deprecated by upstream: *"Package no longer supported"*) | `GH_TOKEN`/`gh auth` | **dropped v1.8.0** |
| `cloud:write` | w | **eng-platform only** — abstract MCP entry resolved at adoption per `feature_toggles.cloud_provider` ∈ {azure, aws, gcp, none}; dropped when `none` | provider-specific (Azure: `azure-platform-mcp-server`; AWS/GCP: TBD) | pending (per-provider FEATs) |
| `npm:publish` | w | **eng-platform only** — canonical-helper publication (FEAT-024 path) | `npm` CLI + OIDC trusted publishing | shipped |
| `bank` | r | **CFO only** | provider-specific MCP, abstract-bound at company init (Finom: `juvantlabs/finom-mcp-server`, FEAT-011) | provider-specific (Finom: `FINOM_API_KEY`) | pending FEAT-011 (Finom) |
| `fattura_elettronica` | r | CFO | provider-specific MCP (Italy: `juvantlabs/aruba-fattura-mcp-server`, FEAT-012) | provider-specific (Aruba: `ARUBA_*`) | pending FEAT-012 (Aruba) |
| `social` | rw | CMO | abstract role — provider MCP **bound per instance** (e.g. Buffer.com, Hootsuite, Sprout Social); the adopter supplies and configures their own | provider-specific (e.g. Buffer: `BUFFER_ACCESS_TOKEN`) | abstract (adopter-bound) |

## GitHub access — `gh` CLI, not an MCP (FEAT-052)

GitHub is **not** an MCP server. The deprecated `@modelcontextprotocol/server-github`
(npm: *"Package no longer supported"*) was dropped in v1.8.0: its calls hung with
no client-side timeout, dead-locking agents until Claude Code's 600s stream
watchdog. GitHub access is now the `gh` CLI:

- **Mechanism**: `gh` / `gh api`, present in the relevant agents' Bash allow-lists.
- **Timeouts**: wrap every GitHub call with `helpers/with-timeout.sh <secs> gh …`
  so a wedged request fails fast instead of stalling (MCP calls could not be
  timeout-wrapped — that was the whole problem).
- **Read vs. write governance**: read-only `gh` (view/list/diff/checks/status,
  `gh api` GET, `repo clone`) is open to all gh-allowed agents. **Write**
  operations (`gh pr/issue/release/repo/secret/workflow/api` mutations) are gated
  by the Track-2d single-writer gate to **eng-lead** (project scope) /
  **eng-platform** (company scope) per §4 — the same policy as `git
  push/commit/merge`. Patterns: `bash-policy.json` `single_writer_gh_patterns`.

## Abstract roles vs. concrete servers

Three of the rows above are **abstract roles** that bind to provider-specific
servers at company init. The pattern lets the agent template stay
provider-agnostic while adopters pick whichever provider matches their stack.

| Abstract role | Provider examples |
|---|---|
| `bank` | Finom (FEAT-011), Mercury, Revolut Business, Wise, others |
| `fattura_elettronica` | Aruba (FEAT-012, Italy SDI), Spain SII, France Chorus Pro, Mexico CFDI, Poland KSeF |
| `social` | Buffer.com, Hootsuite, Sprout Social — the adopter binds their own per instance. No canonical server ships today (renamed from `buffer`, FEAT-056); an **optional** canonical MIT server (Buffer provider) is tracked in FEAT-057. |

Per `feedback_lean_canonical_mcp.md` (project memory): Juvant OS prefers
shipping a single canonical MIT-licensed `juvantlabs/*-mcp-server` per
provider, lean (read-only by default; helper layers in the agent template
not in the server). Community alternatives are evaluated as architectural
inspiration only — never bound directly without a security audit
(see the 2026-05-03 audit of `ftaricano/mcp-onedrive-sharepoint` published
at https://gist.github.com/juvantlabs/a9fe0a76a23b0c1260b1e0ad3194a6da
for the canonical case).

## Wiring a remote authenticated MCP server (`.mcp.json` shape)

When an inventory row points at a **remote** MCP endpoint (HTTP or SSE
transport) that requires an authenticated header — typical for third-party
SaaS MCPs — the entry in `.mcp.json` MUST use the **stdio bridge shape**
defined in [ADR 0022](adr/0022-remote-mcp-stdio-bridge.md), not the
`type: http` + `headers.${SECRET}` shape.

The reason is operational: `type: http` interpolates `${SECRET}` against
Claude Code's **parent process environment**, which forces every operator
to either export the secret shell-wide (leaks into unrelated processes)
or wrap `claude` in a launcher script (breaks the canonical
`claude` / `claude --chrome` invocation, IDE integrations, and every
CLI flag). The stdio bridge loads the secret per-server from the
gitignored `.env.local` into the **child** process — same `.env.local`
the command-style MCP entries already use.

**Canonical shape** (brand-agnostic placeholders):

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

- `<server>` — the inventory row name (e.g. the abstract role).
- `https://<remote-endpoint>/mcp` — the remote MCP URL published by the
  provider.
- `${MCP_TOKEN}` — the secret env-var name listed in the inventory row's
  "Auth env vars" column for that server.
- `.env.local` — the gitignored, per-instance env file at the repo root
  (already covered by the standard `.gitignore`).

The shape mirrors the canonical stdio + `dotenv-cli` shape used by
command-style servers (e.g. `m365-graph` → `dotenv-cli -e .env.local --
npx -y @juvantlabs/m365-graph-mcp-server`); the only addition is the
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote) bridge, which
performs `${VAR}` substitution on `--header` values from
`process.env` at child-process invocation time.

**Anti-patterns** (rejected by CTO at `tool-matrix-change` review):

- `type: http` + `headers: { "Authorization": "Bearer ${SECRET}" }` —
  requires parent-shell secret export. Inventory row goes back for
  rewrite as the stdio bridge.
- `scripts/start.sh` (or equivalent) launcher that sources `.env.local`
  and `exec`s `claude` — breaks the canonical `claude` invocation. Use
  the stdio bridge instead; the launcher becomes unnecessary.
- Hard-coding the secret in `.mcp.json` — `.mcp.json` is committed; the
  secret is not. Always reference an env var.

**When this section does NOT apply**:

- Unauthenticated remote MCP endpoints — a plain `type: http` entry is
  fine (no secret to load).
- claude.ai-managed OAuth connectors (e.g. `ms-graph`) — not configured
  in `.mcp.json`.
- Command-style stdio servers — already use the `dotenv-cli -e .env.local
  --` prefix directly; `mcp-remote` is not part of the chain.

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
- **`gh` write operations** (FEAT-052; replaces the former `github:write`
  MCP capability) to any agent except `eng-platform` at company scope
  (company repos only) and each project's `eng-lead` at that project's
  scope per §4 single-writer-per-scope (ADR 0014). Enforced by the
  Track-2d gate over `bash-policy.json` `single_writer_gh_patterns`, not by
  an MCP capability. Cross-scope writes are forbidden — `eng-platform`
  cannot write to a project repo; `eng-lead` cannot write to a company repo.
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
6. **Outbox rubric (per [ADR 0024](adr/0024-outbound-action-queue.md)).**
   For each **side-effecting** operation the new server exposes, evaluate
   whether it must route through the shared `outbox` table — see the
   rubric below. Record the decision (which operations queue, which
   dispatch inline) in the `tool-matrix-change`. This is part of the
   CTO + CSO review, not a separate gate.

## Outbound action queue (outbox) — activation rubric

Side-effecting MCP operations are not all equal. A **single canonical
`outbox` table** (Turso, `scripts/schema.sql`, per ADR 0024) stages the
ones that need it; the rest are called inline. The unit is the
**operation**, NOT the server — most servers have zero or one operation
that qualifies. **Never create a `<domain>_queue` per MCP**; everything
shares the one `outbox` via `(target_mcp, operation)` + JSON `payload`.

**An operation routes through the outbox if *any* of these hold:**

| Trigger | Example |
|---|---|
| **Accumulation / batch** | invoices accrue before the Aruba submission window |
| **Approval gate** | the CEO must commit before the external effect (default for money / legal / public visibility) |
| **Throttle / quota** | a plan cap or rate limit (e.g. a free social scheduler ~10 queued posts/channel) |
| **Retry / durability** | a send can fail and the *intent* must survive |
| **Scheduling** | the send must occur at a specific future time (scheduled posts, payment on due date) |

**If none hold** — pure read, or a genuinely fire-and-forget low-stakes
call — the operation bypasses the outbox with a direct MCP call. No table,
no row.

**First consumer (FEAT-056): `social` / `schedule-post`.** The CMO's social
scheduling routes through the outbox because **CEO approval is required before
publication** (a standing invariant) and posts are **scheduled** for a future
time — both framework-level rubric triggers, true on any provider or plan. CMO
stages a `draft` row (`target_mcp='social'`, `operation='schedule-post'`); the
CEO commit flips it to `approved`; the drain dispatches approved-and-due rows to
the bound scheduler MCP. A provider **plan cap** (e.g. Buffer Free's ~10/channel)
is *not* a framework concern — it is configured per instance: where a cap exists
the instance sets the drain's per-target throttle to it; on an uncapped (paid)
plan there is nothing to throttle and the drain dispatches as approved. `social`
is an abstract role — the adopter binds a provider (e.g. Buffer.com) per instance
— so the `payload` is provider-neutral and the bound MCP performs the dispatch.
See `agents/company/cmo.md` § "Content Scheduling Protocol".

Lifecycle and ownership:
- The drafting agent inserts a `draft` row (`created_by`).
- The CEO commit via CoS flips it to `approved` (`approved_by`) — the
  outbox **is** the register of "what awaits the CEO commit"; there is no
  separate approval store. Autonomous external effect on a non-`approved`
  row is forbidden (`SYSTEM_INVARIANTS.md` §4 — the commit is the gate).
- Dispatch (`approved → sent`) is **agent-mediated in v1.0** (CoS drains
  approved-and-due rows during a session, honoring per-target throttle;
  see `JUVANT_OS.md` § "Outbox — staged outbound actions"). The scheduled
  drain helper (`helpers/drain-outbox.sh`) handles readiness surfacing and
  retry/dead-letter reconciliation; fully autonomous cloud-routine drain
  is the v1.1+ evolution. Failed dispatch bumps `retry_count` and falls to
  `adapter_dead_letters` once exhausted.

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
- **abstract (adopter-bound)** — an abstract role the framework defines but
  ships **no** canonical server for; the adopter binds a provider-specific
  MCP per instance (e.g. `social` → Buffer.com / Hootsuite / Sprout). Treated
  by the Step 8.5 cross-check like `pending FEAT-XXX` — warn, allow pass; the
  agent runs in restricted mode for the capability until the adopter binds a
  provider.
