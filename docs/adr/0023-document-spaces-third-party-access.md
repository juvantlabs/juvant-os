# ADR 0023 — Provider-neutral document **spaces**: scoped third-party access via org-owned containers (not personal drives)

## Status

Proposed (2026-06-25). The architectural core (spaces = scopes; surgical
org-container promotion on external-sharing trigger; agent→space pointing
under the existing principal) is ratified by the CEO. The adopter-onboarding
mechanics — how the wizard builds the org-container and how `Step 1.5`
evolves to a per-space binding — are deferred and tracked in **ARCH-013**
(`juvantlabs/juvant-os-pm`). Supersedes the framing of instance
upstream-sync-proposal #201 ("doc-storage → SharePoint multi-site"), which is
reframed here in provider-neutral terms.

## Context

Today the document-storage model (`JUVANT_OS.md` § "Wizard — Step 1.5") binds
`doc_storage` to **one** provider and **one** drive — in practice the CEO's
**personal** OneDrive (or Google Drive), a single connected principal. Folder
resolution is `role → folder` *within that one drive* (`resolve_folder`).

Two pressures break this model:

1. **Agents acting more autonomously** need write boundaries — an unauthorized
   (or simply mistaken) agent must not write into an arbitrary folder.
2. **Third parties** — commercialista, counsel, co-founder — need scoped,
   durable access to a *subset* of company documents.

An adopter instance attempted to relieve both by migrating OneDrive → a
SharePoint **multi-site** topology with per-agent service accounts. It worked
technically but surfaced a framework-level tension: **coupling the framework to
SharePoint breaks provider-agnosticism.** An adopter on Google Workspace has no
"sites". The correct abstraction is *"spaces with access rules"*, not
"SharePoint sites"; SharePoint is one provider's *implementation* of that
abstraction, Google Shared Drives another.

Sharing from a **personal** drive fails third parties on three concrete fronts:

- **ACL-spaghetti** — you share a folder, but it lives in a tree that also holds
  everything else personal. The boundary is implicit and one misconfiguration
  away from exposing siblings.
- **Bus-factor** — the third party's access is anchored to the CEO's *personal*
  identity; if that account changes or leaves, access breaks. Access of an
  external party to *company* documents must be anchored to the **company**.
- **Personal/company mixing** — the commercialista should be a guest of "Finance,
  the company space", not invited into a person's drive. Fusing personal and
  company state in one principal is the root problem.

**Threat-model line.** A hard, identity-enforced boundary earns its place only
when an actor *outside the trust loop* touches state. Trusted in-harness agents
(failure mode = error) are on the **soft** side — confirmation tokens, deny-list
hooks, and the audit log (ADR 0004) already cover them, and a per-agent service
identity on a Mac-local host is only *cooperatively* enforced (the MCP server
honours the binding; the OS does not isolate the agents). The **third party**,
by contrast — own identity, outside the harness — is exactly the actor on the
far side of that line. So org-owned containers are premature *for agent
boundaries today*, but justified *now* for third-party access.

## Decision

1. **Document storage is modeled as _spaces_.** A space corresponds to a
   governance scope — company-scope, project-scope (component scope has no
   doc-storage per ADR 0020). The model is *"space = scope, with access rules"*,
   provider-neutral. Implementations:
   - Microsoft → SharePoint site / document library
   - Google → Shared Drive
   - degenerate/soft → a folder in a personal drive (the current default)

2. **Access rules project §4 single-writer-per-scope.** The writer of a scope is
   the writer of its space; this is not a new authorization model, it is the
   documental projection of the invariant the framework already enforces for
   repos (ADR 0014). The instance's decided topology (company-scope sites,
   project-scope sites, components = no site) is literally the §4 scope tree
   projected onto storage — confirming the mapping rather than inventing one.

3. **Default stays soft.** Company init continues to bind a personal-drive folder
   with a single connected principal. **No mandatory migration.** Most spaces
   (ops, branding, internal) may live on the CEO's personal drive indefinitely.

4. **Migration trigger is external sharing, surgical not wholesale.** When — and
   only when — a space must be shared with an external third party, *that space*
   (not the whole store) is promoted to an **org-owned container**, and the third
   party is added as a **guest at library / Shared-Drive granularity**, never via
   a personal-folder share. A single instance may therefore have most spaces on a
   personal drive and a few (e.g. finance → commercialista, legal → counsel) on
   org-containers.

