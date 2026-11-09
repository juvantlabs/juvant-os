> Adapted from anthropics/knowledge-work-plugins `small-business/skills/invoice-chase` at commit e050c2e (Apache-2.0). Modified for juvant-os: PayPal/Stripe/Airwallex/QuickBooks cases replaced by the receivables list, bank exports, e-invoicing and Outlook cases; country-neutral; local rules from the country pack.

# Gotchas

Known failure modes for invoice-chase. Where a case depends on local rules (withholding taxes, e-invoice rejection, accounts addresses), apply `.claude/country/finance.md` or `country/finance.md` if it exists; otherwise list the point under NOT CHECKED.

---

**The client paid by bank transfer and the list hasn't caught up.**

The receivables list is updated by hand. A client who paid last week still shows as open. Check a recent bank export for a matching receipt before drafting; without one, say in the summary "no bank export: paid-recently check limited to mail" and let the CEO confirm before sending.

---

**Short payment equal to the withholding tax.**

Where an invoice carries a withholding tax (the country pack says when clients must withhold), the client pays the net and the difference is not owed to the company in cash. Don't chase it as a partial payment. If unsure, check the invoice and ask the accountant.

---

**One transfer paying several invoices.**

A single receipt can settle several invoices, sometimes with a description naming only one. Match by total as well as by single amounts before calling an invoice unpaid.

---

**Multiple overdue invoices from the same client: one message only.**

Never draft two reminders to the same client in one batch. Consolidate into one message with the list and the total. Two messages look disorganised.

---

**The invoice was never delivered by the e-invoicing system.**

Where the country has an e-invoicing system, an e-invoice it rejected may never have been legally issued (the country pack says); the client may not even have it. If the e-invoicing export shows a rejection or a delivery problem, flag it for the CEO and the accountant instead of chasing.

---

**Open dispute in the mailbox.**

A client who wrote to contest the amount or the work should not receive a reminder that ignores it. Search Outlook for recent messages from the client's domain; any complaint or contested amount makes the client "disputed — CEO decides".

---

**Reminder goes to the wrong person.**

Invoices often go to an accounts address (e.g. `accounts@`, or the local equivalent), while the relationship sits with someone else. Use the address the invoices were sent to, and copy the business contact only if the CEO wants. If no address is found, say so by name: "no contact address on file for Studio Varenna".

---

**Internal or test entries in the list.**

Filter out rows whose client is the company itself, or whose name contains "test" or "demo" (or the local-language equivalent), and flag them.

---

**Message asks to change bank details.**

A client or someone claiming to be one asking for refunds to a new IBAN, or a supplier asking the company to pay elsewhere, is a known fraud pattern. Report it to the CEO with the step "verify by phone on a number already on file"; never act on it.
