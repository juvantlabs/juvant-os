# Thresholds

> Adapted from anthropics/knowledge-work-plugins `small-business/skills/business-pulse` at commit e050c2e (Apache-2.0). Modified for juvant-os: cut-offs come from `roles/finance.md` first, with defaults only where the role card is silent; payments, ads and pipeline-coverage thresholds removed; statuses as words.

Status cut-offs for each section. **`roles/finance.md` wins** wherever it states a
rule; the defaults below apply only where it's silent. When a default is used,
the appendix says so, and suggests the CEO add the rule to `roles/finance.md` if
they want a different one.

Amounts are in euro ([currency and locale](../../kwp-shared/currency-and-locale.md)).

---

## Cash

**Against the buffer** (`roles/finance.md`, e.g. "three months of fixed costs,
about € 90.000"):
- **OK**: at or above the buffer
- **Review**: below the buffer, or a payment due in the next 14 days would take it
  below
- **Critical**: below two-thirds of the buffer

If the role card has no buffer, default: OK ≥ 6 months of fixed costs; Review 3–6;
Critical < 3. If fixed costs aren't known either, show the balance and its change
only, with no status.

**Export age**: a bank export older than 7 days caps the section at **Review**,
with the date shown.

---

## Receivables

Use the payment terms and the late-payer ladder in `roles/finance.md`. With
Morvento's ladder (7 / 30 / 45 / 60 days):
- **OK**: nothing more than 7 days past due
- **Review**: anything 8–44 days past due
- **Critical**: anything 45+ days past due, or the 61+ bucket over 10% of
  receivables

Every invoice past the first step of the ladder is named, with its next step.

Default ladder if the role card has none: Review at 31 days, Critical at 61.

Italian late-payment interest (D.Lgs. 231/2002) may apply to B2B invoices; the
pulse mentions it only as "late-payment interest may apply; check with the
commercialista" and never computes it.

---

## Proposals

- **Review**: a proposal with no answer for 14+ days, or a date we promised
  passed
- **Critical**: a promise the CEO made that's due today or overdue

---

## Deadlines

- **Review**: a deadline from `roles/finance.md` or the calendar within 7 days
  with its inputs not yet ready (e.g. receipts missing for the commercialista)
- **Critical**: within 2 working days and not ready

---

## Watch list

No numeric thresholds. Any escalation, PEC, or second unanswered client email is
surfaced. Severity is the CEO's call.

---

## Overall status

The overall status is the worst section status. Override: if a risk names a
specific client or counterparty, an amount and a deadline within 7 days, the
overall is **Critical** whatever the sections say.
