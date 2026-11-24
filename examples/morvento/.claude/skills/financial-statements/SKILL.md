---
name: financial-statements
description: "Read and explain the financial statements the external accountant prepares: periodic interim statements, the trial balance and the annual accounts (income statement, balance sheet, cash flow). Use to compare periods, flag material variances, explain what the numbers mean for the CEO, or prepare questions for the accountant. Not for producing the books."
argument-hint: "<monthly|quarterly|annual|ytd> <period>"
allowed-tools: Read, Grep, Glob
---

> Adapted from anthropics/knowledge-work-plugins `finance/skills/financial-statements` at commit e050c2e (Apache-2.0). Modified for juvant-os: reads and explains statements the external accountant prepares instead of generating them; US GAAP/ASC replaced by the statutory layout and accounting standards of the company's country; output fits the finance agent's shape; country-neutral; local rules from the country pack.

# Financial statements

**Important**: this skill assists in reading financial statements but does not provide financial advice. The statements are prepared by the external accountant, who is responsible for them; this skill explains them, compares periods and prepares questions. Anything used for filings, financing or tax decisions stays with the accountant.

**Local rules.** If `.claude/country/finance.md` or `country/finance.md` exists, apply its checks and use its terms: the statutory layouts and their line numbering, the accounting standards, the names of the accountant's documents, payroll and tax lines, period-end entries, and the filing basics. If neither exists, say which points depend on local law or practice and list them under NOT CHECKED ("to check with the accountant").

## Usage

```
financial-statements <period-type> <period>
```

- `period-type`:
  - `monthly`: a monthly interim statement, compared with the prior month and the same month last year
  - `quarterly`: a quarter, compared with the prior quarter and the same quarter last year
  - `annual`: the year's statutory accounts, compared with the prior year
  - `ytd`: year to date, compared with the prior year's same period
- `period`: e.g. `2026-10`, `2026-Q3`, `2025`

## Workflow

### 1. Gather the statements

Read before asking:

- `roles/finance.md`: the company's rules and the external accountant's name.
- `memory/map.md`: where the accountant's files live (SharePoint/OneDrive folder, mail attachments).
- The statements for the period and the comparison periods: interim statement or trial balance, and for the year the annual accounts with their notes. Read them through the Microsoft 365 connector (SharePoint/OneDrive files, or attachments in Outlook) or from files the CEO provides.
- A budget or plan, if one exists (`memory/decisions/`).

If something is missing, ask the CEO for that file specifically, by its local name and preparer (e.g. "the September interim statement from the accountant"), not for "the numbers". Never reconstruct a statement from bank movements and present it as the accountant's: if you build an indicative view from cash, label it clearly as such.

Note what the statement is: interim statements usually lack period-end entries (depreciation, accruals and deferrals, severance and other payroll accruals, provision for doubtful receivables, taxes), so profit in a monthly interim statement is normally overstated relative to year end. Say so whenever you compare an interim period with a full year.

### 2. Present the income statement

Present the accountant's figures in the statutory layout the country uses (the country pack gives it, with its line numbering), with comparisons. Without a country pack, use a by-nature layout like this one:

```
INCOME STATEMENT
Period: [description]          Source: [file, prepared by, date]
(EUR, or the company's currency)

                                         Current   Prior    Var EUR   Var %   Budget   Bud var
OPERATING REVENUE
   Revenue from sales and services
   Other revenue and income
   Total revenue
OPERATING COSTS
   Raw materials and goods
   Services
   Use of third-party assets (rent, leases)
   Personnel (wages, social contributions, statutory payroll accruals, other)
   Depreciation, amortisation and write-downs
   Other operating costs
   Total costs
OPERATING RESULT (revenue - costs)
FINANCIAL INCOME AND CHARGES
VALUE ADJUSTMENTS OF FINANCIAL ASSETS
RESULT BEFORE TAXES
   Income taxes
NET RESULT FOR THE PERIOD
```

Show only the lines the statement contains. If the accountant's interim report uses a management layout instead (revenue, direct costs, gross margin, overheads), follow it and say so.

Useful management views on top, computed from the statement and labelled as your computation:

- **Gross margin** for a services company: revenue minus direct costs (services bought for delivery, freelancers, delivery staff if separable).
- **EBITDA**: operating result before depreciation, amortisation and write-downs.
- **Personnel cost as % of revenue**, **services as % of revenue**.

### 3. Variance analysis

For each line:

- **Amount variance**: current − comparison.
- **Percentage variance**: (current − comparison) / |comparison| × 100.
- **Point change** for margins and ratios.

