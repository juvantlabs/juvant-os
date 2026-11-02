# ADR 0035 — Multi-library document spaces: `libraries{}` with purpose-based selection

## Status

**Proposed** — 2026-11-02. Origin: BUG-094 R4 (`juvantlabs/juvant-os-pm#197`),
from an adopter handoff. **Extends ADR 0023** (document spaces) and **ADR 0025**
(sensitive-space access control). It does not supersede any clause of either.

## Context

ADR 0023 models a promoted space as **one** container. `spaces.<role>.resource_ids`
carries a single `drive_id` (SharePoint document library) or a root `file_id`
(Google Shared Drive). Real org spaces often hold **several libraries, each with
a purpose**. A finance site typically has a general working library, an invoices
archive, and an exchange library shared with the external accountant.

With one `drive_id` per space, an adopter has two bad options:

1. **Bind only one library.** The others are unreachable through
   `resolve_space`, so agents either cannot file there or reach them through
   ad-hoc paths that bypass resolution. This is the same bypass class as
   BUG-094.
2. **Promote each library as its own role key** (`finance-invoices`, …). This
   breaks the role → space mapping that templates rely on (`resolve_space(finance, cfo)`).

A third risk applies to sensitive spaces. The ADR 0025 hard perimeter is keyed on
`(AGENT_ROLE, driveId)`. If a sensitive space has more libraries than its
`space_access` rule lists, the unlisted libraries sit **outside** the perimeter.
Nothing detects that today.

## Decision

1. **A space may carry `libraries{}`.** The key is a short library name. Each
   value has:
   - `resource_ids` (required): the provider ID of that library, i.e.
     `drive_id` for SharePoint, root `file_id` for a Google Shared Drive.
     Provider-neutral, the same shape as the space-level `resource_ids`.
   - `purpose` (required): one line saying what belongs there. Agents match it
     against the document they are handling.
   - `path` (optional): the root inside the library. Defaults to the
     space-level `path`.
   - `access` (optional): external guests granted on **this library only**.
     Same entry shape as ADR 0023 `access[]`. The space-level `access[]` keeps
     space-wide grants.
2. **`default_library` is required when `libraries{}` is present.** It names
   the library used when no other library's purpose clearly matches. The
   space-level `resource_ids` keeps the shared IDs (e.g. `site_id`). When
   `libraries{}` is present, the space-level `drive_id` is ignored for
   resolution, and it should be omitted.
3. **Selection by purpose**, in `resolve_space(role, caller, library=None)`:
   - **Explicit name.** The caller names a library that exists → use it. An
     unknown name is an error: surface `[<ROLE> LIBRARY UNKNOWN]`. Never fall
     back silently.
   - **No name, write.** The agent picks the library whose `purpose` matches
     the document class, and **states the choice and the purpose it matched**
     in its response (e.g. "filing in finance/invoices — purpose: issued and
     received invoices"). If no purpose clearly matches, or more than one
     does, it uses `default_library` and says so. A write never targets a
     library that was not chosen by one of these two rules.
   - **No name, read.** The agent may search every library in the space. It
     cites the library it read from.
   - **No `libraries{}`.** Behaviour is unchanged from ADR 0023 (one container).
4. **The sensitive-space perimeter covers every library.** For a space with
   `agent_allowlist` (ADR 0025), every library's drive ID must appear in the
   `drive_ids` of a `space_access` rule in the committed `security/policy.json`
   (ADR 0034). `helpers/doc-storage-check.sh` flags each uncovered library as
   `[DOC STORAGE PERIMETER GAP] <role>/<library>`. A gap is a security
   finding, not a style warning.
5. **Config validation.** `helpers/doc-storage-check.sh` (BUG-094) also flags
   `[DOC STORAGE LIBRARY CONFIG]` when:
   - `default_library` is missing or names no library;
   - a library has no drive ID or no `purpose`;
   - two libraries in the same space share a drive ID.

## Consequences

**Positive**
- Multi-library org spaces are modeled directly. Templates keep calling
  `resolve_space(<role>, <caller>)`; the library is an optional argument, so
  no template has to change.
- Writes into a multi-library space are explainable: the chosen library and
  its matched purpose appear in the agent's response and can be audited.
- A sensitive space can no longer quietly grow an unprotected library.

**Negative / costs**
- Purpose matching is a judgement made by the agent, not a deterministic
  rule. This is mitigated by the stated choice, by the `default_library`
  fallback, and by never guessing between two matching purposes.
- One more config block to maintain. A library added in SharePoint is
  invisible to agents until it is added to `libraries{}`. That is the
  intended default.

**Neutral**
- `access[]` semantics are unchanged: external guests only (ADR 0023). A
  library-level `access[]` only records a narrower grant.
- No schema change in Turso. The model lives in `.juvant/config.json`
  `doc_storage`.

## Alternatives considered

- **One role key per library** (`finance-invoices`). Rejected: it breaks the
  role → space contract and multiplies the `agent_allowlist` and policy entries.
- **Keyword or regex routing rules per library** (deterministic matching).
  Rejected for v1: brittle across document types and languages. Free-text
  `purpose`, a stated choice and a default give enough control. This can be
  revisited if audits show misfiling.
- **Auto-discovering libraries from the site at runtime.** Rejected: an
  unlisted library would become writable without a config change and without
  a perimeter check (Decision 4).

## References

- ADR 0023 — document spaces; ADR 0025 — sensitive-space access control;
  ADR 0034 — committed security policy.
- BUG-094 — `juvantlabs/juvant-os-pm#197` (R4).
- `JUVANT_OS.md` § "Wizard — Step 1.5"; `docs/DOCUMENT_SPACES.md`.
