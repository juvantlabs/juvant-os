> Adapted from anthropics/knowledge-work-plugins `small-business/skills/month-end-prep` at commit e050c2e (Apache-2.0). Modified for juvant-os: QuickBooks/Xero/PayPal cases replaced by bank statement, e-invoicing and card-settlement cases for a company whose books are kept by an external accountant; country-neutral; local rules from the country pack.

# Gotchas

Common mistakes in preparing the monthly packet. Each entry: the pattern, why it matters, a Bad / Good example. Where a case depends on local rules (the e-invoicing system, which suppliers fall outside it), apply `.claude/country/finance.md` or `country/finance.md` if it exists; otherwise list the point under NOT CHECKED.

---

## Gotcha: Flagging one payment for several invoices as a mismatch

**Why it matters:** A client or the company often pays several invoices with one transfer. Matching one-to-one flags the transfer as unexplained and every invoice as unpaid.

### ✗ Bad

> Flagged: receipt of EUR 7,320 from Studio Varenna matches no invoice. Invoices 2026/079 (EUR 4,880) and 2026/088 (EUR 2,440) still open.

### ✓ Good

Before flagging, try combinations of the counterparty's open invoices that sum to the amount, and read the transfer description for invoice numbers. Only flag when no combination fits.

---

## Gotcha: Reading a reissued e-invoice as a duplicate (or missing a real one)

**Why it matters:** A supplier may cancel an invoice with a credit note and reissue it; both reach the e-invoice record. Counting both overstates payables; ignoring a real duplicate leads to paying twice.

### ✗ Bad

> Received invoices scanned: no duplicates.

(Only bank lines were scanned; the same supplier invoice arrived twice as an e-invoice and hasn't been paid yet.)

### ✓ Good

Scan received e-invoices as documents (same supplier, same total, within 5 days), then check for a credit note cancelling one of them. Say what was scanned: "received e-invoices and bank payments, repeats within 5 days".

---

## Gotcha: Treating a refund or credit note as a missing receipt

**Why it matters:** A refund appears as an inflow with no sales invoice behind it. It should match a credit note, not an invoice.

### ✗ Bad

> Flagged: EUR 89.00 received on 18 Oct from SoftCo matches no invoice.

### ✓ Good

Separate refunds from receipts. Match a supplier refund to the supplier's credit note (received e-invoices) or to the original card charge. Flag only if neither exists.

---

## Gotcha: Comparing gross card sales to net bank credits

**Why it matters:** If the company takes card or online payments, the provider pays out net of fees, often days later and in batches. Comparing gross amounts to the bank credit shows a "discrepancy" equal to the fee every time.

### ✗ Bad

> Discrepancy: payments of EUR 500.00, bank credit EUR 492.50, delta EUR 7.50.

### ✓ Good

Compare the provider's net payout to the bank credit; list the fees separately as a cost needing the provider's monthly fee statement (a document for the accountant). Delta under 0.50 (e.g. EUR) after fees: matched.

---

## Gotcha: Foreign software subscriptions with no paperwork

**Why it matters:** Card payments to foreign suppliers (cloud hosting, SaaS tools) usually don't come through the national e-invoicing system, if there is one. Without the supplier's invoice the accountant can't account for them correctly.

### ✗ Bad

> 12 card payments matched to the bank. All expenses accounted for.

### ✓ Good

For every card payment with no e-invoice, look for the supplier's invoice or receipt in the receipts folder and in Outlook (most send them by email; many also have it in the account's billing page, which the CEO must download). List the missing ones with supplier, date and amount.

---

## Gotcha: Writing the packet when flags are still open

**Why it matters:** The packet is what the accountant works from. Writing it with unacknowledged flags bakes errors into the books.

### ✗ Bad

> The CEO hasn't answered about the 3 unexplained receipts. Writing the packet now so there's something to send.

### ✓ Good

Hold at the review gate until the CEO has resolved or deferred every flag. Deferred items go into the open questions, marked "deferred", never dropped.
