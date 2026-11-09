# Pricing method

> Adapted from anthropics/knowledge-work-plugins `small-business/skills/proposal-builder` at commit e050c2e (Apache-2.0). Modified for juvant-os: comparables from past proposals, the receivables export and `memory/`; rules from `roles/finance.md` and `memory/knowledge/product.md`; Italian terms (IVA, payment terms); outcomes proposed for `memory/decisions/`; Morvento examples.

Price from what this company has actually charged and from its own rules. Not
from a general estimate, not from an industry average, never from a
plausible-sounding number.

The CEO can check a price in ten seconds if they can see what it's based on. They
can't check a number from nowhere, so they rebuild it, which is the work this
skill was supposed to remove.

---

## The method

**1. Read the rules.**

- `roles/finance.md`: pricing floor (Morvento: € 650 per person-day minimum),
  discount rule (over 15% needs the CEO), payment terms offered (30 days from
  invoice; 60 days end of month at most)
- `memory/knowledge/product.md`: list prices (Morvento Assist: € 49 per user per
  month; setup project from € 3.000)

**2. Find comparable jobs.**

- past proposals in `drafts/` or the SharePoint location in `memory/map.md`
- the receivables export: what was actually invoiced to similar clients (amounts
  only; the line detail comes from the proposal)
- outcomes recorded in `memory/decisions/`
- a rate card the CEO uploads

A good comparable matches on type of work, rough size and client type. Two or
three is plenty; one is thin but usable if close.

**3. Build from the comparable, adjust for difference. Show the arithmetic.**

```
Comparable: Libreria Fontana, setup Jun 2026: 5 days, € 3.250 + IVA
            (€ 650/day), 8 users.

This job:   Ottica Lenzi, 12 users, plus the web chat channel.
            Setup: 5 days as Fontana + 2 days for the web chat = 7 days
            7 × € 650 = € 4.550 + IVA
            Licences: 12 users × € 49 = € 588/month + IVA
```

The CEO agrees or adjusts one number. That's the point.

**4. Check against the rules.**

- Below the floor? Price at the floor and flag it.
- A discount? State it as a separate line and its percentage; over the rule's
  limit, flag it as the CEO's decision.
- More than about 15% away from the list price or the comparables? Say which you
  used and why. A silent discrepancy is how a company ends up with two prices in
  the market.

---

## When there is no comparable

Don't invent one. Leave a placeholder, say what's needed, build the rest:

```
Line 3: Integration with their e-commerce platform: € ______ + IVA

No comparable integration in our history and no rule for it. Everything
else is priced. Give me the number of days (or the team's estimate) and the
proposal is done.
```

---

## What must never be invented

| Never invent | Why |
|---|---|
| A day rate | It's the company's core economics; the floor is in `roles/finance.md` |
| A number of days | It's a promise about the team's time; the team estimates it |
| A delivery date | The manifesto: no date goes out before the people doing the work have checked it |
| A third party's price (hosting, licences, a subcontractor) | Not ours to give |
| A discount | Always the CEO's call |
| A quantity from a screenshot | Volumes on one screen aren't volumes over time |

---

## Structuring the price

**Break it into lines the client recognises as decisions.** A single number
invites a single objection; four lines invite a conversation about scope.

```
Good:
  Setup and configuration (7 days)          € 4.550
  Web chat channel                           included in setup
  Training for the team (half day)            € 325
  Licences: 12 users × € 49/month             € 588/month
                                             --------
  One-off total                             € 4.875 + IVA
  Monthly                                     € 588 + IVA

Bad:
  Project                                   € 4.875
```

The good version lets the client drop the training or start with fewer users.
The bad version only lets them say "too expensive".

Always state VAT treatment (net of VAT, "+ IVA", for B2B). Recurring and one-off
amounts are never added together into one total.

---

## Options, when they help

Two or three tiers work when the budget is unclear. More than three is paralysis.
Name the recommended option and why, in one line. Never offer an option the
company wouldn't want to deliver.

---

## Terms

Take them from `roles/finance.md` and past proposals, not from scratch. If none
exist, use conservative defaults and flag them:

- Payment: as `roles/finance.md` says (Morvento: 30 days from invoice); never
  beyond the maximum it allows
- Advance: for projects, a share on acceptance (e.g. 30 to 50%), as the CEO
  usually does
- Validity: 30 days
- Changes: written approval before the work proceeds
- Prices net of VAT

**Flag terms weaker than usual.** If the usual advance is 50% and this proposal
says 30%, say it before it goes to the client.

---

## Recording the outcome

When the CEO says what happened (won, lost, no answer), propose an entry for
`memory/decisions/` with the final price and the reason if known:

```
Proposed entry: 2026-11-20, Ottica Lenzi: lost. € 4.875 + IVA setup.
They chose a competitor at about € 3.500 with no approval step.
```

Won proposals become tomorrow's comparables; lost ones sharpen the next quote.
Write it only on a yes.
