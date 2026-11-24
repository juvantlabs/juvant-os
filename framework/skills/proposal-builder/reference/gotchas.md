# Gotchas

> Adapted from anthropics/knowledge-work-plugins `small-business/skills/proposal-builder` at commit e050c2e (Apache-2.0). Modified for juvant-os: photo-quantity case replaced by volume guesses; signature routing replaced by never-send; added overpromising the product, unchecked dates and missing reviews; outcomes proposed for `memory/decisions/`; Morvento examples; country-neutral; local rules from the country pack.

Failure modes that lose money or lose the job. A proposal is a commitment; a
mistake has a price. Examples use Morvento's euro amounts, with "+ VAT" for the
locale's net-of-tax wording.

---

## A quantity guessed from too little

One screenshot of 60 open tickets isn't a weekly volume; "a few shops" isn't
four.

**Bad**
```
About 300 messages a week, based on the screenshot.
```

**Good**
```
Weekly volume not determinable from one screenshot. Either they tell us, or
the offer covers up to 12 users and adjusts if volumes need more.
```

---

## No "not included" section

Scope disputes start with something nobody wrote down.

**Bad**: scope only. The client assumes migration of old messages is included.

**Good**: an explicit list of what a reasonable client might assume is covered
and isn't.

---

## A silent assumption

An assumption the CEO knows about but the client never saw is no protection.

**Bad**: price assuming API access on their plan; mention it only to the CEO.

**Good**: in the client-visible text, with the consequence named.

---

## An invented rate, number of days or date

**Bad**
```
Line 4: CRM integration: € 2.600 + VAT (4 days). Delivery by 15 December.
```
Derived from nothing; a date the team never saw.

**Good**
```
Line 4: CRM integration: € ______ + VAT. Needs the team's estimate.
Timeline: indicative, to be confirmed by the team.
```

---

## Promising more than the product does

The client asks for something the product facts don't support ("fully automatic,
no approval"). Writing it into the scope turns a sales conversation into a
broken promise.

**Bad**: scope says "automatic answers to all customer messages".

**Good**: scope says what the product does per `memory/knowledge/product.md`;
the request goes to the CEO in the risk read, and anything the manifesto rules
out ("replaces your team") never appears.

---

## Redesigning their template

A proposal that doesn't look like the others gets rebuilt by hand. Match the
template exactly; suggest improvements separately, later.

---

## Writing an RFP response they're disqualified from

**Bad**: write the whole response, then mention the certification requirement.

**Good**: go/no-go first.

---

## Mixing the risk read into the client document

**Bad**: soften the risk into the assumptions and say nothing to the CEO.

**Good**: two things. Neutral assumptions in the proposal; a blunt risk read in
chat.

---

## Skipping the reviews

**Bad**: a € 14.000 proposal with the client's terms attached goes to the CEO as
"ready to send".

**Good**: "Reviews needed: legal (value over € 10.000, their terms attached)."
The manifesto's thresholds and `roles/legal.md` decide, not the skill's sense of
urgency.

---

## Sending, or acting as if it was sent

**Bad**: "The proposal is on its way to Marta." Or creating an invoice when the
CEO says "they accepted".

**Good**: the draft is in `drafts/`; the CEO sends it. On acceptance, say what
follows and who does it (order confirmation, first invoice by the CEO or the
external accountant, through the e-invoicing system if the country has one).

---

## Not recording the outcome

**Bad**: move on after the CEO says it was lost.

**Good**: propose the entry for `memory/decisions/`:
```
2026-11-20, Ottica Lenzi: lost at € 4.875 + VAT setup. Competitor at about
€ 3.500, no approval step. Our day rate held; the difference was scope.
```

---

## Terms weaker than usual

**Bad**: 90 days payment because the client asked.

**Good**: `roles/finance.md` says 60 days end of month at most, and the manifesto
says never more than 60 (e.g. Morvento). Price at our terms and flag the request
to the CEO; if the country pack's `legal.md` sets statutory limits on B2B
payment terms, name them.
