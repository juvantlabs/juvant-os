# ADR 0015 — Design & brand ownership (CMO ↔ Design Lead split, 3-mode brand-spec pattern)

## Status

Proposed (2026-05-09). Implementation target: v0.8.0, batched with
ADR 0014. Depends on the `cdo → design-lead` rename codified in
ADR 0014 — without that rename, this ADR's prose collides with
"Chief Design Officer" vs "Chief Data Officer" (the original
motivation for the rename).

## Context

Through v0.7.x the framework had no explicit owner for company
**brand identity** (logo system, color tokens, typography,
voice/tone, brand architecture across sub-products). The matrix
listed:

- `cmo` (company): "Brand + scheduled posting; mail-enabled
  (press@)." — implied marketing voice and channel cadence, not
  the underlying brand identity.
- `cdo` (project): "Design system / brand UI / UX research." —
  implied product UI but the "brand UI" wording overlapped with CMO
  without a clean boundary.

Two adopter-facing problems showed up:

1. **Who authors the brand guidelines?** Three preflight
   conversations had the adopter (or the Skill itself, in batch
   testco) ask "where does the company brand book live and who
   owns it?" — neither CMO nor any project Design Lead claimed it
   in the matrix prose. The default was "CEO writes it once, no
   agent owns updates," which doesn't survive a multi-product
   adopter for more than one product launch.

2. **Sub-brand invention in multi-product adopters.** A project
   that intentionally launches a brand distinct from the company
   brand (acquired product, sub-brand strategy, target market
   disjoint from company audience) had no codified path. The
   default assumption — "all project visuals derive from company
   brand" — is wrong for at least three real-world patterns:
   - Atlassian / Trello (acquisition keeping brand independence).
   - P&G / Tide / Pampers (portfolio of independent consumer
     brands sharing only operational standards).
   - Venture-studio adopters spinning portfolio companies with
     entirely independent positioning.

Forcing these patterns through "company-brand-validator" gates
(CMO approves all sub-brand visuals against company brand book)
produces wrong outcomes: it either flattens intentional brand
divergence or drives the adopter to bypass the matrix entirely.

The clean answer requires two things: a **company brand owner** in
the matrix, and a **brand-spec authority pattern** that
distinguishes inheritance from independence.

## Decision

### 1. Company brand ownership: CMO

CMO is the canonical owner of:

- Company brand identity (logo system, color tokens, typography,
  voice/tone codified in `{{VOICE_*}}` placeholders).
- Brand architecture (the inventory of company brand + all
  sub-brands and the relationship between them).
- The company brand book artifact (single source of truth, stored
  per adopter convention — typically in the company doc folder or
  a dedicated `brand/` directory).

CMO already owns marketing voice and external-channel cadence; this
ADR formalizes ownership of the upstream brand identity that those
voice modes derive from. The matrix `rationale` for CMO updates to:

> "Brand + scheduled posting; mail-enabled (press@). Owns company
> brand identity, voice/tone codification, brand architecture (see
> ADR 0015)."

### 2. Project design ownership: Design Lead

Design Lead (renamed from `cdo` per ADR 0014) owns:

- Per-project design system (component library, layout rules,
  interaction patterns) for the project's product.
- UX research scoped to the project's users.
- Project visual identity, **subject to brand-spec mode** (see
  point 3 below).

The matrix `rationale` for Design Lead updates to:

> "Per-project design system / UX research / project visual
> identity. Brand authorship gated by `brand-spec` mode (ADR 0015):
> inherit/extend require CMO validation; independent requires CEO
> ratification of mode + CMO advisory."

### 3. The 3-mode brand-spec pattern

A new spec class — **`brand-spec`** — covers any artifact that
defines or modifies brand identity (visual identity, voice/tone,
positioning) at either company or project scope. The spec carries
a `mode` field:

