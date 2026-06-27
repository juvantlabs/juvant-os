# ADR 0025 — Document-space access control: MCP-scope prerequisite, access-aware `resolve_space`, and a hook-enforced sensitive-space perimeter

## Status

Proposed (2026-06-25). **Extends [ADR 0023](0023-document-spaces-third-party-access.md)**
with the access-control and scope model that the first instance applying ADR
0023 surfaced (a SharePoint guest-library promotion). The model and the
instance-local policy *convention* are defined here and implemented in docs +
`resolve_space`; the **executable hook deny-list** is harvested back from the
instance once its `m365-graph` v0.4.0 proves the per-operation enforcement (the
ADR 0019 self-developing path) — tracked in ARCH-015.

> **Update (2026-06-27): executable shipped — ARCH-015 closed.** The instance's
> canary went green (every op incl. path-only refused for non-allowlisted agents,
> audit fires), so the per-op enforcement was generalized into the framework hook
> as **`hooks/pre-tool-use.sh` Track 2e** (policy-driven from
> `.security.space_access[]`), with the standing regression canary
> `tests/hooks/test-space-access-policy.sh` wired into CI. Convention finalized to
> `config.json .security.space_access` (clause 5).

## Context

ADR 0023 said an agent operates on a promoted org-owned space "under the existing
connected principal, which is a member of the space." True, but it left three
things implicit that an instance hit immediately when promoting finance/legal
spaces to SharePoint:

1. **Membership is necessary but not sufficient — the MCP needs the _scope_ to
   reach the container type.** `m365-graph` with `Files.ReadWrite` reaches the
   CEO's OneDrive only; SharePoint document libraries sit behind a `Sites.*`
   Graph scope. Without it, the migration moves documents into a place the agents
   cannot read or write — incoherent. The scope grant is a **hard prerequisite of
   promotion**, and the instance initially mis-sequenced it as an optional
   "parked" follow-on.

2. **A broad delegated scope over-reaches.** Because agents act *as the connected
   principal* (the CEO), a delegated `Sites.ReadWrite.All` reaches **every** site
   the CEO is a member of — including Universal-CONFIDENTIAL libraries (banking,
   IP). Library guest-membership stops *guests*; it does nothing against *agents*,
   which are the CEO. Cooperative isolation is not a perimeter for
   Universal-CONFIDENTIAL material.

3. **The perimeter cannot live in the MCP server.** `m365-graph` is one delegated
   token in one process (`msal` picks the single account); the stdio transport
   passes only `{name, arguments}`. A `caller_agent_role` argument would be
   self-declared and therefore spoofable (a prompt-injected agent emits `"lex"`
   from the `cmo` process and the server cannot tell). The only non-spoofable
   signal is `AGENT_ROLE`, set at spawn by the SessionStart hook — i.e. the
   **pre-tool-use hook** is the enforcement layer, the same trust floor as the
   framework's Track-2 deny-list (handbook ADR 0004). Enforcement inside the
   server is theatre.

## Decision

1. **MCP-scope-reaches-container is a hard, sequenced prerequisite of promotion.**
   A space is promoted only after the bound MCP holds the Graph scope to reach
   that container type:
   - OneDrive (personal) → `Files.ReadWrite` (existing).
   - SharePoint (org) → `Sites.ReadWrite.All` (delegated; bounded by the
     principal's site memberships — cooperative) or `Sites.Selected` (app-only;
     truly per-site — the harder path, FEAT-022/cloud).
   - Google Shared Drive (org) → the Drive scope covering shared drives.
   **Sequence is fixed: grant scope → create sites + add guests → migrate.**
   Never migrate before agents can operate. The scope grant is the first gate of
   any promotion, not a follow-on.

2. **Do not promote a Universal-CONFIDENTIAL space that has no external party.**
   It fails the ADR-0023 trigger anyway (no external sharing need). Keeping it
   **soft** (personal drive, reached via the existing `Files`-class scope) means
   the broad `Sites` scope **never touches it** — the exposure is eliminated *by
   design* rather than mitigated after the fact. Promote-then-deny-list is a
   worse pattern than don't-promote. (Reference instance: `finance-banking`,
   which has no external party, was kept soft and dropped from the SharePoint
   topology; only `legal-ip` — which genuinely has an external counsel party AND
   is Universal-CONFIDENTIAL — needed a perimeter.)

