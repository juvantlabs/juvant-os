# ADR 0005 — Portal agent variants: internal vs. portal subagent segregation

## Status

Accepted (2026-04-23). Promoted from `juvantlabs/juvant-os-pm#5` (ARCH-005) on
2026-05-02.

## Context

Some company roles serve both an internal user (the CEO) and external counterparties
through the v1.1 External Portal — typically an accountant against the CFO, an
attorney against the CLO, partners against the CCO, and press against the CMO.
Internal and external sessions require different behavior:

- Different tone (informal internal, formal external).
- Different data access (full internal, filtered external).
- Different authorization (CEO drives internal, NDA-bound counterparties drive
  external).
- Different disclosure-policy enforcement (PUBLIC and RESTRICTED only externally;
  CONFIDENTIAL can flow internally with the CEO present).

Embedding this dual behavior into a single agent template would couple the two
surfaces and increase the chance of disclosure leaks across them.

## Decision

Each role with an external surface ships **two separate template files**:

- `agents/company/<role>.md` — internal variant (full access for the CEO).
- `agents/company/<role>-portal.md` — portal variant (filtered, formal,
  draft-only by default).

Roles with portal variants in v1.1: CFO, CLO, CCO, CMO. Plus a single demo-only
variant for live sales: CCO has `cco-demo.md` for synchronous prospect demos.

Portal variants:

- Use formal tone and AP-style language by default.
- Cannot read internal context (Universal CONFIDENTIAL list per
  `SYSTEM_INVARIANTS.md` §5).
- Are draft-only — replies queue for CEO approval before sending, except for the
  demo variant which is live and CCO-led.
- Run on Azure Static Web App + Azure Functions + a `portal-bridge` MCP server
  that applies the read filter against `disclosure_policies` before passing data.
- Authenticate counterparties via Azure AD B2C (service portal) or invite link /
  email verification (demo portal).
- One portal session per counterparty.

## Consequences

Positive:

- Internal and external behavior are encoded as separate files; diffing one does
  not risk regressions in the other.
- Disclosure-policy enforcement is structural — the portal-bridge MCP server is
  the only path to data, and it filters before emit.
- v1.1 introduction does not touch v1.0 internal agents.

Negative:

- Two files per role increases maintenance surface. Mitigated by a shared
  identity / scope / ethics block referenced by both files (compiled at
  template-build time).
- Counterparty disambiguation (which portal account belongs to which entity in
  `counterparties`) requires `counterparty_routing` to be kept in sync with
  Azure AD B2C tenant state. CFO and CLO own this.

## Implementation

- v1.0 ships `agents/company/<role>.md` (internal variants) only.
- v1.1 adds `agents/company/cfo-portal.md`, `clo-portal.md`, `cco-portal.md`,
  `cmo-portal.md`, plus `agents/company/cco-demo.md` for live demos.
- `portal-bridge` MCP server (deployed alongside the portal) reads
  `disclosure_policies` and applies the filter.
- Tracked under `juvantlabs/juvant-os-pm#17` (FEAT-009 — External Portal).

## References

- `SYSTEM_INVARIANTS.md` §5 (Universal CONFIDENTIAL List).
- `juvantlabs/juvant-os-pm/docs/session-commit-p2.md` — External Portals
  rationale (Service Portal vs. Demo Portal).
