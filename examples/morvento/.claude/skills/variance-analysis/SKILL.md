---
name: variance-analysis
description: "Break a financial variance into its drivers and explain it in plain words. Use when comparing actuals to budget or to a prior period, explaining why revenue, costs, margin or cash moved, or preparing variance commentary for the CEO."
argument-hint: "<line item> <period> vs <comparison>"
allowed-tools: Read, Grep, Glob
---

> Adapted from anthropics/knowledge-work-plugins `finance/skills/variance-analysis` at commit e050c2e (Apache-2.0). Modified for juvant-os: scaled to a small company, figures come from the external accountant's statements and CEO-provided exports, and the output fits the finance agent's VERDICT / FIGURES / FINDINGS / NOT CHECKED shape; country-neutral; local rules from the country pack.

# Variance Analysis

**Important**: this skill assists with variance analysis but does not provide financial advice. Analyses that feed reporting, financing or tax decisions should be reviewed by the external accountant or another qualified professional before use.

Techniques for decomposing variances, setting materiality, writing variance explanations and building a bridge from one figure to another. Amounts are in the company's currency (examples use EUR).

**Local rules.** If `.claude/country/finance.md` or `country/finance.md` exists, apply its checks and use its terms (the accountant's statement names, payroll cost items, seasonality). If neither exists, say which points depend on local law or practice and list them under NOT CHECKED ("to check with the accountant").

## Where the numbers come from

Read before asking:

- `roles/finance.md`: the company's rules (payment terms, cash buffer, pricing floor, spending approval) and the data sources it lists.
- The external accountant's periodic statements (monthly or quarterly interim statement, trial balance, annual accounts), as files the CEO provides or stored on SharePoint/OneDrive (see `memory/map.md` for where).
- A budget or plan, if one exists: look in `memory/decisions/` and `memory/map.md`. Many small companies have no formal budget; then compare to the prior period and the same period last year, and say so.
- Bank exports and e-invoicing exports (if the country has an e-invoicing system) the CEO provides; the receivables list named in the role card.

Never invent a figure. If a comparison basis is missing, say which one and compare on what you have.

## Variance decomposition techniques

### Price / volume

The basic decomposition, for revenue and any cost that can be written as price × volume. For a services company, "volume" is usually person-days or licences and "price" the day rate or licence fee.

```
Total variance = Actual - Budget (or Prior)

Volume effect  = (Actual volume - Budget volume) x Budget price
Price effect   = (Actual price - Budget price) x Actual volume
Mix effect     = residual (interaction term), or allocated proportionally

Check: Volume effect + Price effect = Total variance
       (when mix is embedded in the price/volume terms)
```

Three-way decomposition (separating mix):

```
Volume effect = (Actual volume - Budget volume) x Budget price x Budget mix
Price effect  = (Actual price - Budget price) x Budget volume x Actual mix
Mix effect    = Budget price x Budget volume x (Actual mix - Budget mix)
```

**Example: services revenue**
- Budget: 200 person-days at EUR 700 = EUR 140,000
- Actual: 220 person-days at EUR 660 = EUR 145,200
- Total variance: +EUR 5,200 favourable
  - Volume effect: +20 days × EUR 700 = +EUR 14,000 (more days sold)
  - Price effect: −EUR 40 × 220 days = −EUR 8,800 (lower average day rate)
  - Net: +EUR 5,200

When the price effect comes from discounting, check it against the pricing floor and discount rule in `roles/finance.md` (for example, a day rate under the floor or a discount above the threshold the CEO must approve) and raise it as a finding.

### Rate / mix

For blended rates across segments with different economics (e.g. licences vs custom projects).

```
Rate effect = Sum of (Actual volume_i x (Actual rate_i - Budget rate_i))
Mix effect  = Sum of (Budget rate_i x (Actual volume_i - Expected volume_i at budget mix))
```

**Example: gross margin**
- Licences: 80% margin; custom projects: 40% margin
- Budget mix 50/50 → blended 60%
- Actual mix 40/60 → blended 56%
- Mix explains 4 points of margin compression.

### Personnel cost

For people-cost variances. Personnel cost is gross salary plus employer social contributions plus any statutory items the country requires (severance accruals, extra monthly salaries accrued across the year); the country pack lists them. The payroll figures come from the external accountant or payroll provider; use totals only, never per-person pay.

```
Total personnel variance = Actual personnel cost - Budget personnel cost

Decompose into:
1. Headcount variance  = (Actual HC - Budget HC) x Budget average cost
2. Rate variance       = (Actual average cost - Budget average cost) x Budget HC
3. Mix variance        = shift between levels or contract types
4. Timing variance     = hiring earlier or later than planned (partial-period effect)
5. Accrual timing      = extra monthly salaries or bonuses booked in one month instead of spread
6. Departures          = savings from unplanned leavers, partly offset by backfill and any severance paid out
```

### Spend category

For operating costs where price × volume does not apply.

```
Total opex variance = Actual opex - Budget opex

Decompose by:
1. People-driven costs     (salaries, contributions, recruiting, training)
2. Volume-driven costs     (hosting, transaction fees, commissions)
3. Discretionary spend     (travel, events, consultants, marketing)
4. Contractual/fixed costs (rent, insurance, software subscriptions)
5. One-off                 (legal fees, write-offs, project costs)
6. Timing / phasing        (spend shifted between periods vs plan)
```

## Materiality thresholds and investigation triggers

### Setting thresholds

Materiality decides which variances need an explanation. Base it on:

1. **Size of the company**: for a company with a few hundred thousand of annual revenue, a fixed threshold of e.g. EUR 1,000–2,500 per line per month is usually a sensible starting point; agree it with the CEO and propose recording it in `roles/finance.md` if it is not there.
2. **Line size**: larger lines warrant a lower percentage threshold.
3. **Volatility**: noisy lines may need a higher threshold to avoid chasing noise.
4. **Decision relevance**: what size of variance would change a decision? Anything that touches the cash buffer or the spending approval limit in the role card is material regardless of percentage.

### Recommended threshold framework

| Comparison | Amount threshold | Percentage threshold | Trigger |
|---|---|---|---|
| Actual vs budget | company-specific | 10% | either exceeded |
| Actual vs prior period | company-specific | 15% | either exceeded |
| Actual vs forecast | company-specific | 5% | either exceeded |
| Sequential (month on month) | company-specific | 20% | either exceeded |

### Investigation priority

When several variances exceed thresholds, look at them in this order:

1. **Largest absolute amount variance**: biggest impact on profit or cash.
2. **Largest percentage variance**: may point to an error or a process problem.
3. **Unexpected direction**: opposite to trend or expectation.
4. **New variance**: a line that was on track and now is not.
5. **Cumulative or growing variance**: getting bigger each period.

## Writing variance explanations

### Structure for each explanation

```
[Line item]: [favourable/unfavourable] variance of [currency] [amount] ([percentage]%)
vs [comparison basis] for [period]

Driver: [primary driver]
[2-3 sentences explaining the business reason, with each contributing factor quantified]

Outlook: [one-off / expected to continue / improving / deteriorating]
Action: [none / monitor / ask the accountant / ask the CEO / update forecast]
```

### Quality checklist

- [ ] **Specific**: names the actual driver, not "higher than expected".
- [ ] **Quantified**: amount and percentage impact of each driver.
- [ ] **Causal**: explains why, not only what.
- [ ] **Forward-looking**: says whether it will continue.
- [ ] **Actionable**: names the follow-up or decision.
- [ ] **Concise**: 2–4 sentences.

### Anti-patterns

- "Revenue was higher than budget due to higher revenue" (circular).
- "Costs were elevated this period" (which costs? why?).
- "Timing" without saying what moved, from when to when.
- "One-off" without saying what the item was.
- "Various small items" for a material variance (decompose further).
- Explaining only the largest driver and ignoring offsetting items.
- Reading an accounting entry (an accrual, a reclassification by the accountant) as a business change. If a movement looks like a booking rather than an event, ask the accountant before explaining it.

## Bridge (waterfall) method

A bridge shows how you get from one value to another through positive and negative contributors.

### Data structure

```
Starting value: [budget / prior period amount]
Drivers:        [contributing factors with signed amounts]
Ending value:   [actual / current period amount]

Check:          Starting value + sum of drivers = Ending value
```

### Text bridge

```
BRIDGE: Revenue, Q3 actual vs Q3 prior year

Q3 prior year revenue                              EUR 118,000
  |
  |--[+] New clients                                +EUR 14,500
  |--[+] More days on existing clients              +EUR 6,200
  |--[-] Lower average day rate                     -EUR 4,400
  |--[-] Client lost (contract not renewed)         -EUR 9,000
  |--[-] Timing (milestone invoiced in October)     -EUR 3,000
  |
Q3 actual revenue                                  EUR 122,300

Net variance: +EUR 4,300 (+3.6% favourable)
```

### Bridge reconciliation table

| Driver | Amount | % of variance | Cumulative |
|---|---|---|---|
| New clients | +EUR 14,500 | 337% | +EUR 14,500 |
| More days on existing clients | +EUR 6,200 | 144% | +EUR 20,700 |
| Lower average day rate | −EUR 4,400 | −102% | +EUR 16,300 |
| Client lost | −EUR 9,000 | −209% | +EUR 7,300 |
| Timing | −EUR 3,000 | −70% | +EUR 4,300 |
| **Total variance** | **+EUR 4,300** | **100%** | |

Percentages can exceed 100% for single drivers when there are offsetting items.

### Bridge practice

1. Order drivers from largest positive to largest negative, or in a logical business sequence.
2. Keep to 5–8 drivers; group the small ones into "Other".
3. Check that the bridge ties (start + drivers = end).
4. Label each step with the amount and a short description.
5. End with the total variance.

## Budget vs actual vs forecast

### Three-way comparison

| Line | Budget | Forecast | Actual | Bud var (EUR) | Bud var (%) | Fcst var (EUR) | Fcst var (%) |
|---|---|---|---|---|---|---|---|
| Revenue | | | | | | | |
| Direct costs | | | | | | | |
| Gross margin | | | | | | | |

### When to use each comparison

- **Actual vs budget**: yearly performance against the plan set at the start of the year.
- **Actual vs forecast**: running management, spotting emerging problems.
- **Forecast vs budget**: how expectations have moved since planning.
- **Actual vs prior period**: trend; the default when there is no budget.
- **Actual vs same period last year**: growth with seasonality removed (holiday months are often unrepresentative; the country pack names them).

### Forecast accuracy

```
Forecast accuracy = 1 - |Actual - Forecast| / |Actual|
MAPE = average of |Actual - Forecast| / |Actual| across periods
```

| Period | Forecast | Actual | Variance | Accuracy |
|---|---|---|---|---|
| Jan | | | | |
| Feb | | | | |
| **Avg** | | | **MAPE** | |

### Variance trending

- **Consistently favourable**: the budget may be too cautious.
- **Consistently unfavourable**: the budget may be too ambitious, or there is an execution problem.
- **Growing unfavourable**: worsening performance or unrealistic targets.
- **Shrinking**: forecasts getting more accurate through the year (normal).
- **Volatile**: unpredictable business or weak forecasting method.

## What to return

When the finance agent uses this skill, fit the result to its shape:

```
VERDICT: OK | CHANGES | STOP

FIGURES
<the comparison table or bridge, each figure with its source: file, period, who prepared it>

FINDINGS
1. [high|medium|low] <line item and variance> — <driver and why it matters> — <what you propose>
...

NOT CHECKED
<missing comparison basis, periods not covered, bookings to confirm with the accountant; points that depend on local rules if no country pack>
```

Use STOP only when a variance means money should not be committed before the CEO has seen it (for example, the cash buffer in the role card is at risk). If a durable fact emerges (a materiality threshold the CEO agreed, a recurring seasonal pattern), propose adding it to `memory/knowledge/finance.md` or `roles/finance.md`; don't store it yourself.
