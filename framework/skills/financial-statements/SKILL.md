---
name: financial-statements
description: "Read and explain the financial statements the commercialista prepares: the periodic situazione contabile, the trial balance and the annual bilancio (income statement, balance sheet, cash flow). Use to compare periods, flag material variances, explain what the numbers mean for the CEO, or prepare questions for the commercialista. Not for producing the books."
argument-hint: "<monthly|quarterly|annual|ytd> <period>"
allowed-tools: Read, Grep, Glob
---

> Adapted from anthropics/knowledge-work-plugins `finance/skills/financial-statements` at commit e050c2e (Apache-2.0). Modified for juvant-os: reads and explains statements the commercialista prepares instead of generating them; US GAAP/ASC replaced by the Italian civil-code layout (artt. 2424–2425-ter c.c.) and OIC principles; output fits the finance agent's shape.

# Financial statements

**Important**: this skill assists in reading financial statements but does not provide financial advice. The statements are prepared by the commercialista, who is responsible for them; this skill explains them, compares periods and prepares questions. Anything used for filings, financing or tax decisions stays with the commercialista.

## Usage

```
financial-statements <period-type> <period>
```

- `period-type`:
  - `monthly`: a monthly situazione contabile, compared with the prior month and the same month last year
  - `quarterly`: a quarter, compared with the prior quarter and the same quarter last year
  - `annual`: the year's bilancio, compared with the prior year
  - `ytd`: year to date, compared with the prior year's same period
- `period`: e.g. `2026-10`, `2026-Q3`, `2025`

## Workflow

### 1. Gather the statements

Read before asking:

- `roles/finance.md`: the company's rules and the commercialista's name.
- `memory/map.md`: where the commercialista's files live (SharePoint/OneDrive folder, mail attachments).
- The statements for the period and the comparison periods: *situazione contabile* or *bilancio di verifica* (trial balance), and for the year the *bilancio d'esercizio* with its *nota integrativa*. Read them through the Microsoft 365 connector (SharePoint/OneDrive files, or attachments in Outlook) or from files the CEO provides.
- A budget or plan, if one exists (`memory/decisions/`).

If something is missing, ask the CEO for that file specifically ("the September situazione contabile from Dott. Rinaldi"), not for "the numbers". Never reconstruct a statement from bank movements and present it as the commercialista's: if you build an indicative view from cash, label it clearly as such.

Note what the statement is: interim statements usually lack period-end entries (depreciation, accruals and deferrals, TFR accrual, provision for doubtful receivables, taxes), so profit in a monthly situazione is normally overstated relative to year end. Say so whenever you compare an interim period with a full year.

### 2. Present the income statement (Conto economico)

Italian statutory statements follow the civil-code layout (art. 2425 c.c.), which classifies costs by nature. Present the commercialista's figures in that structure, with comparisons:

```
INCOME STATEMENT (Conto economico)
Period: [description]          Source: [file, prepared by, date]
(EUR)

                                         Current   Prior    Var EUR   Var %   Budget   Bud var
A) VALUE OF PRODUCTION
   1) Revenue from sales and services
   5) Other revenue and income
   Total A
B) COSTS OF PRODUCTION
   6) Raw materials and goods
   7) Services
   8) Use of third-party assets (rent, leases)
   9) Personnel (wages, social contributions, TFR, other)
  10) Depreciation, amortisation and write-downs
  14) Other operating costs
   Total B
DIFFERENCE A - B (operating result)
C) FINANCIAL INCOME AND CHARGES
D) VALUE ADJUSTMENTS OF FINANCIAL ASSETS
RESULT BEFORE TAXES
  20) Income taxes (IRES, IRAP)
NET RESULT FOR THE PERIOD
```

Show only the lines the statement contains. If the commercialista's interim report uses a management layout instead (revenue, direct costs, gross margin, overheads), follow it and say so.

Useful management views on top, computed from the statement and labelled as your computation:

- **Gross margin** for a services company: revenue minus direct costs (services bought for delivery, freelancers, delivery staff if separable).
- **EBITDA**: A − B excluding item 10 (depreciation and write-downs).
- **Personnel cost as % of revenue**, **services as % of revenue**.

### 3. Variance analysis

For each line:

- **Euro variance**: current − comparison.
- **Percentage variance**: (current − comparison) / |comparison| × 100.
- **Point change** for margins and ratios.

#### Materiality

Agree thresholds with the CEO and propose recording them in `roles/finance.md`. Starting points for a small company:

| Line size (annual) | Euro threshold | Percentage threshold |
|---|---|---|
| > EUR 500,000 | EUR 10,000 | 5% |
| EUR 50,000 – 500,000 | EUR 5,000 | 10% |
| < EUR 50,000 | EUR 2,000 | 15% |

Either threshold exceeded makes a variance material. For monthly statements, scale down.

#### Decomposition

Break each material variance into drivers (method in the `variance-analysis` skill):

- **Volume** (days sold, licences) and **rate/price**.
- **Mix** between revenue types or cost categories.
- **New or discontinued** clients, products, suppliers.
- **One-off** items.
- **Timing**: an item booked in a different period from the one it belongs to; frequent in interim statements.
- **Booking effects**: a reclassification or a period-end entry by the commercialista, not a business change.

#### Explanation

For each material variance:
1. Quantify (EUR and %).
2. Favourable or unfavourable.
3. Decompose into drivers.
4. Give the business reason, if known from the data or `memory/`; otherwise write it as a question.
5. Say whether it is temporary or a trend.
6. Note the action (none, monitor, ask the commercialista, ask the CEO).

