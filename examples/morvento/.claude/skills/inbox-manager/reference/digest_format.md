# Digest format

> Adapted from anthropics/knowledge-work-plugins `small-business/skills/inbox-manager` at commit e050c2e (Apache-2.0). Modified for juvant-os: drafts live in Outlook Drafts and the CEO sends them; no send-approval prompt or batch send; no filing; Morvento example; country-neutral; local rules from the country pack.

The digest is the product. Everything else this skill does is upstream of it.

**Target: ninety seconds to read.** If it takes longer, the triage was too loose.

---

## Shape

1. **One-line headline**: how much came in, how much needs the CEO.
2. **Needs you**: ranked by consequence, each with the ask in one line and what
   happens if it waits.
3. **Drafted**: recipient and one-line summary of each reply, grouped where
   similar. Say they're in Outlook Drafts.
4. **Routed**: one line each, naming where it went and what the CEO does next
   (e.g. "→ legal reviewer; ask CoS for the NDA review").
5. **Covered by someone else**: threads a colleague already answered.
6. **Handled**: one count with categories, ending with: "nothing needs you; ask to
   see any category."
7. **Could be filed** (optional, one line): what the CEO might archive, by folder.
8. **The closing line**: where the drafts are and what the CEO does.

Draft bodies are not repeated in chat (they're in Outlook). In pasted mode, or if
the CEO asks, the full text of each draft follows the digest, in the same order
as the drafted list.

Needs-you always goes first.

---

## Worked example: Morvento

```
63 emails since yesterday. 4 need you.

NEEDS YOU
1. Dott. Rinaldi: October expense receipts still missing for the monthly
   packet, due tomorrow (5th). Without them the VAT settlement is incomplete.
2. Bottega Verdi: want German answers added to the setup project, about
   6 extra days. Need yes or no before Friday. No price given yet.
3. Ottica Lenzi: second email. Auto-replies sent a wrong opening time to
   their customers. First email Thursday, unanswered. Acknowledgement drafted;
   this needs a call.
4. Studio Fabbri: you promised the proposal by Wednesday. It's Wednesday,
   and there's no proposal in drafts/ yet.

DRAFTED: 11 replies in your Outlook Drafts
   3 scheduling (Dana Whitfield, Corradi, Nguyen)
   2 supplier confirmations
   4 product questions
   2 thank-yous for referrals

ROUTED: 3
   Hosting EU invoice, € 1.847 net of VAT, due 30/11 → finance (recurring cost)
   Studio Varenna on the September invoice → invoice-chase; say "who owes us
      money" to see the thread
   NDA from Ferramenta Bassi → legal reviewer; ask for the NDA review

COVERED BY SOMEONE ELSE: 2
   Nguyen setup question: Paolo answered at 09:15
   Corradi reschedule: Sara confirmed Friday

HANDLED: 48
   26 receipts · 11 newsletters · 7 delivery notices · 4 notifications
   Nothing needs you; ask to see any category.

The 11 replies are in your Outlook Drafts. Review and send them from Outlook,
or tell me which ones to change.
```

---

## The closing line

One line, no question with three options. The CEO sends from Outlook; this skill
never sends. If the CEO asks to change a draft, update it in Outlook (or in
`drafts/` in pasted mode) and say what changed.

---

## When there is no connector

Same digest; the drafts follow it as text, and the last line becomes:

```
Here are the 11 drafts, ready to paste into Outlook. I've also saved them in
drafts/inbox-2026-11-04.md.
```

That's a complete outcome: the CEO still skipped the hour of triage and writing.

---

## What to leave out

- **Subject lines in bulk.**
- **How the sorting worked.**
- **The handled bucket itemised.**
- **Hedging on every item.** If unsure about one, say so on that one.
