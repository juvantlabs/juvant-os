# Sources: what skills read, and one source of record per figure

> Adapted from anthropics/knowledge-work-plugins `small-business/shared/connector-neutrality.md` at commit e050c2e (Apache-2.0). Modified for juvant-os: the vendor-peer table (ledgers, CRMs, payments, payroll) is replaced by the sources juvant-os actually has; the source-of-record and capability-honesty rules are kept; plugin-registration notes removed.

**Shared across skills.** A skill runs on what the company actually has. It
never recommends a vendor, and it never pretends a source exists.

---

## The sources juvant-os has

| Category | Source | Access |
|---|---|---|
| Mail | Outlook, through the Microsoft 365 connector | Read; drafts only |
| Calendar | Outlook calendar, through the Microsoft 365 connector | Read only |
| Files | SharePoint / OneDrive, through the Microsoft 365 connector | Read (scoped per `tenant-scope.md`) |
| Team chat | Teams, through the Microsoft 365 connector | Read only |
| Company context | The repo: `manifesto.md`, `roles/*.md`, `memory/knowledge/`, `memory/map.md`, `memory/decisions/`, `state/activity.jsonl`, `drafts/` | Read; skills write only to `drafts/` unless their SKILL.md says otherwise |
| Bank | Exports (CSV, PDF statements) the CEO provides | Read only |
| E-invoicing (SDI) | Exports or lists the CEO provides (XML, CSV, PDF) | Read only |
| Bookkeeping, payroll, tax filings | The commercialista | Documents the CEO forwards |

There is no CRM, no accounting ledger connector, no payments processor, no
payroll system and no e-signature tool. Skills that would use one in their
original form read the closest real source instead (a receivables export, a
pipeline list in `memory/` or SharePoint, past proposals) or ask the CEO.

---

## Rules

**Name what was read.** Every brief, pulse or proposal says which sources it
used, and which ones it could not reach, in one quiet line.

**One figure, one source of record.** When two sources hold the same figure (a
receivables total in an SDI export and in the commercialista's spreadsheet), the
total comes from one, the output says which, and the other is used only to flag
differences. Never sum the same figure across two sources. If it's unclear which
is authoritative, ask once; if the answer should hold, propose adding it to
`roles/finance.md` or `memory/map.md`.

**State capability limits as facts.** "The bank export stops at 31 October, so
November is not included" is a capability statement. Write those, in one line,
with what the skill does instead.

**Exports are snapshots.** Always show the date an export was produced (or the
last date it contains). A cash figure from a three-week-old statement is labelled
as such, never presented as today's.

**Missing is a normal path.** No export, no mailbox, nothing in `memory/`: ask the
CEO for the handful of figures the skill needs, label them "CEO-supplied", and
build the same output from them.

---

## What this does not change

- **Hard limits.** Nothing here widens what a skill may do. Outbound is
  draft-only; no skill writes to a bank, to SDI, or to anything outside the repo
  and the Outlook drafts folder.
- **Honesty about scope.** A skill that only covers Italian rules says so
  (`currency-and-locale.md`).
