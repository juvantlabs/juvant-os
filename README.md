# Juvant OS

**The open-source multi-agent operating system that runs your company with Claude.**

---

## What is Juvant OS?

Juvant OS is a Skill-first multi-agent system built on Claude Code.
You open Claude Code in a folder. You speak to the Skill. The Skill orchestrates your entire company.

No CLI. No daemon. No installation. No commands to remember.

```
cd ~/my-company
claude
"Initialize Juvant OS for Acme Corp"
```

---

## How it works

```
JUVANT_OS.md            ← The Skill. The orchestrator. The only entry point.
agents/company/         ← 9 mandatory + 3 toggle-gated company agents (CoS, CFO, CLO, CMO, CCO, CHRO, CSO, CEthO, CTO + eng-platform default-on + optional CRO/VPE) — source of truth
agents/projects/        ← 8 project agents (PCA, Product Lead, Design Lead, Eng Lead, Eng/*) — source of truth
.claude/agents/         ← Symlinks into agents/<scope>/ — runtime registration for Task spawn
hooks/                  ← 7 lifecycle bash scripts
scripts/schema.sql      ← Turso database schema
helpers/                ← Scheduled scripts populating Turso queues (FEAT-007)
plugins/portal-bridge/  ← Channel — bridge between Azure Portal and agent sessions (v1.1)
plugins/teams-meeting/  ← Channel — Teams meeting bot, CoS silent co-pilot (v1.1)
```

Per [ADR 0014](docs/adr/0014-tech-leadership-restructure.md), v0.8.0 renamed
roles for industry alignment: company `ca` → `cto` (Chief Architect →
Chief Technology Officer); at project scope `cto`/`coo`/`cdo`/`cpo` →
`pca`/`eng-lead`/`design-lead`/`product-lead`. Project-VPE was removed
(absorbed by Eng Lead); VPE returns at company scope as an opt-in
cross-project aggregator. Adopters on v0.7.x migrate via
`bash scripts/migrate.sh --from=v0.7 --to=v0.8` (see CHANGELOG v0.8.0).

Agent definitions live under `agents/<scope>/<role>.md` (the documented home,
where adopters navigate and review changes). Claude Code's Task tool reads
subagent definitions from `.claude/agents/<role>.md`; the OSS template ships
relative symlinks from there into `agents/<scope>/` so a single substitution
during company-init updates both views (see [ADR 0010](docs/adr/0010-compiled-agent-registration.md)).

