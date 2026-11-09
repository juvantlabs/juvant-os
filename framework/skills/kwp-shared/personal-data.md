# Personal data: what never leaves the source

> Adapted from anthropics/knowledge-work-plugins `small-business/shared/personal-data.md` at commit e050c2e (Apache-2.0). Modified for juvant-os: Italian identifiers (codice fiscale, IBAN) and GDPR framing; payroll systems replaced by the commercialista's documents; skill list aligned.

**Shared across skills.** Bank exports, SDI e-invoices, payslips and payroll
summaries from the commercialista, contracts, mail threads and client
data return more about a person than any deliverable needs. The rule is the same
in every skill: use a field to do the work, never reproduce it. This also keeps
outputs in line with GDPR data minimisation; it is not a substitute for advice
from counsel on GDPR questions.

---

## Never reproduced, in any output

Not in chat, not in a brief, not in an HTML page, not in a spreadsheet, not in a
file under `drafts/` or `memory/`, not in a draft email, not in a log line or
`state/activity.jsonl`:

- Personal tax codes (codice fiscale) and national ID numbers of individuals. A
  company's VAT number (partita IVA) on an invoice is the expected exception.
- Dates and places of birth.
- Home addresses of employees and contractors. A work location is fine.
- Full card numbers, CVVs and expiry dates. The last four digits identify a
  card; nothing more is needed.
- Full IBANs and bank account numbers, the company's or anyone else's. The bank
  name or the last four characters is the limit.
- Identity documents (carta d'identità, passport) as images or numbers.
- Health data, including sick-leave reasons (certificati medici).

When a source carries one of these (an e-invoice XML with a sole trader's codice
fiscale, a bank export with full IBANs, a payslip), it is read for the step that
needs it and dropped. It is not copied into working notes, not echoed back to
confirm, and not left in a rendered page.

---

## Kept to the output that needs it

- **Per-person pay** (salary, hours, gross, net, deductions) appears only in
  outputs prepared for the commercialista or the CEO about payroll, never in a
  brief, a pulse, a hiring output or a customer-facing draft. Total payroll cost
  as one line in a cash view is fine.
- **Medical, disability, leave-reason and other special-category details**
  (GDPR art. 9) seen in a CV, a leave request or a message are not carried into
  any note or output.
- **Client and customer contact details** go only where the skill's step needs
  them: the draft addressed to that person. Never into a team-wide channel post
  or a page meant for a wider audience.
- **Client data processed by the company's product** belongs to the client (see
  the manifesto). A skill never pulls it into marketing, examples or case
  studies without the written consent the manifesto or `roles/legal.md`
  requires.

---

## When the CEO asks for it anyway

Say the field is not reproduced by these skills and point to the source (the
bank portal, the SDI portal, the commercialista's documents), where it sits under
its own access controls. One line, no lecture.

---

## Skills this governs

The finance skills (`cash-flow-snapshot`, `invoice-chase`, `month-end-prep`),
`business-pulse`, `monday-brief`, `inbox-manager` and `proposal-builder` first.
Every other skill applies it the moment a source returns one of the fields
above.
