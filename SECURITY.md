# 🔐 Security

## Reporting a vulnerability

Please report vulnerabilities **privately**, through one of these channels:

1. **GitHub private vulnerability reporting** (preferred): this repository's **Security** tab → **Report a vulnerability**. The report stays between you and the maintainers until a coordinated advisory is published.
2. **Email:** `security@juvant.io`.

**Please don't** open a public issue, pull request or discussion with reproduction details. Once the details are public, the coordinated-disclosure window is gone.

If you run juvant-os and found the defect in your own company repository, the `bugfix` skill drafts the private report with you and sends it with your ok.

## What we commit to

This repository follows the [juvantlabs security disclosure process](https://github.com/juvantlabs/handbook/blob/main/docs/security/disclosure-process.md):

| Step | Target |
|---|---|
| Acknowledge the report | ≤ 7 days |
| Triage and severity | ≤ 14 days |
| Fix ready (high or critical) | ≤ 30 days |
| Fix ready (moderate) | ≤ 90 days |
| Public advisory | 1–7 days after the fixed release |

Fixes ship as an official [release](https://github.com/juvantlabs/juvant-os/releases). Companies get them with the `update` skill.

## Supported versions

| Version | Supported |
|---|---|
| Latest v2 release | ✅ |
| Older v2 releases and release candidates | ❌ update to the latest release |
| v1 (frozen on the [`v1` branch](https://github.com/juvantlabs/juvant-os/tree/v1)) | ❌ no further releases; move to v2 |

## What the hard limits are, and aren't

juvant-os enforces a few hard limits with Claude Code hooks: outbound is draft-only, no money movement, no secrets in files or commands, nothing overwritten, deleted or moved without the CEO. Private files are readable only by the roles listed for them.

These are **guardrails against mistakes, not isolation.** They stop an agent from doing the wrong thing by accident, and they make the right path the easy one. They are not a sandbox: they don't contain a determined attacker, or code that is already running on the machine with the user's rights. For data that must stay out of an agent's reach, use the access controls of the system that holds it.

## Scope

**In scope:**

- A way for an agent to get past a hard limit or a private-file rule, through a path the hooks are meant to cover.
- Defects in the framework's hooks (`framework/hooks/`), skills, agent prompts, templates, dashboard, `setup.sh` and the `update` skill: for example, prompt-injection-friendly instructions, or an install or update that takes code from anywhere other than an official release.
- The migration tools in `tools/`.

**Out of scope:**

- Behaviour the section above describes as a limit by design.
- A company's own repository and its own changes (its manifesto, role cards, `limits-company.json`): the company owns them.
- Dependencies and vendors: Claude Code, the MCP servers (each `juvantlabs/*-mcp-server` repository has its own `SECURITY.md`), Microsoft 365, banks, e-invoicing providers, npm, PyPI and OS packages. Report to them.

## How this repository checks itself

On every pull request and every push to `main`, CI (`bash tests/run.sh`) runs:

- `shellcheck` and `bash -n` on every shell script, JSON and Python syntax checks, and frontmatter checks on agents and skills;
- the `framework/FILES` check: the framework ships exactly the files it lists;
- a check that the Morvento example carries the current framework;
- unit tests for the hooks (hard limits, private files, secrets, authorizations), setup and update, the dashboard, the `bugfix` skill and the migration tools.

`main` is protected by a ruleset: pull requests, the CI check required, no force pushes or deletion.