State lives in [Turso](https://turso.tech) — a cloud SQLite database shared across all agent sessions.
Agents communicate through Turso, not through each other directly.

---

## Plugins

### Inbound mail (NOT a plugin)

Inbound M365 mail in v1.0 is **on-demand read** via the existing `ms-graph`
claude.ai connector, dispatched by CoS to mail-enabled agents
(CFO/CLO/CCO/CMO). No polling, no auto-emit, no plugin. Mailbox bindings
captured at company init in `.juvant/config.json` `mail_enabled_agents.<role>`.
See [ADR 0009](docs/adr/0009-mail-via-ms-graph-on-demand.md). Reactive push
lands in v1.1+ via FEAT-016 (`m365-mail-mcp-server`) + FEAT-015 webhook
receiver + OP-004 cloud agents.

### `plugins/portal-bridge/`
MCP server. Bridge between the External Portal (Azure Static Web App) and Claude Code agent sessions.
Reads `agents.status` from Turso to serve live 🟢/🔴 availability to the portal.
Applies `disclosure_policies` filter before passing any data to portal agent variants.
Manages one dedicated session per external counterparty.
Powers two separate portals:
- **Service Portal** — ongoing relationships (accountant, lawyer, partners)
- **Demo Portal** — live sales demos (CCO-led, prospect-facing)

### `plugins/teams-meeting/`
Native Claude Code Channel plugin. Registers CoS as a silent bot participant in Teams meetings.
Reads live transcript via Graph API every ~15 seconds.
CoS analyzes transcript and whispers suggestions privately to you.
If you @mention CoS by name in the meeting chat, it responds publicly — visible to all participants.

```
Client: "How do you handle GDPR?"
CoS → private to you: "Suggest: Azure West Europe, GDPR Art. 28, DPA available on request"

You: "@Atlas can you summarize our data residency approach?"
CoS → public in meeting chat: "All data processed in Azure West Europe..."
```

> All three plugins are **v1.1 features** — not required for Alpha/Beta/v1.0.

---

## Supported platforms (v1.0)

Juvant OS runs anywhere [Claude Code](https://code.claude.com) does, **plus a
bash interpreter** for the hooks + helpers in `hooks/*.sh` and `helpers/*.sh`.

| Platform | Hooks | Schedule install (`install-schedules.sh`) | Notes |
|---|---|---|---|
| **macOS 13+** (Ventura or later) | ✅ | ✅ launchd plists | Default development target |
| **Linux** (Ubuntu 22.04+, Debian 12+, …) | ✅ | ✅ cron via crontab | Recommended for cloud / always-on hosts |
| **Windows + WSL2** (Ubuntu) | ✅ | ✅ cron in WSL | **Recommended Windows path** — WSL2 background services run cron even when you're in Windows |
| **Windows + Git Bash** (no WSL) | ✅ hooks work | ⚠️ scheduling NOT supported in v1.0 | Hooks run inside Claude Code; for scheduling, install Task Scheduler entries manually pointing at `C:\Path\to\Git\bin\bash.exe <helper>.sh`. Native Windows Task Scheduler integration tracked as v1.1 OP. |
| **Windows native** (no bash) | ❌ | ❌ | Not supported in v1.0. Use WSL2. |

The MCP servers shipped under `juvantlabs/*-mcp-server` (currently
`m365-graph-mcp-server`, future `finom-mcp-server`, `aruba-fattura-mcp-server`,
`m365-mail-mcp-server`) are **fully cross-platform** — they run via `npx` on Node ≥
20 and need no shell. Only the `juvant-os` template's hooks + helpers depend on
bash.

### Why bash?

The hooks + helpers are bash because (a) Claude Code's hook contract registers
`{"command": "bash hooks/*.sh"}` directly, no language abstraction required, and
(b) the helpers do simple shell work (curl, jq, turso, gpg) where bash is the
shortest path. v1.1+ may add a portability layer if non-WSL Windows demand
materializes.

---

## Quick start

### 1. Create a private repo for your company

The OSS template at `juvantlabs/juvant-os` is meant to be **mirror-pushed** to your
own private repo, not GitHub-forked. This decouples your company's repo visibility
from the OSS template's visibility (the template will eventually go fully public;
your per-company instance stays private regardless).

```bash
# Create the empty private repo in your GitHub org
gh repo create <your-org>/<company-slug> \
  --private \
  --description "<Company Name> — Juvant OS instance"

# Bare clone of the OSS template
git clone --bare git@github.com:juvantlabs/juvant-os.git

# Mirror push to your new repo (standalone, NOT a GitHub fork)
cd juvant-os.git
git push --mirror git@github.com:<your-org>/<company-slug>.git

# Cleanup
cd .. && rm -rf juvant-os.git

# Working clone
git clone git@github.com:<your-org>/<company-slug>.git
cd <company-slug>

# Optional: track upstream for future syncs
git remote add upstream git@github.com:juvantlabs/juvant-os.git
```

### 2. Open Claude Code and initialize

```bash
claude
> Initialize Juvant OS for <Company Name>
```

The Skill (`JUVANT_OS.md`) will guide you through:
- Choosing your database (local / Turso Cloud / Azure / AWS / GCP) — CLI or Manual setup
- Binding your bank provider (Finom / Mercury / Revolut / Wise / other)
- Configuring notifications (Telegram bot, Teams webhook, Morning Brief time)
- Setting up counterparties (accountant, lawyer, partners)
- Generating agent names and compiling templates
- Running the **Bootstrap Protocol** (`SYSTEM_INVARIANTS.md` §1) — CEO-only one-shot
  approval of the founding manifestos, followed by the CSO `bootstrap_baseline` audit

### 3. Commit your compiled setup

```bash
git add agents/ scripts/ hooks/ .claude/settings.json
git commit -m "init(<company-slug>): bootstrap company-scope agents"
git push
```

See [`JUVANT_OS.md`](JUVANT_OS.md) Appendix B for the canonical first-time setup procedure.

### Adding the github MCP server

The OSS template ships `.mcp.json` empty — adopters wire their MCP
servers explicitly. The github MCP server is the most common addition;
CSO uses it for branch-protection checks; eng-platform writes the
company repo + each project's Eng Lead writes its own project repo per
§4 single-writer-per-scope (ADR 0014). To enable:

1. Create a GitHub Personal Access Token (PAT) with `repo` + `read:org`
   scope at https://github.com/settings/tokens.
2. Add it to your shell environment:
   ```bash
   export GITHUB_PERSONAL_ACCESS_TOKEN="ghp_..."
   ```
   (Add to `~/.zshrc` / `~/.bashrc` / your shell init for persistence.)
3. Edit `.mcp.json` to register the server:
   ```json
   {
     "mcpServers": {
       "github": {
         "command": "npx",
         "args": ["-y", "@modelcontextprotocol/server-github"],
         "env": {
           "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_PERSONAL_ACCESS_TOKEN}"
         }
       }
     }
   }
   ```
4. Restart Claude Code (the change is picked up at session start).

`.mcp.json` is committed to the per-company repo (it does NOT contain
the token — only references the env var). The token itself stays in
your shell env, never committed.

### Permission modes for sandbox / test contexts

The OSS template ships `.claude/settings.json` with
`defaultMode: "acceptEdits"` — Edit/Write are auto-accepted, Bash
prompts on each call. Production-safe.

For sandbox and test contexts (testco runs, throwaway initializations)
the prompt cadence can be excessive — especially during the CSO
bootstrap audit which issues many tool calls in sequence. Two opt-out
flags are available:

```bash
# Auto-accept anything matching the allow-list, never prompt.
# Trusted local sessions; respects deny lists in hooks/bash-policy.json.
claude --permission-mode auto

# Bypass all permission checks (= --dangerously-skip-permissions).
# Sandboxes only; recommended for `/tmp/<testco>` directories
# where blast radius is contained.
claude --permission-mode bypassPermissions
```

Document your choice per-instance in `.claude/settings.local.json`
or invoke `claude` with the explicit flag each time.

---

## Agents

### Company agents

**Mandatory (9):**

| Role | Default name | Model | Domain |
|---|---|---|---|
| CoS | Atlas | Opus 4.7 | Orchestration, routing, proxy |
| CFO | Theos | Sonnet 4.6 | Finance, banking, invoices |
| CLO | Lex | Opus 4.7 | Legal, contracts, IP, disclosure |
| CMO | Mira | Sonnet 4.6 | Brand identity, marketing, communication, brand-spec validator/advisory (ADR 0015) |
| CCO | Clio | Sonnet 4.6 | Sales, partnerships, revenue |
| CHRO | Sage | Sonnet 4.6 | People, ranking, versioning |
| CSO | Shield | Opus 4.7 | Cybersecurity, system audit |
| CEthO | Vera | Opus 4.7 | AI ethics, disclosure ethics |
| CTO | Arch | Opus 4.7 | Agent tool matrix, cross-project tech standards, architectural principles (renamed from `ca` per ADR 0014 §1) |

**Toggle-gated (3, set at company init):**

| Role | Default name | Model | Toggle | Default | Domain |
|---|---|---|---|---|---|
| eng-platform | Hephaestus | Sonnet 4.6 | `eng_platform_enabled` | **true** | Company-scope sole writer per §4: company repos + cloud control plane + npm registry for canonical helpers (ADR 0014 §3, ADR 0016) |
| CRO | Lumen | Sonnet 4.6 | `cro_enabled` | false | Research synthesis with citation discipline |
| VPE | Helm | Sonnet 4.6 | `vpe_enabled` | false | Cross-project Eng/* aggregator; recommended only for ≥2 active projects (ADR 0014 §2) |

### Project agents

8 per project (was 9 in v0.7; project-VPE removed per ADR 0014 §2; aggregator function absorbed by Eng Lead).

| Role | Model | Domain |
|---|---|---|
| PCA | Sonnet 4.6 | Project Chief Architect; project-scope tech direction + Tier 1 manifesto approval (renamed from project `cto` per ADR 0014 §1) |
| Product Lead | Sonnet 4.6 | Product direction, PRDs, GitHub spec authoring (renamed from `cpo`) |
| Design Lead | Sonnet 4.6 | Design system, UX research, accessibility, project visual identity (brand-spec authoring per ADR 0015) (renamed from `cdo`) |
| Eng Lead | Sonnet 4.6 | Sole GitHub writer at project scope per §4; engineering execution, Eng/* delegation, release/deployment specs, operational ownership (renamed from `coo`, absorbs project-VPE function) |
| Eng/API | Haiku 4.5 | Endpoints, OpenAPI |
| Eng/Backend | Haiku 4.5 | Business logic, services |
| Eng/Frontend | Haiku 4.5 | UI components |
| Eng/AI | Haiku 4.5 | Models, pipelines |

---

## Roadmap

| Milestone | What | Status |
|---|---|---|
| **Alpha** | `JUVANT_OS.md` Skill + 7 lifecycle hooks + 19 subagent templates + Bootstrap Protocol §1 | ✅ [v0.4.0](https://github.com/juvantlabs/juvant-os/releases/tag/v0.4.0) (2026-05-02) |
| **OSS template defaults** | CODEOWNERS, CI lint, branch-protection-spec, MCP_INVENTORY | ✅ [v0.5.0](https://github.com/juvantlabs/juvant-os/releases/tag/v0.5.0) (2026-05-03) |
| **Batch testco infra** | ADR 0012 batch mode + driver + fixtures + opt-in CI | ✅ v0.6/v0.7 series |
| **Tech-leadership restructure** | ADR 0014 (ca→cto, project rename, VPE toggle, eng-platform expansion, eng-platform-spec class) + ADR 0015 (brand-spec authority + 3-mode pattern) + ADR 0016 (framework scope position) | ✅ [v0.8.0](https://github.com/juvantlabs/juvant-os/releases/tag/v0.8.0) + [v0.8.1](https://github.com/juvantlabs/juvant-os/releases/tag/v0.8.1) (2026-05-10) |
| **Beta** | M365 mail channel plugin + Desktop Scheduled Tasks (Morning Brief, bank polls, fiscal deadlines) | Planned |
| **v1.0** | Test scenarios green (subagent evals + hook tests + integration) | Planned |
| **v1.1** | External Service Portal + Demo Portal + Teams Meeting Bot + Finom MCP + Aruba e-invoice MCP + Webhook Services + multi-principal governance | Planned |

Tracked work: [`juvantlabs/juvant-os-pm`](https://github.com/juvantlabs/juvant-os-pm/issues).

---

## Multi-company usage

Each company is a fork of this repo in its own folder:

```
cd ~/acme    → claude   (manages Acme Corp)
cd ~/contoso → claude   (manages Contoso Ltd)
```

Each fork has its own Turso database, its own compiled agents, its own `.juvant/config.json`.

---

## What goes in `.gitignore`

```
.juvant/config.json     ← secrets (Turso token, Telegram, Teams webhook)
.juvant/sessions/       ← local session state
.env
*.env.*
node_modules/
.DS_Store
logs/
.claude/local/
```

---

## State

Juvant OS uses [Turso](https://turso.tech) (LibSQL) as its cloud state store.
All agent sessions share the same Turso database — this is how agents maintain shared memory across restarts, devices, and parallel sessions.

Turso is optional: you can run with a local SQLite file, but v1.1 portal and meeting features will not be available.

---

## Documentation

- [`SYSTEM_INVARIANTS.md`](SYSTEM_INVARIANTS.md) — canonical cross-cutting invariants
  (Bootstrap Protocol §1, naming convention §2, disclosure fallback cascade §3,
  single-writer invariant §4, universal CONFIDENTIAL list §5, spec authorization
  matrix §6, architectural principles §7).
- [`JUVANT_OS.md`](JUVANT_OS.md) — the Skill orchestrator (read at every SessionStart).
- [`docs/adr/`](docs/adr/) — Architecture Decision Records (Nygard form, with index
  and modification governance).
- [`CHANGELOG.md`](CHANGELOG.md) — release history.
- [Releases](https://github.com/juvantlabs/juvant-os/releases) — tagged releases with
  detailed notes.
- [`juvantlabs/juvant-os-pm`](https://github.com/juvantlabs/juvant-os-pm) — planning
  docs (`build-plan.md`, `critical-review.md`, design rationale) and FEAT/OP issue
  tracker.

---

## License

MIT — see [LICENSE](LICENSE)
