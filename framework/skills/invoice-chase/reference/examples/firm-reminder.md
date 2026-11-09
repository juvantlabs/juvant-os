> Adapted from anthropics/knowledge-work-plugins `small-business/skills/invoice-chase` at commit e050c2e (Apache-2.0). Modified for juvant-os: rebuilt on the Morvento receivables list and the role card's firm-reminder step; consolidated invoices; statutory interest kept out of the draft and offered to the CEO separately; country-neutral; local rules from the country pack.

# Firm Reminder — example

**Scenario:** Run on 27 October 2026. Studio Varenna Srl has two open invoices: 2026/079 (EUR 4,880, due 24 September, 33 days late) and 2026/088 (EUR 2,440, due 22 October, 5 days late). A friendly reminder for 2026/079 went out on 2 October (found in the CEO's sent mail; date illustrative). No reply, no dispute in the mailbox.

**Step:** firm reminder (oldest invoice past 30 days, per `roles/finance.md`) · **Score:** `occasionally-late` (no paid invoices on record) · **Tone:** direct, with a pay-by date

**Saved as:** Outlook draft in the CEO's mailbox. (Shown in English; the real draft is in the language Morvento uses with this client, e.g. Italian.)

---

**Subject:** Overdue invoices 2026/079, 2026/088 — EUR 7,320

Dear [contact name],

following our reminder of 2 October, the following invoices are still unpaid:

- 2026/079 of 25 August, EUR 4,880, due 24 September (33 days overdue)
- 2026/088 of 22 September, EUR 2,440, due 22 October

Total due: EUR 7,320.

Please arrange payment by 5 November by bank transfer to [IBAN as on the invoices], reference "Invoices 2026/079 and 2026/088".

If there is a problem with either invoice, reply to this email and we'll sort it out quickly.

Kind regards,
[CEO name]
Morvento

---

**Note to the CEO (in the summary, not in the draft):** these are B2B invoices, so statutory late-payment interest (and, where the country's legal pack provides it, a recovery-cost compensation) would apply to 2026/079 from the day after the due date, e.g. 25 September, if you choose to claim them. I haven't included them: it's your call on the relationship. Confirm the rate in force with counsel or the accountant before claiming. If 2026/079 is still unpaid on 8 November (45 days), the next step is your call to the client; I'll prepare the brief.

---

**Why this works:**
- States the facts: invoices, amounts, due dates, days overdue, the earlier reminder.
- One clear pay-by date.
- Leaves a professional way out ("if there is a problem") without apologising.
- One call to action.
- Firm but courteous: no threats, no interest claim the CEO hasn't chosen.
