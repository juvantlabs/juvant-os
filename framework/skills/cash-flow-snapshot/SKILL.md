---
name: cash-flow-snapshot
description: "Build a 30/60/90-day cash forecast from the bank balance, the receivables and payables lists and the known fixed costs and tax dates, with confidence bands and named risks, checked against the cash buffer in the finance role card. Use when the CEO asks about cash, runway, whether salaries and tax payments are covered, or a cash crunch."
allowed-tools: Read, Grep, Glob
---

> Adapted from anthropics/knowledge-work-plugins `small-business/skills/cash-flow-snapshot` at commit e050c2e (Apache-2.0). Modified for juvant-os: data comes from the receivables list, CEO-provided bank and e-invoicing exports and the role card instead of ledger/payment-processor connectors; recurring salary and tax outflows added; band applied to inflows; XLSX, artifact, scheduling and connector-building dropped; output fits the finance agent's shape; country-neutral; local rules from the country pack.

# Cash Flow Snapshot

Produces a 30/60/90-day cash forecast with confidence bands and named risks, and checks it against the company's minimum cash buffer.

**Quick start**

> "Are we fine on cash until February?"

Take the opening bank balance, the open receivables, the payables and the fixed costs and tax dates, place each in its window using each client's payment history, apply confidence bands, compare closing cash with the buffer in `roles/finance.md`, and name the risks.

This skill reads only. It never pays, moves money or writes to the bank or invoicing system.

**Local rules.** If `.claude/country/finance.md` or `country/finance.md` exists, apply its checks and use its terms: the tax and social-contribution calendar, extra monthly salaries, income-tax advances, withholding taxes, bank export column names. If neither exists, say which points depend on local law or practice and list them under NOT CHECKED ("to check with the accountant").

---

## Workflow

### Step 1 — Gather the sources

Read first, ask only for what's missing:

1. `roles/finance.md`: minimum cash buffer, payment terms, late-payer steps, recurring obligations (tax payment dates, etc.), data sources.
2. **Receivables list** named in the role card (e.g. `samples/finance/receivables.csv`): invoice, client, issued, due, amount, paid_on.
3. **Payables**: the payables list if the company keeps one, otherwise received invoices from the e-invoicing export (if the country has an e-invoicing system) the CEO provides, with due dates.
4. **Bank**: a recent statement or balance export the CEO provides (read-only; never credentials). `memory/map.md` says where finance files live on SharePoint/OneDrive.
5. **Fixed costs and tax amounts**: salaries (net pay date and amount), periodic tax and social-contribution payments (VAT, withholdings, contributions), rent, subscriptions, loan instalments. Tax amounts and tax advances come from the external accountant; ask the CEO for the latest figures or look for the accountant's email through the Microsoft 365 connector.
6. **Invoicing plan**, if the CEO has one: work to be invoiced in the coming months. Without it, the forecast covers only invoices already issued; say so prominently, because for a services company that makes later windows look worse than they are.

Use all available sources together. Note which ones were used: it sets the band width and goes in the output.

**Always establish the opening cash balance.** "Will we make salaries" is a question about the balance, not the net. Take it from the bank export with its date, or ask the CEO: "What's in the business account now, and as of what date?" **Never assume one.** If nobody can supply it, head the output "no opening balance — net change only" and drop the buffer check and cash-on-hand risks.

### Step 2 — Prepare the data

**Receivables:**
- Keep only open invoices (no `paid_on`). Check a recent bank export for receipts not yet marked paid in the list; a receipt in the bank means the invoice is not an inflow any more (see `reference/gotchas.md`).
- Watch for amounts paid net of withholding tax by clients required to withhold (the country pack says when); the inflow is the net amount.

**Payables:** supplier, amount, due date. Received invoices with no due date: assume the supplier's usual terms and say so.

**Fixed costs and tax dates**, each with date and amount (the country pack gives the local calendar):
- Periodic tax and social-contribution payments: VAT settlements, withholdings on salaries and fees, social contributions.
- Net salaries, on the company's pay date.
- Extra monthly salaries where the country or collective agreement provides them.
- Income-tax balance and advances, on their statutory dates. Amounts and exact dates from the accountant.
- Annual items: insurance, VAT annual balance, registry or chamber fees, software renewals.
- Rent, leases, loan instalments, recurring subscriptions.

**CSV or spreadsheet files:** match column names loosely (date / value date / booking date; amount, or credit − debit; the country pack lists local column names). If the mapping is ambiguous, show the header row and ask the CEO to confirm before computing.

### Step 3 — Compute payment timing

For each client, from paid invoices in the receivables list (and bank history if available):
- **Mean delay**: average days between due date and receipt (negative = early).
- **Variance**: standard deviation of the delay over the last 6–12 payments.

