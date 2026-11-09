# Data sources

> Adapted from anthropics/knowledge-work-plugins `small-business/skills/business-pulse` at commit e050c2e (Apache-2.0). Modified for juvant-os: the per-vendor tool tables (QuickBooks, Xero, NetSuite, MYOB, Zoho, PayPal, Square, Stripe, HubSpot, Gusto, Shopify, TikTok, Ramp, Expensify, DocuSign, Slack) are replaced by the repo, CEO-provided exports and the Microsoft 365 connector; country-neutral; local rules from the country pack.

What each pulse section reads. **Read independent sources in parallel**; don't
pull serially. Where a file lives comes from `memory/map.md`; the paths below are
the usual ones.

---

## Company rules (read first)

| What | Where | Used for |
|---|---|---|
| Cash buffer, payment terms, late-payer ladder, approval threshold | `roles/finance.md` | Thresholds, next steps on late payers |
| Recurring deadlines | `roles/finance.md` | This week's commitments |
| Who decides what | `manifesto.md` | What lands on the CEO |
| Where exports and lists live | `memory/map.md` | Paths |
| Local calendar and terms | Country pack `finance.md` and `locale.md` (`.claude/country/` or `country/`) | Tax and contribution dates, e-invoicing system, mail with legal weight, escalation words; without a pack, these points are listed as not checked |

## Cash

| Metric | Source | Notes |
|---|---|---|
| Balance | Latest bank export (CSV or PDF statement) | Closing balance and its date. A balance without a date is not usable |
| Week-on-week change | Same export, or the previous one | If only one export exists, "(no prior figure)" |
| Large movements | Same export | Single movements over the approval threshold in `roles/finance.md`, named |
| Months of buffer | Balance ÷ monthly fixed costs in `roles/finance.md` | Only if the role card gives fixed costs |

If there's no bank export, the Cash section reads "n/a: no bank export provided"
and the appendix says what would fill it. Never estimate a balance.

## Receivables

| Metric | Source | Notes |
|---|---|---|
| Open invoices | E-invoicing or receivables export (e.g. `samples/finance/receivables.csv`: `invoice, client, issued, due, amount_eur, paid_on`) | Open = no `paid_on` |
| Aging | Same | Days past `due`: 0–30, 31–60, 61+ |
| Late-payer step | Same + ladder in `roles/finance.md` | E.g. 7 days: friendly reminder; 30: firm; 45: CEO call; 60: formal notice from counsel |
| Paid late recently | Same | `paid_on` after `due`: pattern, not a risk |

State whether amounts include VAT if the export says; if it doesn't, say
"amounts as in the export".

## Proposals and deals

No CRM. Read:

| Metric | Source | Notes |
|---|---|---|
| Open proposals | `drafts/` (proposal files) and any proposals list `memory/map.md` points to | Client, value, date sent (from Outlook sent mail if the CEO sent it) |
| Waiting for an answer | Outlook: last message in the client thread | Days since we sent it |
| New inquiries this week | Outlook: inbound from new contacts | Count and names |
| Won or lost | `memory/decisions/`, `state/activity.jsonl` | Recent outcomes |

If there's no list and nothing in `drafts/`, omit the section.

## Commitments (next 7 days)

| Metric | Source | Notes |
|---|---|---|
| External meetings | Outlook calendar | Clients, prospects, partners, the external accountant, counsel; skip internal noise |
| Deadlines | `roles/finance.md`, country pack `finance.md` | Tax and contribution payments, the external accountant's packet, VAT or sales-tax dates; exact dates as the role card states them |
| Promised dates | Outlook threads, `memory/decisions/` | "By Friday" the CEO wrote (in any language) |
| Renewals and expiries | `memory/knowledge/`, contracts listed in `memory/map.md` | Within 30 days |

## Watch list

| Metric | Source | Notes |
|---|---|---|
| Urgent threads | Outlook: flagged or marked important, last 7 days | |
| Escalations | Outlook: "complaint", "cancel", "refund", "urgent", "escalation", plus the local-language words in the locale file | |
| Unanswered clients | Outlook: client threads where the last message is theirs, 2+ working days | |
| Mail with legal weight | Outlook: certified or registered email, as the locale file defines it, if it reaches this mailbox | Always listed |
| Teams | Chats and mentions to the CEO | Asks needing the CEO |

If Outlook errors, skip the section and note it in the appendix.

## Waiting on the CEO

| Metric | Source | Notes |
|---|---|---|
| Drafts ready | `drafts/` | Files newer than the last pulse, or not yet marked done |
| Reviews finished | `state/activity.jsonl` | Entries from reviewers (`legal`, `finance`, `ethics`) routed to the CEO |
| Decisions to record | `memory/decisions/` | Follow-ups promised in recent decisions |

## Risks scan

Run alongside the metric reads.

| Risk | Source | Trigger |
|---|---|---|
| Overdue receivable | Receivables export | Past due; step per the late-payer ladder |
| Stale proposal | `drafts/`, Outlook | No answer 14+ days, or promised date passed |
| Urgent mail | Outlook | Escalation words, mail with legal weight, second unanswered client email |
| Deadline | `roles/finance.md`, country pack, calendar | Within 7 days |
| Cash | Bank export, `roles/finance.md` | Below buffer, or a known payment would take it below |
| Old export | Any export | Older than 7 days: label it, and flag if decisions depend on it |