5. **Org-container is provider-neutral.** Implementation is SharePoint
   site + guest (Microsoft, using `Sites.Selected` for surgical app scope) or
   Shared Drive + external member (Google, per-drive membership). The framework
   names the capability ("org-owned space with scoped guest"), never the product.

6. **Container-ownership is decoupled from agent identity** (the key enabler).
   Promoting a space to org-owned does **not** require a separate per-agent
   service identity. The agent keeps writing under the **existing connected
   principal** (the CEO), who is a *member* of the org space; the third party is
   the *guest*. Per-agent service-account identities are deferred to the
   **cloud-identity milestone (FEAT-022)**, where every agent has its own identity
   anyway and the boundary becomes near-free — rather than paying the heavy
   provisioning regime (`Sites.FullControl.All`, admin consent, staged revoke)
   on a Mac-local host whose threat model does not need it.

7. **Co-founder is out of scope here.** A co-founder is not a *guest* but a
   **second principal** of the company — broad, durable, peer access. That routes
   to FEAT-022 (multi-principal governance), not to guest-at-a-space.

### Agent → space pointing (first-class concern)

A space is useless if agents cannot resolve and write to it. Pointing has two
layers; this ADR fixes the near-term shape and defers the mechanics to ARCH-013:

- **Resolution.** `role → folder` (within one drive) evolves to
  `space → { provider, resource_id, path }`. Each space carries its own container
  binding, so resolution works even when spaces span different containers (most
  on the personal drive, a few on org-containers). The current global
  `doc_storage.resource_ids` descends to **per-space** binding wherever a space
  diverges from the instance default.
- **Identity.** For the surgical near-term case the agent writes under the
  **same connected principal** that is already a member of the target space — no
  new identity is minted. The org-container's value is the *clean guest boundary
  for the external party*, not a new agent identity. (Per-agent identities arrive
  with FEAT-022, per Decision 6.)

This keeps "pointing agents at org storage" cheap: a config-level per-space
binding plus the existing OAuth principal — not the multi-service-account
provisioning saga.

## Consequences

**Positive**
- Provider-agnostic: the abstraction lives in "spaces", not in any vendor. An
  adopter on Google gets Shared Drives via the same model.
- Surgical and cheap: only spaces that need external sharing migrate; no
  instance-wide cutover, no `FullControl` provisioning regime.
- Third-party access gets a clean library-granularity boundary and is anchored to
  the company (bus-factor fixed) instead of the CEO's personal identity.
- Reuses §4: no second authorization model to learn or maintain.

**Negative / trade-offs**
- Per-space provider/resource binding complicates `Step 1.5` and the resolution
  algorithm (`resolve_folder` → `resolve_space`).
- "Split-brain" storage — some spaces org-owned, some personal — is more to
  reason about than a single uniform drive. Mitigated by it being opt-in per
  space and config-visible.
- The operator must understand the spaces model. Mitigated by the default
  remaining the familiar single-drive soft mode until a sharing trigger fires.

## Implementation

Deferred to **ARCH-013**. Expected work:
- Evolve `.juvant/config.json` `doc_storage` to carry per-space bindings
  (`provider`, `resource_ids`, `path`, plus an `access` block for guests).
- `resolve_folder` → `resolve_space` in `JUVANT_OS.md` § Step 1.5.
- Wizard guidance for *building* an org-container and *pointing* agents at it
  (the "how do adopters construct the org storage" question the CEO flagged as
  still-open).
- Onboarding guard codifying the doc-storage taxonomy (documents/reference →
  space; canon/skill/code → repo; **operational/transactional state → company DB
  per ADR 0024**; regenerable → nothing), so skill/codebase/canon/queue-state
  never leak into doc-storage.

## References

- `SYSTEM_INVARIANTS.md` §4 — single-writer-per-scope + disclosure boundary.
- [ADR 0014](0014-tech-leadership-restructure.md) — single-writer-per-scope.
- [ADR 0020](0020-component-scope.md) — components have no doc-storage.
- [ADR 0024](0024-outbound-action-queue.md) — sibling: operational/transactional
  state belongs in the company DB outbox, not doc-storage (the 4-way taxonomy).
- FEAT-022 — multi-principal governance (co-founder = second principal;
  per-agent service identities at the cloud milestone).
- Instance upstream-sync-proposal #201 — reframed by this ADR in
  provider-neutral terms.