#### Materiality

Agree thresholds with the CEO and propose recording them in `roles/finance.md`. Starting points for a small company (e.g. in EUR):

| Line size (annual) | Amount threshold | Percentage threshold |
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
- **Booking effects**: a reclassification or a period-end entry by the accountant, not a business change.

#### Explanation

For each material variance:
1. Quantify (amount and %).
2. Favourable or unfavourable.
3. Decompose into drivers.
4. Give the business reason, if known from the data or `memory/`; otherwise write it as a question.
5. Say whether it is temporary or a trend.
6. Note the action (none, monitor, ask the accountant, ask the CEO).

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

| Line | Variance (amount) | Variance (%) | Direction | Likely driver | Action |
|---|---|---|---|---|---|
| | | | Unfav. | | Ask the accountant |

### 6. Questions for the accountant

Write the questions the statements raise, each tied to a line and an amount: entries that look misclassified, period-end entries not yet booked, receivables that look doubtful, differences from the company's own receivables/payables lists. These go into the monthly packet (`month-end-prep`) or into a draft email to the accountant (Outlook draft, or `drafts/<name>.md`) for the CEO to send.

## Reading the balance sheet

Use the statutory layout the country pack gives. Without one, the usual sections are:

```
ASSETS
Fixed assets: intangible (software, development costs, trademarks),
              tangible (equipment, furniture, hardware),
              financial (shareholdings, long-term receivables)
Current assets: inventory (incl. work in progress on orders),
                receivables (trade, tax receivables such as VAT credit, other;
                  separately when due beyond 12 months),
                current financial assets,
                cash and bank
Accrued income and prepaid expenses

LIABILITIES AND EQUITY
Equity (share capital, reserves, retained earnings, result for the year)
Provisions for risks and charges
Employee benefit / severance liabilities, where the country has them
Payables (bank loans, trade, tax, social security, other;
  separately when due beyond 12 months)
Accrued expenses and deferred income
```

What to look at for a small company:

- **Cash** against the minimum buffer in `roles/finance.md`.
- **Trade receivables** against the company's receivables list; a gap is a reconciliation item. Check whether a provision for doubtful receivables exists for old items.
- **Tax and social-security payables**: VAT, withholdings and contributions due with the next tax payment.
- **Employee severance or benefit liabilities**, where the country has them: a real liability that grows every month and is paid when people leave.
- **Deferred income**: annual licences invoiced in advance; revenue not yet earned.
- **Equity**: losses that erode share capital beyond statutory thresholds can trigger obligations for the directors in many countries; if equity looks low against share capital, raise it with the accountant and counsel without stating the legal consequences yourself.

## Reading the cash flow statement

Whether a cash flow statement is required depends on the country and the company's size (the country pack says); it may not exist. If it does, it usually uses the indirect method:

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

If there is none, a simple view from two balance sheets and the income statement (result + depreciation ± change in receivables, payables and severance liabilities) is a reasonable indication; label it as your computation.

## Common period-end entries to expect

Interim statements often lack these; the annual accounts include them. Use the list to explain why year-end profit differs from interim figures, and to ask the accountant whether they've been booked (the country pack adds local items):

1. **Accruals and deferrals**: costs and revenue split across periods (insurance, annual licences sold or bought).
2. **Depreciation and amortisation** of fixed assets.
3. **Severance or employee-benefit accruals** for the period, where the country has them.
4. **Extra monthly salary accruals**, where the country or collective agreement provides them.
5. **Provision for doubtful receivables** based on ageing.
6. **Invoices to issue or receive** for work done or received in the period.
7. **Taxes**: income taxes for the year.
8. **Work in progress** on orders spanning year end.

## Statutory basics, for context only

- The annual accounts are usually approved by the shareholders and filed with a public register; small companies often file an abridged form. The country pack gives the local rules.
- Thresholds, deadlines and the form that applies are the accountant's call; don't state them as facts without the accountant's confirmation.

## What to return

```
VERDICT: OK | CHANGES | STOP

FIGURES
<the statement in the layout above with comparisons, key metrics; each figure's source file, preparer and date>

FINDINGS
1. [high|medium|low] <line and variance> — <driver, or "unexplained"> — <action: monitor / ask the accountant / CEO decision>
...

NOT CHECKED
<statements missing, period-end entries likely not booked, items only the accountant can confirm, points that depend on local rules if no country pack>
```

STOP only when the statements show something the CEO must see before committing money (cash below the buffer, a large unexplained payable, equity eroded). Offer to drill into any single variance with `variance-analysis`.