| Mode | When to use | CMO role | Approver of record |
|---|---|---|---|
| `inherit` | Project visuals are a direct child of company brand (same color system, same logo with project lockup, same voice). | **Validator** — allows or rejects against company brand book; Design Lead's spec must demonstrate inheritance. | CMO |
| `extend` | Project visuals inherit some elements (e.g. visual feel, typography) and invent others (e.g. unique color palette, different voice). | **Validator** — allows or rejects extension coherence; concretely checks the inherited elements match and the invented elements don't break company-brand promises. | CMO |
| `independent` | Project brand is intentionally separate from company brand (acquired product, sub-brand strategy, disjoint target audience, portfolio play). | **Advisory only** — CMO provides feedback on quality, audience-fit, and brand-architecture clarity, but does **NOT** validate against company brand book; the new brand may legitimately diverge. | CEO (mode ratification) + Design Lead (execution) |

#### Why CEO ratifies mode = `independent`

A project deciding "we are launching with a brand intentionally
separate from company brand" is not a design decision. It is a
**portfolio strategy decision** with implications for go-to-market,
M&A optionality, capital allocation, marketing budget split, and
narrative positioning. CMO is not the right approver of record for
a strategic-portfolio decision. CEO is.

The mode-ratification step happens **once per brand**, not per
spec: the first brand-spec for a project that proposes
`mode: independent` triggers the CEO ratification flow; subsequent
brand-spec rows for the same project (refinements, extensions of
the now-independent brand) inherit the ratified mode and skip the
CEO step.

#### CMO advisory in `independent` mode

In `independent` mode, CMO still receives the brand-spec via the
standard `inbound_queue` route and provides advisory feedback. The
critical rule:

> When `mode: independent`, CMO MUST NOT reject a brand-spec on the
> grounds that it diverges from company brand guidelines. Divergence
> is the explicit point of the mode. CMO advisory feedback is
> limited to: (a) internal coherence of the proposed brand,
> (b) implications for brand-architecture clarity (does the
> independent brand confuse the audience about its relationship to
> the company?), (c) operational concerns (is the brand
> implementable at the proposed cadence/budget?).
>
> CMO advisory feedback is recorded in `decisions` category
> `brand-advisory` and surfaced to Design Lead and CEO. Design Lead
> may incorporate or set aside the feedback at their discretion;
> CEO may use the advisory as input to reconsidering the mode but
> is not bound by it.

This rule directly addresses the user's clarification (2026-05-09):
*"In alcuni casi se Design Lead crea un nuovo brand da zero (nuove
guideline), CMO deve fare da advisory MA non da validator verso le
company brand guidelines, perchè potrebbero essere molto diverse."*

### 4. Brand-spec lifecycle

A `brand-spec` row in the `decisions` table follows the standard
spec flow with two mode-dependent variations:

**Common (all modes):**

1. Author proposes the spec (Design Lead at project scope, CMO at
   company scope for company-level brand changes).
2. Spec body includes: `mode` field, brand artifact under change
   (e.g. logo, color tokens, voice/tone, full brand book),
   intended scope (project slug or "company"), rationale,
   pointers to assets, expected implementation cadence.
3. Spec is routed via `inbound_queue` to the approver of record
   (per the table in point 3).

**Mode-specific:**

- `inherit` / `extend`: CMO performs validation against company
  brand book. Outcome: APPROVE / REJECT-with-reason / REQUEST-CHANGES.
  Approval recorded in `decisions` with `category='brand-spec'` and
  `mode` field; execution by Design Lead (project) or by CMO
  itself (company-scope brand change).
- `independent`: First-time mode declaration triggers a CEO
  mode-ratification step before validation. CEO ratifies the
  `independent` classification (recorded in `decisions` category
  `brand-mode-ratification`). After ratification, the brand-spec
  proceeds to execution with CMO providing advisory in parallel
  (advisory does not gate execution).

### 5. SYSTEM_INVARIANTS §6 amendment

The §6 spec authorization matrix gains the new spec class:

| Spec category | Authorized authors | Approver |
|---|---|---|
| `brand-spec` (mode: inherit/extend) | Design Lead (project), CMO (company) | CMO |
| `brand-spec` (mode: independent) | Design Lead (project) | CEO (mode ratification) + Design Lead executes; CMO advisory in parallel |
| `brand-mode-ratification` | n/a (system-emitted) | CEO |