If a client has fewer than 3 payments on record, use the average delay across all clients as the point estimate and a default ±30% band. With 3 or more payments, compute the band from actual variance; don't assume ±30%.

**Invoices already deep in the late-payer steps** (past the CEO-call threshold in `roles/finance.md`, e.g. 45 days): don't count them as expected inflows. Show them as upside ("+EUR X if paid") and as a risk. Expecting money that is already in the escalation path is the most common reason a forecast is quietly optimistic.

### Step 4 — Build the 30/60/90-day forecast

Three windows from today: 0–30, 31–60, 61–90 days.

| Line | Method |
|---|---|
| Expected inflows | Open receivables due in the window, shifted by the client's mean delay; plus planned invoices if the CEO gave a plan (marked as planned) |
| Expected outflows | Payables due in the window + fixed costs and tax payments falling in the window |
| Net | Inflows − outflows |
| Closing cash | Opening balance + cumulative net |
| Band | Applied to inflows (outflows are mostly fixed): low = inflows × (1 − band) − outflows; high = inflows × (1 + band) − outflows |
| Buffer check | Closing cash (expected and low) vs the minimum buffer in the role card |

Band:
```
band_pct = weighted_avg_stddev_days / avg_payment_term_days
```
Weight by invoice amount. Round to one decimal place; cap at ±50%. Above that, the data is too thin to model: say so instead of forecasting (Step 5). Planned (not yet issued) invoices get at least ±30%.

### Step 5 — Name the risks

Look for conditions that push low-band cash below the buffer or below zero, and write each as one line, with the client or obligation named:

- **Buffer breach:** "Closing cash falls to EUR 63,100 by 8 January, below the EUR 90,000 buffer in the role card (low band: EUR 53,800)."
- **Salary or tax-payment crunch:** "Salaries (EUR 16,500) and the 13th month (EUR 14,000) go out on 27 December; low-band cash that day is EUR X." Needs a sourced balance.
- **Late payer:** "Studio Varenna has EUR 7,320 open, the oldest 46 days late; not counted as an inflow."
- **Concentration:** one client making up most of the inflows in a window.
- **Thin data:** "Only one payment on record for Ottica Brenta: default ±30% band."
- **Missing source:** "No payables list or received-invoices export: supplier payments not included; outflows are understated."

Top 5 by amount impact.

### Step 6 — Return the result

Use markdown tables, amounts with the currency code (`EUR 4,880`), never a bare symbol. Fit the finance agent's shape:

```
VERDICT: OK | CHANGES | STOP

FIGURES
Cash Flow Snapshot — <date range>
Sources: <files and exports used, with as-of dates>
Opening balance: EUR X as of <date>   (or: none on file — net change only)
Minimum buffer (roles/finance.md): EUR X

| Window | Inflows | Outflows | Net | Closing cash | Low | High |
|---|---|---|---|---|---|---|
| 0–30 days | | | | | | |
| 31–60 days | | | | | | |
| 61–90 days | | | | | | |

Upside not counted: <late invoices in escalation>
Detail: <inflows and outflows per window, dated, each with its source>

FINDINGS
1. [high|medium|low] <risk> — <why it matters> — <what you propose>
...

NOT CHECKED
<sources not available this run and what they would change; figures the accountant should confirm (tax amounts and advances); points that depend on local rules if no country pack>
```

VERDICT: OK when expected and low-band closing cash stay above the buffer; CHANGES when the low band breaches it or a source is missing; STOP when expected cash falls below the buffer or below an upcoming salary or tax payment, so the CEO sees it before committing any new spending.

**Say what is missing.** "Built from: receivables list (to 6 Nov), bank export (6 Nov), fixed costs from the CEO. Not available: payables list — supplier payments are missing from outflows." A CEO who knows what's missing can judge the number; one who doesn't will trust it completely.

If the CEO wants a file, write the same content as markdown where `memory/map.md` says finance working files go.

---

## After the run

One line on the result: the forecast is built and the risks are named. Then offer at most three next steps that fit:

- Late payers found: `invoice-chase` to draft the reminders the role card's steps call for.
- Month just ended: `month-end-prep` to prepare the accountant's packet.
- Buffer breach: a short note for the CEO with the options (pull invoicing forward, defer a spend, talk to the bank); the decision is the CEO's.

Don't repeat an offer the CEO declined this session.

This forecast is an aid, not accounting or financial advice: say which sources it rests on, and that financing decisions should be checked with the accountant.

## Reference files

| File | Load when |
|---|---|
| `reference/gotchas.md` | Data looks odd, variance is extreme, or before the first run on a new data shape |
| `reference/examples/worked-example.md` | To model the output for a new data shape |
