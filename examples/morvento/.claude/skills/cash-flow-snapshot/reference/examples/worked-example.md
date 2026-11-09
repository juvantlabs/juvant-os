> Adapted from anthropics/knowledge-work-plugins `small-business/skills/cash-flow-snapshot` at commit e050c2e (Apache-2.0). Modified for juvant-os: rebuilt on the Morvento example (receivables list, role card), Italian outflows, finance agent output shape.

# Worked example — cash-flow-snapshot

**Scenario:** Morvento, six-person B2B software company. Run on 9 November 2026. Sources: `samples/finance/receivables.csv`, a bank balance export from the CEO, fixed costs and an invoicing plan from the CEO, F24 and tax-advance amounts from the commercialista. No payables list. The bank, fixed-cost, tax and plan figures below are illustrative.

---

## Input data

**Opening balance:** EUR 112,000 at 6 Nov 2026 (bank export, provided by the CEO).
**Minimum buffer** (`roles/finance.md`): EUR 90,000.

**Open receivables** (receivables list, no `paid_on`):

| Invoice | Client | Due | Amount | Days late on 9 Nov |
|---|---|---|---|---|
| 2026/079 | Studio Varenna Srl | 24 Sep | EUR 4,880 | 46 |
| 2026/088 | Studio Varenna Srl | 22 Oct | EUR 2,440 | 18 |
| 2026/096 | Ottica Brenta Snc | 12 Nov | EUR 3,660 | — |
| 2026/099 | Pasticceria Gelsi Srl | 19 Nov | EUR 1,470 | — |

**Payment history** (paid invoices in the list, delay vs due date):

| Client | Payments on record | Delay |
|---|---|---|
| Pasticceria Gelsi | 1 | −1 day |
| Ottica Brenta | 1 | +5 days |
| Ferrolino Logistica | 1 | −1 day |
| Agriturismo Le Querce | 1 | −2 days |
| Studio Varenna | 0 | — |

Every client has fewer than 3 payments: default ±30% band.

**Invoicing plan** (CEO): about EUR 26,000 of work invoiced at each month end, 30-day terms.

**Fixed costs and taxes** (CEO and commercialista):

| Date | Item | Amount |
|---|---|---|
| 16 Nov | F24 (October VAT, withholdings, INPS) | EUR 9,800 |
| 27 Nov | Net salaries | EUR 16,500 |
| 30 Nov | IRES/IRAP second advance | EUR 6,000 |
| 1 Dec | Rent and subscriptions | EUR 3,700 |
| 16 Dec | F24 | EUR 9,800 |
| 27 Dec | Net salaries + 13th month | EUR 30,500 |
| 1 Jan | Rent and subscriptions | EUR 3,700 |
| 16 Jan | F24 (incl. withholdings on the 13th month) | EUR 12,500 |
| 27 Jan | Net salaries | EUR 16,500 |
| 1 Feb | Rent and subscriptions | EUR 3,700 |

---

## Step 3 — placing the inflows

| Invoice | Amount | Expected receipt | Window | Note |
|---|---|---|---|---|
| 2026/096 Ottica Brenta | EUR 3,660 | 17 Nov | 0–30 | due 12 Nov + 5-day delay |
| 2026/099 Pasticceria Gelsi | EUR 1,470 | 18 Nov | 0–30 | due 19 Nov, pays a day early |
| November work (planned) | EUR 26,000 | 30 Dec | 31–60 | not yet invoiced |
| December work (planned) | EUR 26,000 | 30 Jan | 61–90 | not yet invoiced |
| Studio Varenna, 2 invoices | EUR 7,320 | — | upside | oldest 46 days late: past the CEO-call step |

---

## Step 4 — forecast (9 Nov 2026 → 7 Feb 2027)

Band ±30% on inflows.

| Window | Inflows | Outflows | Net | Closing cash | Low | High |
|---|---|---|---|---|---|---|
| 0–30 days | EUR 5,130 | EUR 36,000 | −EUR 30,870 | EUR 81,130 | EUR 79,591 | EUR 82,669 |
| 31–60 days | EUR 26,000 | EUR 44,000 | −EUR 18,000 | EUR 63,130 | EUR 53,791 | EUR 72,469 |
| 61–90 days | EUR 26,000 | EUR 32,700 | −EUR 6,700 | EUR 56,430 | EUR 39,291 | EUR 73,569 |

Low and high closing cash assume the low (or high) case in every window.
Upside not counted: EUR 7,320 from Studio Varenna.

---

## Output

```
VERDICT: STOP
(closing cash goes below the EUR 90,000 buffer within 30 days: no new spending before the CEO has read this)

FIGURES
Cash Flow Snapshot — 9 Nov 2026 → 7 Feb 2027
Sources: receivables list (to 6 Nov), bank export (6 Nov), fixed costs and
invoicing plan from the CEO, F24 and tax advance from Dott. Rinaldi.
Opening balance: EUR 112,000 at 6 Nov 2026
Minimum buffer: EUR 90,000

[forecast table above]
Upside not counted: EUR 7,320 (Studio Varenna, 2026/079 and 2026/088)

FINDINGS
1. [high] Buffer breach — closing cash EUR 81,130 by 9 Dec and EUR 56,430 by
   7 Feb (low band EUR 39,291), against a EUR 90,000 buffer — the 13th month
   and the January F24 drive the drop — propose the CEO reviews planned
   spending and the invoicing timing for December.
2. [high] Studio Varenna — EUR 7,320 open, 2026/079 is 46 days late (CEO call
   due at 45 days per the role card) — propose the CEO calls this week;
   invoice-chase can prepare the call brief.
3. [medium] Inflows in 31–90 days are entirely planned invoices — if
   November's invoicing slips, the 31–60 window loses EUR 26,000 —
   propose confirming the November invoices go out on 30 Nov.
4. [medium] Thin data — at most one payment on record per client — bands set
   to the default ±30%.

NOT CHECKED
No payables list or SDI received-invoices export: supplier payments are not in
the outflows, so the forecast is optimistic by whatever suppliers are owed.
F24 and tax-advance amounts are the commercialista's estimates; confirm before
16 Nov. This is an aid, not financial advice.
```