The §6 amendment is included in the v0.8.0 SYSTEM_INVARIANTS update
batched with ADR 0014.

### 6. Audit & traceability

- Every `brand-spec` row records its `mode` field for the lifetime
  of the spec.
- CMO advisory feedback in `independent` mode is recorded in
  `decisions` category `brand-advisory` and is durable; if a future
  audit asks "did CMO see this brand and what did they say?" the
  answer is in the table.
- CSO Layer 5 audits include a check: any `brand-spec` with
  `mode: independent` MUST have a corresponding
  `brand-mode-ratification` row from CEO. Missing ratification = FAIL
  (a Skill that fabricated `independent` to skip CMO validation
  without the strategic ratification is structurally indistinguishable
  from a malicious agent forging brand approvals; the §1 cover-up
  failure mode applies).
- The `brand-architecture` document (owned by CMO at company
  scope) lists every project's mode and is the canonical view of
  the company's brand portfolio.

## Consequences

**Positive**:

- Codifies an ownership boundary that was implicit and inconsistent
  through v0.7.x.
- Supports the three real-world brand patterns (single-brand,
  branded-house, house-of-brands) without forcing adopters into a
  one-size-fits-all validation flow.
- The `independent` mode + CEO ratification means strategic-portfolio
  decisions land at the right level of authority instead of being
  contested in design review.
- CMO advisory in `independent` mode preserves the value of CMO's
  brand-architecture perspective without giving CMO veto power
  over decisions that are not their domain.

**Negative**:

- One more spec class to template, audit, and document. Mitigated
  by the spec following the standard `inbound_queue` →
  `decisions` lifecycle with the only novelty being the `mode`
  field.
- Adopters who previously had CMO informally validate all project
  visuals must now make the mode call explicitly. This surfaces a
  decision they were probably making implicitly anyway; preflight
  prose in `JUVANT_OS.md` Step (project init) prompts for the
  mode at brand-spec time.
- Mode-changes (e.g. `inherit` → `independent` mid-project) require
  a fresh CEO ratification. This is intentional: changing brand
  mode mid-flight is itself a strategic-portfolio decision.

**Neutral**:

- For single-brand adopters (one company, one product, brand
  unified) the default `inherit` mode means the workflow is
  identical to a CMO-validates-everything model. The 3-mode
  pattern only adds friction when an adopter actually wants
  brand independence — at which point the friction is the right
  amount of friction (a CEO ratification).
- The brand-spec pattern is orthogonal to the underlying brand
  artifact format. Adopters can store brand books as Figma files,
  PDFs, in-repo MDX, dedicated DAM systems, etc.; the spec
  mechanism only governs **authorization**, not artifact storage.

## Cross-references

- ADR 0014 (tech leadership restructure) — codifies the `cdo →
  design-lead` rename that this ADR depends on; together they
  ship in v0.8.0.
- ADR 0006 (CA owns agent_tool_matrix) — `brand-spec` is added
  to the canonical spec catalog under the new CTO ownership
  (per ADR 0014, the CTO holds what was CA's authority).
- ADR 0011 (CEO direct channel class) — unrelated but worth
  noting that brand-mode-ratification flows through CoS to CEO
  via the standard inbound_queue → CEO presentation route, not
  via `:send-ceo-only` (which is reserved for Critical
  notifications, not authorization gates).
- SYSTEM_INVARIANTS §5 (Universal CONFIDENTIAL List) — brand
  guidelines themselves are NOT on the universal list; brand
  identity is a deliberately external-facing artifact. The brand
  book is publishable per the disclosure policies CLO/CEthO
  approve, not blocked by §5.
- Future ADR (TBD) — when an adopter actually exercises
  `mode: independent` end-to-end and surfaces edge cases in the
  CMO advisory boundary, those may justify amendments to this
  ADR. v0.8.0 ships the structural framework; refinement happens
  on real adopter signal.
