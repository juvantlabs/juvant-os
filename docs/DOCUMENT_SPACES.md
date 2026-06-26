# Document spaces — adopter guide

> Implements [ADR 0023](adr/0023-document-spaces-third-party-access.md).
> This guide is **operational**: it tells an adopter *when* to promote a
> document space to an org-owned container, *how* to build that container
> on either provider, *how* to point agents at it, and *what must never
> land in doc-storage in the first place*. The model and rationale are in
> the ADR; this is the how-to.

## The model in one paragraph

A **space** is a governance scope's documents — a company-scope space
(finance, legal, ops, …) or a project-scope space. The framework is
**provider-neutral**: a space is "a place with access rules", and the
provider is just the implementation. Three implementations:

| Container | Microsoft | Google |
|---|---|---|
| **personal** (soft, default) | a folder in the CEO's OneDrive | a folder in the CEO's My Drive |
| **org** (promoted) | a **SharePoint site / document library** | a **Shared Drive** |

Company init binds every space to the **personal** container. That is the
soft default and it is fine for the vast majority of spaces. You promote a
space to **org** only when there is a concrete reason — and there is
essentially one.

## When to promote a space (the only trigger)

> **Promote a space the first time it must be shared with an external
> third party.** Not before.

External third party = someone with **their own identity, outside your
Claude harness**: the commercialista, outside counsel, an auditor. They
are the actor on the far side of the trust boundary, and a personal-drive
folder-share fails them three ways:

- **ACL-spaghetti** — the shared folder sits in a tree holding everything
  else personal; one misconfiguration exposes siblings.
- **Bus-factor** — their access is anchored to *your personal account*; if
  it changes, their access breaks. Company-document access must be
  anchored to the company.
- **Personal/company mixing** — they should be a guest of "Finance, the
  company space", not a guest inside your drive.