### 4. Key metrics

```
KEY METRICS                    Current   Prior    Change
Revenue growth (%)                                X.X%
Gross margin (%)               XX.X%     XX.X%    X.X pt
EBITDA margin (%)              XX.X%     XX.X%    X.X pt
Net margin (%)                 XX.X%     XX.X%    X.X pt
Personnel cost / revenue (%)   XX.X%     XX.X%    X.X pt
Days sales outstanding         XX        XX       X
Cash / monthly fixed costs     X.X       X.X      X.X   (vs the buffer in roles/finance.md)
```

### 5. Material variance list

| Line | Variance (EUR) | Variance (%) | Direction | Likely driver | Action |
|---|---|---|---|---|---|
| | | | Unfav. | | Ask commercialista |

### 6. Questions for the commercialista

Write the questions the statements raise, each tied to a line and an amount: entries that look misclassified, period-end entries not yet booked, receivables that look doubtful, differences from the company's own receivables/payables lists. These go into the monthly packet (`month-end-prep`) or into a draft email to the commercialista (Outlook draft, or `drafts/<name>.md`) for the CEO to send.

## Reading the balance sheet (Stato patrimoniale)

Layout of art. 2424 c.c., in short:

```
ASSETS (Attivo)
A) Amounts due from shareholders for unpaid capital
B) Fixed assets
   I   Intangible (software, development costs, trademarks)
   II  Tangible (equipment, furniture, hardware)
   III Financial (shareholdings, long-term receivables)
C) Current assets
   I   Inventory (incl. work in progress on orders)
   II  Receivables (trade receivables, tax receivables such as VAT credit, other)
       — shown separately when due beyond 12 months
   III Current financial assets
   IV  Cash and bank
D) Accrued income and prepaid expenses (ratei e risconti attivi)

LIABILITIES AND EQUITY (Passivo)
A) Equity (share capital, reserves, retained earnings, result for the year)
B) Provisions for risks and charges
C) Employee severance indemnity (TFR)
D) Payables (bank loans, trade payables, tax payables, social security payables, other)
   — shown separately when due beyond 12 months
E) Accrued expenses and deferred income (ratei e risconti passivi)
```

What to look at for a small company:

- **Cash** (C.IV) against the minimum buffer in `roles/finance.md`.
- **Trade receivables** (C.II) against the company's receivables list; a gap is a reconciliation item. Check whether a provision for doubtful receivables exists for old items.
- **Tax and social-security payables** (D): VAT, withholdings and INPS due with the next F24.
- **TFR** (C): a real liability that grows every month and is paid when people leave.
- **Deferred income** (E): annual licences invoiced in advance; revenue not yet earned.
- **Equity**: losses that erode share capital beyond the civil-code thresholds trigger obligations for the directors; if equity looks low against share capital, raise it with the commercialista and counsel without stating the legal consequences yourself.

## Reading the cash flow statement (Rendiconto finanziario)

Required by art. 2425-ter c.c. for companies filing the full bilancio; companies filing the abridged form (art. 2435-bis) or as micro-companies (art. 2435-ter) are exempt, so it may not exist. If it does, it usually uses the indirect method (OIC 10):

```
A) Cash flow from operating activities
   Net result, plus taxes, interest, depreciation and other non-cash items,
   plus/minus changes in working capital (receivables, payables, inventory,
   accruals and deferrals), minus taxes and interest paid
B) Cash flow from investing activities
C) Cash flow from financing activities
Increase (decrease) in cash = A ± B ± C
Opening cash, closing cash
```

If there is none, a simple view from two balance sheets and the income statement (result + depreciation ± change in receivables, payables and TFR) is a reasonable indication; label it as your computation.

## Common period-end entries to expect

Interim statements often lack these; the annual bilancio includes them. Use the list to explain why year-end profit differs from interim figures, and to ask the commercialista whether they've been booked:

1. **Accruals and deferrals** (*ratei e risconti*): costs and revenue split across periods (insurance, annual licences sold or bought).
2. **Depreciation and amortisation** of fixed assets.
3. **TFR accrual** for the period.
4. **13th/14th month accruals** where the collective agreement provides them.
5. **Provision for doubtful receivables** based on ageing.
6. **Invoices to issue or receive** (*fatture da emettere / da ricevere*) for work done or received in the period.
7. **Taxes**: IRES and IRAP for the year.
8. **Work in progress** on orders spanning year end.

## Statutory basics, for context only

- The annual bilancio is approved by the shareholders and filed with the Companies Register; for a small company it is usually in abridged form (art. 2435-bis c.c.) and prepared under the OIC principles.
- Thresholds, deadlines and the form that applies are the commercialista's call; don't state them as facts without the commercialista's confirmation.

## What to return

```
VERDICT: OK | CHANGES | STOP

FIGURES
<the statement in the layout above with comparisons, key metrics; each figure's source file, preparer and date>

FINDINGS
1. [high|medium|low] <line and variance> — <driver, or "unexplained"> — <action: monitor / ask commercialista / CEO decision>
...

NOT CHECKED
<statements missing, period-end entries likely not booked, items only the commercialista can confirm>
```

STOP only when the statements show something the CEO must see before committing money (cash below the buffer, a large unexplained payable, equity eroded). Offer to drill into any single variance with `variance-analysis`.
