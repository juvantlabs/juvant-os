# Triage rules

> Adapted from anthropics/knowledge-work-plugins `small-business/skills/inbox-manager` at commit e050c2e (Apache-2.0). Modified for juvant-os: legal-weight mail, e-invoicing notifications and tax deadlines as signals, CEO instead of owner, Morvento worked example; country-neutral; local rules from the country pack.

Three buckets. The whole value of this skill is that the first bucket is short and
correct.

**Local rules.** If the country pack's `locale.md`, `finance.md` or `legal.md`
exists (in `.claude/country/` or `country/`), apply its checks and use its terms: which mail
has legal weight, which authorities and forms of notice exist, which tax and
contribution deadlines are hard. If neither exists, say which points depend on
local law or practice and list them under NOT CHECKED (to check with local
counsel or the accountant).

---

## Bucket 1: Needs you

An item belongs here only if the CEO personally has to do something:

| Signal | Example |
|---|---|
| A decision only the CEO can make | Accept or decline a project, approve a change to scope, a discount |
| Money moving | A supplier invoice over the approval threshold in `roles/finance.md`, a refund request, a payment dispute |
| An unhappy customer | A complaint, an escalation, a second email with a sharper tone |
| A hard deadline | A tax or contribution payment due this week (dates in the country pack's `finance.md`), an insurance renewal, a tender deadline, a document the external accountant needs by a set date |
| A commitment already made | The CEO wrote "I'll send the numbers Wednesday" and it's Wednesday |
| Anything legal or regulatory | A contract, a formal notice, certified mail from a public authority, the tax authority, the social-security institute, a court |
| Payment details changed | New bank details, urgent transfer request, lookalike sender domain: needs you, never drafted, verify by phone |

**Mail with legal weight is never handled automatically.** Where the country
has certified or registered email with legal effect (the locale file names it),
a message of that kind always lands in needs-you, with the sender and subject,
and a note to involve the `legal` reviewer if it's a notice.

**Rank by consequence, not arrival time.** What happens if this waits 24 hours? A
deadline on Friday outranks a newer, lighter question.

Keep it to about five. If eight qualify, list eight; if twenty qualify, the
threshold is wrong and the triage needs tightening.

## Bucket 2: Drafted

A reply is in Outlook Drafts, waiting for the CEO to review and send. Most mail
lands here: routine customer questions, scheduling, supplier confirmations,
questions answered many times before.

The CEO's job on this bucket is to skim and send, not to think.

## Bucket 3: Handled

Receipts, newsletters, delivery notices, calendar confirmations, platform
notifications, automatic reports, e-invoicing system notifications for invoices
already known.

**Report as a count with categories, never a list.** "41 handled: 22 receipts, 9
newsletters, 6 deliveries, 4 notifications." The CEO can ask to see any category.

---

## Edge cases

**A thread with a receipt and a question.** The question wins.

**A newsletter from someone the CEO knows.** Still handled.

**Cold sales pitches.** Handled. No draft, not surfaced.

**Something you can't classify.** Needs-you, saying you weren't sure why.
Under-filing is cheap; over-filing loses a customer.

**A thread a colleague already answered.** Leave it, note it under "covered by
someone else". Replying under a colleague looks disorganised and undercuts them.

---

## Worked example: Morvento, Wednesday 4 November

Giulia's inbox: 63 new since yesterday afternoon.

**Needs you (4)**

1. **External accountant: documents for the monthly packet due Thursday 5th.**
   Dott. Rinaldi is still missing October's expense receipts. Without them the
   VAT settlement is calculated on incomplete figures.
2. **Bottega Verdi: change of scope, about 6 extra days.** They want German
   answers added to the setup project. Needs a yes or no before their Friday
   meeting; price not given yet.
3. **Ottica Lenzi: second email, unhappy.** Auto-replies sent a wrong opening
   time to their customers. First email was Thursday, unanswered.
4. **Studio Fabbri: you promised the proposal Wednesday.** You wrote "proposta
   entro mercoledì" on 27 October. It's Wednesday.

**Drafted (11)**: three scheduling replies, two supplier confirmations, four
routine product questions, two thank-yous for referrals.

**Handled (48)**: 26 receipts, 11 newsletters, 7 delivery notices, 4 notifications.

**Routed (3)**: a cloud-hosting invoice flagged for `finance`, a reply from a
client about an overdue invoice to `invoice-chase`, an NDA from a prospect to the
`legal` reviewer.

Giulia reads that in about a minute and knows what her morning is.