**Do _not_ promote** for these reasons (they don't cross the boundary):

- "An agent might write to the wrong folder." Agents are trusted in-harness
  subagents; the failure mode is error, covered by confirmation tokens,
  the deny-list, and the audit log (ADR 0004). A per-agent service identity
  on a Mac-local host is only *cooperatively* enforced and not worth the
  provisioning cost today — it belongs to the cloud milestone (FEAT-022).
- "A co-founder needs access." A co-founder is not a *guest*, they are a
  **second principal** of the company — that is FEAT-022 (multi-principal
  governance), a broader change than promoting one space.

Promotion is **surgical**: promote the *one* space that needs sharing, not
the whole store. An instance happily runs with most spaces personal and a
couple (finance, legal) org-owned.

> **Do not promote a Universal-CONFIDENTIAL space that has no external party**
> (ADR 0025). Banking, IP, and other §5 material with no commercialista/counsel
> who needs it fails the trigger above — keep it **soft** (personal drive).
> Agents still reach it via the existing `Files`-class scope, and the broad
> `Sites` scope you grant for the *other* promoted spaces then **never touches
> it**. Promoting it and bolting on a deny-list is strictly worse than not
> promoting it: you would create the exposure, then mitigate it. Promote the
> sensitive space **only** when it genuinely has an external party (e.g.
> `legal-ip` that outside counsel must read) — and then it needs the perimeter
> in "Access control for sensitive spaces" below.

## Prerequisite: the bound MCP must reach the container (sequence this FIRST)

> **ADR 0025 — hard prerequisite.** Being a *member* of the org space is
> necessary but **not sufficient**: the bound MCP also needs the Graph **scope**
> to reach that container *type*. `m365-graph` with `Files.ReadWrite` reaches the
> CEO's **OneDrive only** — it cannot read or write a **SharePoint** library. If
> you migrate before granting the scope, you move documents into a place the
> agents cannot operate. Incoherent.

| Container | Scope the bound MCP needs |
|---|---|
| OneDrive (personal, soft) | `Files.ReadWrite` (already present) |
| SharePoint (org) | `Sites.ReadWrite.All` (delegated — bounded by the principal's site memberships, *cooperative*) **or** `Sites.Selected` (app-only, truly per-site — the harder path, FEAT-022) |
| Google Shared Drive (org) | the Drive scope covering shared drives |

**Fixed sequence — never reorder:**

1. **Grant the scope** to the bound MCP (delegated `Sites.ReadWrite.All` is the
   pragmatic today-path; it likely needs a server version bump + Entra admin
   consent). This is **gate #1** of any promotion, not a follow-on.
2. **Create the sites/libraries + add guests** (next section).
3. **Migrate the documents** — last.

Delegated-scope caveat: with `Sites.ReadWrite.All` the agent (acting *as* the
connected principal) reaches **every** site that principal is a member of —
cooperative isolation, not a per-agent perimeter. That is fine for
non-sensitive spaces; for Universal-CONFIDENTIAL ones see "Access control for
sensitive spaces" below. True per-agent isolation is FEAT-022.

## How to build the org container

The credential / OAuth mechanics for the bound MCP server are already
covered in `JUVANT_OS.md` § "M365 write-capability setup"; this section
covers only the *container* construction and the *guest grant*.

### Microsoft — SharePoint site + library + guest

1. **Create the site** from the SharePoint admin/portal (a Team or
   Communication site). Manual portal creation is the supported path — it
   needs no app and no `Sites.FullControl.All` consent regime. Title it for
   the space (e.g. a `finance` space → a site whose document library holds
   the finance documents).
2. **Add your connected principal as a site member** (the identity the
   `ms-graph` MCP authenticates as — typically the CEO). This is what lets
   agents keep writing under the *existing* identity; no new service
   account is minted.
3. **Add the third party as a guest at the _library_ level**, with the
   minimum role (read / contribute). Guest-at-library, never guest-at-site
   if the site holds more than this one library — keep the blast radius to
   the shared library only.
4. **Grant the bound MCP the scope to reach this site** (the prerequisite
   above — do it *first*). For today's **delegated** `m365-graph` that is
   `Sites.ReadWrite.All`, bounded by your site memberships. If/when you move to
   **app-only** access, prefer `Sites.Selected` authorized on *this site only*
   over tenant-wide application permission — the surgical per-site app perimeter
   (FEAT-022 path). Don't grant broader than the container set requires.
5. **Capture `site_id` and `drive_id`** (Microsoft Graph returns both; the
   wizard's discover-via-tool path can read them). These go in the
   `spaces.<role>.resource_ids` block.

### Google — Shared Drive + library + external member

1. **Create a Shared Drive** (not a My Drive folder — the Shared Drive is
   the org-owned container, owned by the organization, not by a person).
2. **Add your connected principal as a member** of the Shared Drive (the
   identity the Drive MCP authenticates as).
3. **Add the third party as a member** of the Shared Drive (or share a
   single folder within it) with the minimum role (viewer / commenter).
   Per-Shared-Drive membership is the Google equivalent of
   `Sites.Selected` — the service identity and the guest are scoped to this
   drive only.
4. **Capture the Shared Drive id** (root `file_id`); it goes in
   `spaces.<role>.resource_ids`.

## How to point agents at the promoted space

Promotion is complete when the space's `spaces.<role>` override exists in
`.juvant/config.json` `doc_storage`. Add the block (see the schema in
`JUVANT_OS.md` § "Wizard — Step 1.5"):

```json
"spaces": {
  "finance": {
    "container": "org",
    "provider": "sharepoint",            // or "shared-drive"
    "resource_ids": { "site_id": "…", "drive_id": "…" },
    "path": "/Finance",
    "access": [
      { "principal": "commercialista@studio.example",
        "role": "read", "granted_at": "<date>", "decision_ref": "<decisions.id>" }
    ]
  }
}
```

From then on agents resolve the space with `resolve_space(role)`
(`JUVANT_OS.md` § Step 1.5), which returns `provider` + `resource_ids` +
`path` for the **org** container instead of the personal default. **The
agent's identity does not change** — it still authenticates as the
connected principal, which you added as a site/drive member in step 2. The
only new participant is the external guest. That is what makes pointing
agents at org storage cheap: a config block plus the existing OAuth
principal, not a service-account provisioning project.

### Governance of the grant

- Every external grant is authorized by a `decisions` row (the
  `access[].decision_ref` points back to it) — the same single-writer /
  CEO-commit discipline as any other change of consequence.
- The single-writer-per-scope rule (§4) projects onto spaces: the writer of
  a scope is the writer of its space. Promotion does not change who writes;
  it changes who can *see*.

## Access control for sensitive spaces (ADR 0025)

Needed **only** when you had to promote a Universal-CONFIDENTIAL space because it
genuinely has an external party (the `legal-ip`-must-be-read-by-counsel case). If
you followed the "do not promote a sensitive space with no external party" rule
above, most sensitive material stays soft and this section does not apply to it.

The problem: with a broad delegated `Sites` scope, agents act *as the connected
principal* and can technically reach the sensitive library. Library
guest-membership stops **guests**, not **agents**. So you need a real perimeter
on that one library — two layers:

**1. Cooperative — `agent_allowlist` on the space (does not, alone, enforce).**
Set `spaces.<role>.agent_allowlist` to the agent roles that legitimately need it,
e.g. `["lex","cto","cso"]` for `legal-ip`. `resolve_space` then refuses to hand
the `driveId` to any other agent. This is defence-in-depth — necessary but not
sufficient, because an agent could obtain the `driveId` another way.

**2. Hard — pre-tool-use hook deny-list (the enforcement of record).** Keyed on
`(AGENT_ROLE, target driveId/siteId)`. `AGENT_ROLE` is set at spawn and is
**not** something an agent can rewrite at call time, so it is the same
non-spoofable trust floor as the framework's Track-2 deny-list. **Enforcement
cannot live in the MCP server** — `m365-graph` is one delegated token in one
process and cannot tell which agent is calling; a `caller_agent_role` argument
would be self-declared and spoofable. Requirements for the hard layer:

- **Per-operation target visibility.** For *every* operation the hook must be
  able to derive the target `driveId`/`siteId`. Path-only operations → a double
  predicate (driveId **and** a library-name match). A cross-site search → scoped
  to a `siteId`/`driveId` or **denied** to non-allowlisted callers. **Any
  operation where the hook cannot see a target → denied** in the interim.
- **Escalation surface.** Sharing / permission-grant operations on the sensitive
  library are in scope of the allowlist — granting access is privilege
  escalation, not a read.
- **Alerting.** Every access writes `security_audit_log` (severity high) +
  notifies CoS, **including** allowlisted agents (tagged "expected") — to catch
  authorized-but-anomalous access.
- **Regression gate.** A synthetic canary (a non-allowlisted probe agent trying
  every operation, path-only included) gates go-live **and re-runs on every MCP
  version bump** — a new tool in a later server release must not silently reopen
  a hole.

**Where the rules live — critical.** The concrete `driveId`s and agent allowlists
are **instance state**. Put them in an instance-local, non-synced policy file —
convention **`.juvant/space-access-policy.json`** (gitignored) — that the hook
reads **in addition to** the synced `hooks/bash-policy.json`. **Never** put them
in `bash-policy.json` itself: `upstream-sync` would overwrite it and your
perimeter would evaporate. The hook treats the policy as a no-op when the file is
absent.

Honest cost: until FEAT-022, operations whose target the hook cannot see are
denied to non-allowlisted callers (an unscopable cross-site search, for example).
That is the price of cooperative→hard on the sensitive spaces only; the bulk of
promoted spaces stay cooperative.

## Taxonomy guard — what must NOT go in doc-storage

The audit that motivated ADR 0023 found a personal drive being used as a
dumping ground for things that are not documents. Doc-storage holds
**documents and references** — and nothing else. Four destinations, decide
per item:

| If the item is… | It belongs in… |
|---|---|
| a document or reference (contracts, decks, statements, PDFs) | the **doc-storage space** |
| canon, a skill, or code (MANIFESTO, a Claude skill, a codebase) | the **git repo** (`.claude/skills/`, a project repo) |
| operational / transactional state (an approval queue, status, audit, decisions) | the **company DB** (Turso) — e.g. the `outbox`, [ADR 0024](adr/0024-outbound-action-queue.md) |
| regenerable output | **nowhere** — regenerate it |

Concretely: a brand design system is a *skill* (repo), not a folder of
assets in doc-storage; a downloaded codebase is a *repo/zip*, not an
"Input" folder; a social-post approval queue is *DB state* (the `outbox`),
not a spreadsheet or list in doc-storage; the company manifesto is *canon
in the repo*, with only its distributable renders (the `.docx`) living in a
space. When onboarding or migrating, run each item through this table
before it lands — doc-storage is not a filesystem.

## References

- [ADR 0023](adr/0023-document-spaces-third-party-access.md) — the spaces
  model, the surgical-promotion decision, and the identity decoupling.
- [ADR 0025](adr/0025-document-space-access-control.md) — the access-control +
  scope model this guide implements (MCP-scope prerequisite, access-aware
  `resolve_space`, the sensitive-space hook perimeter, instance-local policy).
- [ADR 0024](adr/0024-outbound-action-queue.md) — the `outbox`: where
  operational/transactional state lives (the DB leg of the taxonomy).
- `JUVANT_OS.md` § "Wizard — Step 1.5" — the `doc_storage` schema,
  `resolve_space`, and the M365 credential setup.
- `SYSTEM_INVARIANTS.md` §4 — single-writer-per-scope.
- FEAT-022 — multi-principal governance (co-founder = second principal;
  per-agent service identities at the cloud milestone).
