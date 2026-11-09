> Adapted from anthropics/knowledge-work-plugins `small-business/skills/invoice-chase` at commit e050c2e (Apache-2.0). Modified for juvant-os: firmness now comes from the late-payer step in `roles/finance.md`; the payment-history score only adjusts warmth within the step; EUR and Italian payment details.

# Tone Matching

How firm and how warm each reminder is.

## Two inputs

- **The step** from `roles/finance.md` (friendly at 7 days, firm at 30 in the Morvento example) decides how firm the message is. It is the company's rule; the score never moves a client to a different step.
- **The payment-history score** decides warmth inside the step.

## Scoring

Score each client from the receivables list (and bank history if available) over the last 12 months. At least 3 paid invoices are needed to score; fewer defaults to `occasionally-late`.

| Score | Criteria |
|---|---|
| `good-payer` | Paid on or before the due date in ≥ 75% of invoices |
| `occasionally-late` | Paid late in 25–50% of invoices, or fewer than 3 invoices on record |
| `repeat-late` | Paid late in > 50% of invoices |

"On time" means the money reached the bank on or before the due date.

## Tone by step and score

| Step | good-payer | occasionally-late | repeat-late |
|---|---|---|---|
| Friendly | Warm, assumes oversight | Polite, factual | Polite, factual, asks for a payment date |
| Firm | Direct but courteous; one line acknowledging the good history | Direct, states a pay-by date | Direct, states a pay-by date, notes the previous reminder |

Firm is never rude: no threats, no capitals, no mention of lawyers or interest unless the CEO asked for it.

## Subject lines

Adapt to the language of the message; the shape stays:

- Friendly: `Reminder: invoice [N] of [date] — EUR [amount]`
- Firm: `Overdue payment: invoice [N] — EUR [amount], [X] days past due`
- Several invoices: `Overdue invoices [N1], [N2] — EUR [total]`

## Body checklist (every step)

- Invoice number(s), invoice date, original due date, amount of each, total due.
- Days overdue.
- Payment instructions exactly as on the invoice (IBAN, payment reference). Never new bank details.
- One call to action: pay, or reply with a payment date. Never two.

Step-specific:
- **Friendly:** one sentence that leaves room for oversight ("if payment is already on its way, please disregard this").
- **Firm:** one pay-by date, usually 7–10 days out; one sentence referring to the earlier reminder with its date.

## Consolidation

One message per client. List each invoice (number, date, due date, amount), then the total. The step comes from the oldest invoice; the tone from the client's score.