3. **`resolve_space` is access-aware (the cooperative layer).** A
   `spaces.<role>` block may carry an `agent_allowlist` — the internal agent
   roles permitted to resolve and operate on that space. When present,
   `resolve_space(role, caller)` returns `None` (surfacing `[<ROLE> ACCESS
   DENIED]`) for a caller not on the list, so a non-permitted agent never even
   receives the sensitive `driveId`. Absent ⇒ all company agents (the default for
   a normally-promoted space). This is defence-in-depth, **not** the enforcement
   of record.

4. **The hard perimeter is the pre-tool-use hook deny-list.** It is keyed on
   `(AGENT_ROLE, target driveId/siteId)` and is the enforcement of record because
   `AGENT_ROLE` is non-spoofable (spawn-set) and the hook runs before the call
   crosses stdio. Requirements:
   - **Per-operation target visibility.** For every operation the target
     `driveId`/`siteId` must be derivable by the hook. Operations exposing only a
     path-string use a double predicate (driveId **and** a library-name match);
     a cross-site search must be scoped to a `siteId`/`driveId` (or denied to
     non-allowlisted callers); **any operation where the hook cannot see a target
     is denied** in the interim.
   - **Escalation surface.** Sharing / permission-grant operations on a sensitive
     space are in scope of the allowlist too — they are privilege escalation, not
     a read.
   - **Alerting.** Every access to a sensitive space writes
     `security_audit_log` (severity high) + notifies CoS, **including**
     allowlisted agents (tagged "expected") — to catch authorized-but-anomalous
     access (an allowlisted agent exfiltrating the whole library at 03:00).
   - **Regression gate.** A synthetic canary (a non-allowlisted probe agent
     attempting every operation, path-only included, against the sensitive space)
     gates go-live **and re-runs on every MCP version bump** — a new tool in a
     later server release must not silently reopen a hole.

5. **Instance-specific rules live in an instance-local policy layer.** The
   concrete `driveId`s and agent allowlists for a company's sensitive spaces are
   instance state. They live in **`.juvant/config.json` under
   `.security.space_access[]`** (a list — gitignored, instance-local) that the
   synced hook reads — never inside `hooks/bash-policy.json` or any synced file,
   which `upstream-sync` would overwrite, evaporating the perimeter. The hook is
   a no-op when the list is absent. *(Convention finalized at harvest time to
   `config.json .security.space_access` — the form proven in the reference
   instance — rather than a separate `space-access-policy.json`; the hook already
   reads `config.json` for Track 2c/2d.)*

## Consequences

**Positive**
- Promotion can no longer strand documents where agents cannot operate (scope is
  gate #1).
- Universal-CONFIDENTIAL exposure is eliminated by design where possible
  (don't-promote) and hard-perimetered where unavoidable (`legal-ip`), at the
  framework's real trust floor (`AGENT_ROLE`), not in spoofable server code.
- Instance-specific rules survive upstream-sync (instance-local policy layer).

**Negative / trade-offs**
- Interim functional cost until FEAT-022: operations whose target the hook cannot
  see are denied to non-allowlisted callers (e.g. an unscopable cross-site search
  is denied). This is the honest price of cooperative→hard on the sensitive
  spaces only; the bulk of promoted spaces stay cooperative.
- Per-MCP target extraction is MCP-specific work in each server's bump, not a
  single generic hook — the framework defines the convention; each component
  supplies its extractor.

## Implementation

- **This PR (framework):** ADR 0025; `docs/DOCUMENT_SPACES.md` (scope
  prerequisite + sequencing + don't-promote-UC rule + sensitive-space access
  control + instance-local policy convention); `JUVANT_OS.md` `resolve_space`
  access-aware + `agent_allowlist` in the `spaces.<role>` schema.
- **Harvest-after (ARCH-015):** the executable pre-tool-use hook deny-list
  (instance-local policy loader + per-op target extraction + alerting + canary),
  generalized from the instance's `m365-graph` v0.4.0 once its canary proves the
  per-operation enforcement.

## References

- [ADR 0023](0023-document-spaces-third-party-access.md) — document spaces (the
  base this extends).
- [ADR 0024](0024-outbound-action-queue.md) — sibling (outbox).
- [ADR 0019](0019-juvantlabs-as-self-developing-project.md) — the harvest-back
  model (prove in an instance, generalize into the framework).
- `SYSTEM_INVARIANTS.md` §4 (single-writer / disclosure boundary), §5 (Universal
  CONFIDENTIAL).
- handbook ADR 0004 — agent-action guardrails; Track 2 deny-list is the
  enforcement floor this reuses.
- `docs/DOCUMENT_SPACES.md` — the adopter-facing how-to.
