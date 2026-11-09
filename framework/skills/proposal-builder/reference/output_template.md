# Output template

> Adapted from anthropics/knowledge-work-plugins `small-business/skills/proposal-builder` at commit e050c2e (Apache-2.0). Modified for juvant-os: the review closes with the reviews needed and the CEO sending it themselves (no DocuSign question); euro and VAT; Morvento examples.

The CEO checks two things before sending: the price and the scope. Structure the
review around that.

---

## Structure

```
## Proposal: <client>, <job in four words>

**<total + IVA>** · <one line on how it was priced>

Based on: <comparables and rules used, with dates and amounts>

### Open assumptions
- <assumption>: <what happens if it's wrong, in euro>

### Worth knowing before you send
- <risk, plainly>

### Reviews needed
- <legal / finance / ethics, and why> (or "none")

Draft: drafts/proposal-<client>-<date>.md (+ .docx / .pdf if produced)

<What the CEO does next, in one line.>
```

Everything above the draft line is for the CEO alone. The client never sees it.

---

## Worked example

```
## Proposal: Ottica Lenzi, assistant for 4 shops

**€ 4.875 + IVA one-off, € 588 + IVA per month** · Setup priced from the
Libreria Fontana job plus 2 days for web chat; licences at list price.

Based on: Libreria Fontana, Jun 2026: 5 days setup, € 3.250 + IVA
          (€ 650/day, our floor). List price € 49/user/month
          (memory/knowledge/product.md).

### Open assumptions
- Their e-commerce plan includes API access. If not, the integration line
  is void and they pay for the upgrade; stated in the proposal.
- 12 users. Each extra user is € 49/month; stated.

### Worth knowing before you send
- On the call Marta said "we spent about 3.000 on the website". € 4.875
  will feel high; the one-page summary should say plainly what the
  setup includes.
- 7 days is my estimate from Fontana plus the chat. The manifesto says no
  date goes out before the team checks it: ask Marco to confirm the days
  and the start date.
- They asked for auto-replies "for everything". The product facts say the
  team approves each answer unless auto-replies are enabled for simple
  questions. I scoped approvals-first and put auto-replies under "not
  included unless requested in writing".

### Reviews needed
- Legal: yes. The one-off is under € 10.000, but setup plus 12 months of
  licences is about € 11.900 + IVA, over the manifesto's € 10.000 line.
  The work also touches their customers' messages, so a DPA is needed.

Draft: drafts/proposal-ottica-lenzi-2026-11-09.md

Review it, get Marco's confirmation on the days, and send it from Outlook
when you're happy. I can draft the cover email.
```

The third risk bullet is what protects the company: it came from comparing the
transcript with the product facts, not from the pricing.

---

## When a price line is open

Show the proposal as complete except for the gap, and make the ask trivial:

```
## Proposal: Studio Varenna, integration with their CRM

**€ 3.900 + IVA + integration line** · Everything priced except one line.

Line 4: CRM integration: € ______ + IVA

No comparable integration and no rule for it. Give me the team's estimate in
days and this is ready.
```

---

## For an RFP response

Compliance leads:

```
## RFP response: Consorzio Commercianti, customer service assistant

**€ 17.640 + IVA per year, plus € 4.550 + IVA setup** · 3-year term; licences
at list price for 30 users, setup at our day rate (7 days).

### Compliance check
✓ Data processed in the EU: yes (product facts)
✓ 3 references from retail clients
⚠ They require 99,9% availability with penalties. Our product facts don't state
  an availability figure. Needs the team and legal before we answer.

Due 28/11, 12:00, by PEC. Page limit 15; we're at 11.

### Worth knowing before you send
- Penalties of € 200 per day of unavailability, uncapped. That's the main
  reason to walk if we can't cap it.

### Reviews needed
- Legal: value over € 10.000, penalties, their contract terms.
```

---

## Rules

**Lead with the number.**

**Always show the comparables and the rules used.**

**Keep the risk section honest and separate.** It never appears in the client
document.

**One closing line**: what the CEO does next. The CEO sends; this skill never does.
