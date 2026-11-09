> Adapted from anthropics/knowledge-work-plugins `small-business/skills/cash-flow-snapshot` at commit e050c2e (Apache-2.0). Modified for juvant-os: ledger/PayPal cases replaced by the receivables list, bank and e-invoicing exports, and recurring salary and tax patterns; country-neutral; local rules from the country pack.

# Gotchas — cash-flow-snapshot

Known edge cases in the data. Where a case depends on local rules (withholding taxes, bank export formats, the tax calendar), apply `.claude/country/finance.md` or `country/finance.md` if it exists; otherwise list the point under NOT CHECKED.

---

## 1. The receivables list says open, the bank says paid

**Bad:** Counting every row without `paid_on` as a future inflow. The list is updated by hand and lags the bank; a client who paid last week inflates the forecast.

**Good:** Check open invoices against a recent bank export (amount plus client name or invoice number in the transfer description). A match means "possibly paid — verify": leave it out of inflows and list it for the CEO to update the list.

---

## 2. Payments net of withholding tax

**Bad:** Expecting the full invoice total from a client that withholds tax (e.g. on professional fees, where the country requires it) and then flagging the shortfall as a late or partial payment.

**Good:** Where the invoice carries a withholding, the inflow is the net amount; the withheld part is a tax credit, not cash. If unsure whether an invoice carries one, check the invoice and ask the accountant.

---

## 3. Bank and spreadsheet exports name columns differently

**Bad:** Requiring exact names like "Date", "Amount". Bank exports use local names (the country pack lists them), separate value and booking dates, or separate debit and credit columns; rigid parsing fails silently.

**Good:** Match loosely (date → booking date → transaction date; amount, or credit − debit; description → reference / narrative). Use the value date for cash timing. Show the header row and confirm the mapping before computing: one question beats a silent wrong forecast.

---

## 4. Fixed costs hidden among one-off payments

**Bad:** Only modelling costs someone labelled as recurring. Rent, software and utilities often appear as separate bank debits or supplier invoices each month with nothing marking them recurring.

**Good:** Treat payments to the same counterparty in 3+ consecutive months with similar amounts (±10%) as recurring. Show the list to the CEO: "I'm treating these as fixed monthly costs; does that look right?"

---

## 5. Lumpy outflows that monthly averages hide

**Bad:** Spreading fixed costs evenly at "about EUR 30,000 a month". Extra monthly salaries, larger tax payments that follow them, income-tax balances and advances, and annual insurance and licences all land on specific dates (the country pack gives the local calendar).

**Good:** Place each outflow on its own date. Ask the CEO or the accountant for extra-salary and tax-advance amounts rather than estimating them.

---

## 6. Band formula breaks on small or zero delays

**Bad:** Dividing the standard deviation of payment delay by the mean delay. Clients who pay on the due date have a mean delay near zero and the band explodes.

**Good:** Divide by the payment term in days (e.g. 30), as in the SKILL. If a client always pays on time with near-zero variance, set its band to 5%.

---

## 7. Band applied to the net

**Bad:** low = net × (1 − band). When the net is negative this makes the low case *better* than expected.

**Good:** Apply the band to inflows only (outflows are mostly fixed): low = inflows × (1 − band) − outflows.

---

## 8. Invoices already in escalation

**Bad:** Counting an invoice 50 days late as next month's inflow because "they'll pay eventually".

**Good:** Past the CEO-call step in the role card, show it as upside and as a risk, not as an expected inflow.
