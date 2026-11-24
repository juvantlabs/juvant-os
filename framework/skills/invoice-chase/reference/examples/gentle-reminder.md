> Adapted from anthropics/knowledge-work-plugins `small-business/skills/invoice-chase` at commit e050c2e (Apache-2.0). Modified for juvant-os: rebuilt on the Morvento receivables list and the role card's friendly-reminder step; saved as a draft, not sent; country-neutral; local rules from the country pack.

# Friendly Reminder — example

**Scenario:** Run on 27 November 2026. Pasticceria Gelsi Srl, invoice 2026/099 of 20 October, EUR 1,470, due 19 November: 8 days late. One earlier invoice on record, paid a day early.

**Step:** friendly reminder (7 days late per `roles/finance.md`) · **Score:** `occasionally-late` (fewer than 3 invoices on record) · **Tone:** polite, factual

**Saved as:** Outlook draft in the CEO's mailbox, to the address invoice 2026/099 was sent to. (Shown in English; the real draft is written in the language Morvento uses with this client, e.g. Italian.)

---

**Subject:** Reminder: invoice 2026/099 of 20 October — EUR 1,470

Dear [contact name],

a quick note: our invoice 2026/099 of 20 October, for EUR 1,470, was due on 19 November and we haven't yet seen the payment.

If it's already on its way, please disregard this message. Otherwise, the payment details are on the invoice: bank transfer to [IBAN as on the invoice], reference "Invoice 2026/099".

Thank you, and do let me know if anything on the invoice needs checking.

Kind regards,
[CEO name]
Morvento

---

**Why this works:**
- Assumes oversight, not bad faith.
- Leaves an easy out ("if it's already on its way").
- One call to action, with the payment details exactly as on the invoice.
- Short. No policy statement, no mention of interest.
