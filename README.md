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
"Set up Juvant OS for Acme Corp"
```

---

## How it works

```
JUVANT_OS.md            ← The Skill. The orchestrator. The only entry point.
agents/company/         ← 10 company agents (CoS, CFO, CLO, CMO...)
agents/projects/        ← 9 project agents (CTO, CPO, CDO, Eng/*...)
hooks/                  ← 5 lifecycle bash scripts
scripts/schema.sql      ← Turso database schema
plugins/m365-mail/      ← Inbound email channel plugin (Claude Code native)
plugins/portal-bridge/  ← MCP server — bridge between Azure Portal and agent sessions
plugins/teams-meeting/  ← Teams meeting bot — CoS as silent co-pilot during calls
```

State lives in [Turso](https://turso.tech) — a cloud SQLite database shared across all agent sessions.
Agents communicate through Turso, not through each other directly.

---

## Plugins

### `plugins/m365-mail/`
Native Claude Code Channel plugin (`defineChannel` API).
Polls Microsoft 365 via Graph API every 5 minutes.
Pushes inbound emails directly into the relevant agent session (CFO, CLO, CCO).
Sender confidence scoring enforced via Turso `disclosure_policies`.
Claude Code manages the lifecycle entirely — no separate process, no daemon.

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

## Quick start

### 1. Fork this repo

Fork `juvantlabs/juvant-os` into a private repo for your company.

```bash
git clone git@github.com:your-org/your-company-os.git
cd your-company-os
```

### 2. Open Claude Code

```bash
claude
```

### 3. Speak to the Skill

```
"Set up Juvant OS for [Your Company Name]"
```

The Skill will guide you through:
- Choosing your database (local / Turso Cloud / Azure / AWS / GCP)
- Configuring notifications (Telegram, Teams)
- Setting up counterparties (accountant, lawyer, partners)
- Generating agent names and compiling templates
- Running the manifesto approval flow

### 4. Commit your compiled setup

```bash
git add agents/ hooks/ .claude/settings.json
git commit -m "init: [Company Name] setup"
git push
```

---

## Agents

### Company agents

| Role | Default name | Model | Domain |
|---|---|---|---|
| CoS | Atlas | Opus 4.7 | Orchestration, routing, proxy |
| CFO | Theos | Sonnet 4.6 | Finance, banking, invoices |
| CLO | Lex | Opus 4.7 | Legal, contracts, IP, disclosure |
| CMO | Mira | Sonnet 4.6 | Marketing, brand, communication |
| CCO | Clio | Sonnet 4.6 | Sales, partnerships, revenue |
| CHRO | Sage | Sonnet 4.6 | People, ranking, versioning |
| CSO | Shield | Opus 4.7 | Cybersecurity, system audit |
| CEthO | Vera | Opus 4.7 | AI ethics, disclosure ethics |
| CA | Arch | Opus 4.7 | Cross-project tech standards |
| CRO | Lumen | Sonnet 4.6 | Research (optional) |

### Project agents

| Role | Model | Domain |
|---|---|---|
| CTO | Sonnet 4.6 | Architecture, tech decisions |
| CPO | Sonnet 4.6 | Product vision, BRD |
| CDO | Sonnet 4.6 | UX, design system |
| COO | Sonnet 4.6 | Ops, GitHub gateway |
| VPE | Sonnet 4.6 | Engineering coordination |
| Eng/API | Haiku 4.5 | Endpoints, OpenAPI |
| Eng/Backend | Haiku 4.5 | Business logic, services |
| Eng/Frontend | Haiku 4.5 | UI components |
| Eng/AI | Haiku 4.5 | Models, pipelines |

---

## Roadmap

| Milestone | What |
|---|---|
| **Alpha** | JUVANT_OS.md Skill + hooks + 19 subagent templates |
| **Beta** | M365 mail channel plugin + Scheduled Tasks + all company agents operational |
| **v1.0** | Testing green |
| **v1.1** | Service Portal + Demo Portal + Teams Meeting Bot |

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

## Project management

Documentation and project board: [juvantlabs/juvant-os-pm](https://github.com/juvantlabs/juvant-os-pm)

---

## License

MIT — see [LICENSE](LICENSE)
