# Handoffs

> Adapted from anthropics/knowledge-work-plugins `small-business/skills/inbox-manager` at commit e050c2e (Apache-2.0). Modified for juvant-os: routes to the `finance` and `legal` reviewers and the finance skills instead of ap-processor, speed-to-lead and contract-review; bill handling with e-invoicing courtesy copies; Morvento example; country-neutral; local rules from the country pack.

The inbox is where most business events first appear: a bill, a new inquiry, a
contract, a complaint all arrive as email first. That makes this skill the
trigger for the rest of the company's work.

**Every handoff gets a line in the digest.** An item that disappears without a
mention reads as a lost email.

---

## What goes where

| What arrived | Goes to | What happens there |
|---|---|---|
| Supplier invoice, bill, payment reminder | Needs-you, flagged for the `finance` reviewer | Checked against `roles/finance.md` (approval threshold, recurring costs); goes in the external accountant's monthly packet; the CEO pays it from the bank |
| Customer replying about an overdue invoice | `invoice-chase` skill | Owns the reminder thread and any payment arrangement, as drafts |
| Contract, NDA, order form, terms, formal notice | `legal` reviewer | Review against `roles/legal.md`; the CEO decides and signs |
| New inquiry from a prospect | Stays here | First reply drafted; flagged in needs-you if it's a real opportunity; `proposal-builder` if they ask for a quote |
| Meeting request, scheduling thread | Stays here | Reply drafted with times from the calendar, conflicts named; nothing booked |
| Anything touching client data, AI behaviour complaints, or a request that sits badly with the manifesto | `ethics` reviewer, alongside needs-you | A second view before the CEO answers |

Anything else stays here and is triaged normally.

**A routed item is still draft-only.** No reviewer or skill sends, pays, signs or
books. The handoff moves the work, not the authority.

---

## How to spot each one

**A bill, not a receipt.** A bill asks for money that hasn't moved: an invoice
number, a due date, an amount owed, payment details. A receipt confirms money
already moved. Where the country has a national e-invoicing system (the country
pack's `finance.md` says), a supplier's legally valid invoice arrives through it
and a PDF by email is usually a courtesy copy. Treat it as a bill for the due
date, and note that the e-invoicing copy is the one the external accountant
books. Without a country pack, say whether the PDF is the legal invoice was not
checked.

**A real inquiry, not a pitch.** An inquiry describes their own problem and asks
whether the company can help. A pitch describes the sender's product. When
genuinely ambiguous, treat it as an inquiry.

**A scheduling thread, not a date mention.** "Can we do Thursday at 15:00?" is
scheduling. "We finished on Thursday" is not.

**A contract, not a mention of one.** An attachment or a link to terms the CEO
is being asked to accept or sign. A thread that only talks about "the contract"
stays here unless it asks for a change to terms.

---

## What to pass along

Pass the whole thread reference (the Outlook message, with attachments), not a
summary: the receiving reviewer needs the PDF, the sender's address, the history
and the timestamps. Also say what you already know:

- which bucket you'd put it in
- any deadline or amount extracted
- whether anyone at the company already replied

**In pasted mode**, pass the pasted text exactly and say the attachment isn't
there:

```
Cloud hosting invoice → finance. I only have the pasted text, not the PDF,
so the amounts come from what's below; the e-invoicing copy will have the exact
figures.
```

---

## When the receiving skill or reviewer isn't available

Say so by name and keep the item in needs-you with the key facts pulled out.
Never drop it or pretend it was handled.

```
2 supplier invoices came in (e.g. Hosting EU € 1.847 net of VAT, due 30/11;
Studio Grafico Neri € 612 net of VAT, due 15/12). The finance reviewer isn't available in
this session, so I've left them in needs-you.
```

---

## Worked example: Morvento

Giulia's Wednesday triage produced three handoffs:

- **Hosting EU invoice n. 88214, € 1.847 net of VAT, due 30 November** → flagged for
  `finance`. Courtesy PDF attached; it's recurring, so above the approval rule in
  `roles/finance.md`.
- **Studio Varenna: "we'll pay the September invoice next week"** →
  `invoice-chase`, which owns that reminder thread.
- **NDA from a prospect, Ferramenta Bassi** → `legal` reviewer. Their template has
  a 5-year term and a clause choosing the court of Milan; legal compares it with
  `roles/legal.md`.

All three appear in the digest under "routed", one line each.
