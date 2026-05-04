# Security

## Reporting a vulnerability

Please report vulnerabilities **privately** via one of these channels:

1. **GitHub Security Advisory** (preferred) — go to this repo's
   `Security` tab → `Report a vulnerability`. Your report stays
   private between you and the maintainer until we publish a
   coordinated advisory.
2. **Email** — `security@juvant.io`. Reports go to the primary
   maintainer.

**Please do NOT** open a public issue or pull request that contains
reproduction details for the vulnerability. Once a public artifact
exposes the issue, the coordinated-disclosure window collapses.

## What we commit to

This repo follows the
[juvantlabs Security Disclosure Process](https://github.com/juvantlabs/handbook/blob/main/docs/security/disclosure-process.md).
SLOs:

| State | Target |
|---|---|
| Acknowledge receipt | ≤ 7 days |
| Initial triage + severity classification | ≤ 14 days |
| Patch prepared (high/critical) | ≤ 30 days |
| Patch prepared (moderate) | ≤ 90 days |
| Public advisory + CVE | Patch + 1–7 days |

## Scope

`juvantlabs/juvant-os` is the **framework template**: agent prompts,
hooks, scaffolder-installable skill, Turso schema. Adopters fork it
and instantiate per company under their own (typically private) repo.

In scope for this repo's security disclosure:

- Vulnerabilities in agent templates (e.g. prompt-injection-friendly
  patterns, disclosure-policy bypass paths in the template logic).
- Vulnerabilities in shipped hooks (`hooks/*.sh`) and helper scripts
  (when `helpers/` lands per FEAT-007).
- Vulnerabilities in `JUVANT_OS.md` skill orchestration that allow an
  agent or counterparty to bypass the
  [Universal Boundaries](SYSTEM_INVARIANTS.md) or the disclosure
  fallback cascade.
- Vulnerabilities in the Turso schema (`scripts/schema.sql`) that
  allow privilege escalation across agent rows.

Out of scope (report to the upstream maintainer instead):

- **Vulnerabilities in adopter per-company instances** — those live
  in private forks under the adopter's control. Adopters apply this
  template's SLOs in their own repos.
- **Vulnerabilities in upstream dependencies** — Claude Code, Turso /
  LibSQL, `@modelcontextprotocol/server-github`,
  `@juvantlabs/m365-graph-mcp-server` (separate
  [`SECURITY.md`](https://github.com/juvantlabs/m365-graph-mcp-server/blob/main/SECURITY.md)),
  npm / PyPI / OS packages. Report to those projects.
- **Vulnerabilities in Microsoft Graph, Finom, Aruba, or other
  vendor APIs** — report to the vendor.

## Supported versions

| Version | Supported |
|---|---|
| `main` (latest) | ✅ |
| Tagged `0.x` releases | ✅ for the currently-shipped `0.x` only |
| Older `0.x` releases | ❌ end-of-life with each new release until `1.0` |

Once `1.0` ships, the supported-versions matrix expands to formally
back-port security fixes to the `N-1` major.

## Hardening this template applies to itself

The `.github/workflows/lint.yml` workflow runs on every PR:

- `shellcheck` on `hooks/*.sh`, `scripts/*.sh`, `helpers/*.sh`.
- YAML frontmatter validation on every agent template.
- `scripts/schema.sql` parse via `sqlite3` dry-run.
- `.claude/settings.json` JSON validation.
- Tracked-secrets grep (private keys, GitHub PATs, OpenAI keys, Slack
  tokens) — refuses to merge if any are detected.
- Markdown lint (relaxed for the OSS template; adopters tighten in
  their forks).

These checks are mirrors of the CSO Layer 2 baseline audit
(`agents/company/cso.md`); per-adopter security posture is enforced
in the adopter's CI.
