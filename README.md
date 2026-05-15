# Juvant OS

**The open-source multi-agent operating system that runs your company with Claude.**

[![CI](https://github.com/juvantlabs/juvant-os/actions/workflows/lint.yml/badge.svg)](https://github.com/juvantlabs/juvant-os/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/juvantlabs/juvant-os)](https://github.com/juvantlabs/juvant-os/releases)
[![Built with Claude](https://img.shields.io/badge/Built%20with-Claude-blueviolet)](https://www.anthropic.com/claude)

---

## What is Juvant OS?

Juvant OS is a Skill-first multi-agent system built on Claude Code. You open
Claude Code in a folder, speak to the Skill, and the Skill orchestrates your
entire company — routing tasks, managing context, and coordinating a team of
specialized AI agents across finance, legal, marketing, engineering, and more.

There is no CLI, no daemon, no installation, and no commands to remember. The
only entry point is the Skill.

```
cd ~/my-company
claude
"Initialize Juvant OS for Acme Corp"
```

State is stored in [Turso](https://turso.tech) (LibSQL), a cloud SQLite database
shared across all agent sessions. This is how agents maintain shared memory
across restarts, devices, and parallel sessions. A local SQLite file is also
supported for development and single-machine setups.

---

## How it works

```
JUVANT_OS.md            ← The Skill. The orchestrator. The only entry point.
agents/company/         ← Company-scope agent source templates
agents/projects/        ← Project-scope agent source templates
.claude/agents/         ← Symlinks into agents/<scope>/ — runtime registration
hooks/                  ← 7 lifecycle bash scripts
scripts/schema.sql      ← Turso database schema
helpers/                ← Scheduled scripts populating Turso queues
```

Each company is a mirror of this template in its own private repository. Multiple
companies run independently — each with its own Turso database, compiled agents,
and configuration:

```
cd ~/acme    → claude   (manages Acme Corp)
cd ~/contoso → claude   (manages Contoso Ltd)
```

---

## Agents

### Company scope

**Mandatory (9):**

| Role | Default name | Model | Domain |
|---|---|---|---|
| CoS | Atlas | Opus 4.7 | Orchestration, routing, CEO proxy |
| CFO | Theos | Sonnet 4.6 | Finance, banking, invoices |
| CLO | Lex | Opus 4.7 | Legal, contracts, IP, disclosure |
| CMO | Mira | Sonnet 4.6 | Brand, marketing, communications |
| CCO | Clio | Sonnet 4.6 | Sales, partnerships, revenue |
| CHRO | Sage | Sonnet 4.6 | People, agent ranking, versioning |
| CSO | Shield | Opus 4.7 | Security, system audit |
| CEthO | Vera | Opus 4.7 | AI ethics, disclosure ethics |
| CTO | Arch | Opus 4.7 | Agent tool matrix, cross-project tech standards |

**Toggle-gated (3, enabled at company init):**

| Role | Default name | Model | Default | Domain |
|---|---|---|---|---|
| eng-platform | Hephaestus | Sonnet 4.6 | **on** | Company-scope sole writer: repos, cloud control plane, npm |
| CRO | Lumen | Sonnet 4.6 | off | Research synthesis with mandatory citation discipline |
| VPE | Helm | Sonnet 4.6 | off | Cross-project engineering aggregator (recommended for ≥2 active projects) |

### Project scope

8 agents per project:

| Role | Model | Domain |
|---|---|---|
| PCA | Sonnet 4.6 | Project Chief Architect — tech direction and Tier 1 manifesto approval |
| Product Lead | Sonnet 4.6 | Product direction, PRDs, GitHub spec authoring |
| Design Lead | Sonnet 4.6 | Design system, UX research, accessibility |
| Eng Lead | Sonnet 4.6 | Sole GitHub writer at project scope; engineering execution and delegation |
| Eng/API | Haiku 4.5 | Endpoints, OpenAPI |
| Eng/Backend | Haiku 4.5 | Business logic, services |
| Eng/Frontend | Haiku 4.5 | UI components |
| Eng/AI | Haiku 4.5 | Models, pipelines |

---

## Quick start

### 1. Create a private repo for your company

Mirror-push the OSS template into a new private repo in your organization.
This keeps your company's repository independent from the upstream template —
you can pull upstream improvements selectively, on your schedule.

```bash
# Create the empty private repo
gh repo create <your-org>/<company-slug> \
  --private \
  --description "<Company Name> — Juvant OS instance"

# Bare clone of the OSS template
git clone --bare git@github.com:juvantlabs/juvant-os.git

# Mirror push
cd juvant-os.git
git push --mirror git@github.com:<your-org>/<company-slug>.git

# Cleanup and working clone
cd .. && rm -rf juvant-os.git
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

The Skill will guide you through:

- Company identity and document storage (OneDrive or Google Drive)
- Database setup (local SQLite or Turso Cloud)
- Notifications (Telegram bot, Teams webhook, Morning Brief schedule)
- Counterparties (accountant, lawyer, partners, clients)
- Agent name generation and template compilation
- The **Bootstrap Protocol** — CEO-only founding manifesto approval followed
  by the CSO `bootstrap_baseline` security audit

### 3. Wire the GitHub MCP server (recommended)

The OSS template ships `.mcp.json` empty. The GitHub MCP server is the most
common addition — it gives CSO read access for branch-protection checks and
eng-platform write access for repository management.

1. Create a GitHub PAT with `repo` + `read:org` scope.
2. Export it in your shell: `export GITHUB_PERSONAL_ACCESS_TOKEN="ghp_..."`
3. Register it in `.mcp.json`:

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_PERSONAL_ACCESS_TOKEN}" }
    }
  }
}
```

`.mcp.json` is committed to your company repo. The token stays in your shell
environment and is never committed.

### 4. Commit your compiled setup

```bash
git add agents/ scripts/ hooks/ .claude/settings.json
git commit -m "init(<company-slug>): bootstrap company-scope agents"
git push
```

---

## Supported platforms

| Platform | Hooks | Scheduled helpers | Notes |
|---|---|---|---|
| **macOS 13+** | ✅ | ✅ launchd | Default development target |
| **Linux** (Ubuntu 22.04+, Debian 12+) | ✅ | ✅ cron | Recommended for always-on hosts |
| **Windows + WSL2** | ✅ | ✅ cron in WSL | Recommended Windows path |
| **Windows + Git Bash** | ✅ hooks | ⚠️ manual scheduling | Scheduling not auto-configured in v1.0 |
| **Windows native** | ❌ | ❌ | Not supported — use WSL2 |

Hooks and helpers are bash. The MCP servers under `juvantlabs/*-mcp-server`
run via `npx` on Node ≥ 20 and are fully cross-platform.

---

## Roadmap

| Milestone | What you get | Status |
|---|---|---|
| **v0.4** | Company initialization wizard, 9 founding agents, 3 toggle-gated roles, Bootstrap Protocol with CSO security audit | ✅ |
| **v0.5** | CI lint, CODEOWNERS, branch-protection spec — ready for adopter forks | ✅ |
| **v0.6 / v0.7** | Project initialization, 8 per-project agents, automated batch testco regression driver | ✅ |
| **v1.0** | Full company + multi-project initialization, stable migration from v0.7, M365 document storage, scheduled Morning Brief and fiscal helpers | ✅ |
| **v1.1** | Teams meeting transcript analysis, multi-principal governance, Knowledge Sync Pipeline | Planned |

Roadmap detail and open issues are tracked in the private project management
repository — reach out via the [discussions](https://github.com/juvantlabs/juvant-os/discussions)
if you have questions or feature requests.

---

## Documentation

| Document | Purpose |
|---|---|
| [`JUVANT_OS.md`](JUVANT_OS.md) | The Skill — read at every session start |
| [`SYSTEM_INVARIANTS.md`](SYSTEM_INVARIANTS.md) | Cross-cutting invariants: bootstrap, naming, disclosure, single-writer, CONFIDENTIAL list, spec auth, architectural principles |
| [`docs/adr/`](docs/adr/) | Architecture Decision Records |
| [`CHANGELOG.md`](CHANGELOG.md) | Release history |

---

## License

MIT — see [LICENSE](LICENSE)
