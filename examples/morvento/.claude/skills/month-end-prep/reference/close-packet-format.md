> Adapted from anthropics/knowledge-work-plugins `small-business/skills/month-end-prep` at commit e050c2e (Apache-2.0). Modified for juvant-os: the XLSX/PDF close packet becomes a markdown packet index for the commercialista plus an Outlook cover-email draft; payroll sheet reduced to totals cross-check; processor reconciliation columns replaced by bank/SDI checks.

# Commercialista packet format

The packet is two things: a markdown index with the checks and open questions, and a cover email draft. The documents themselves (statements, SDI exports, receipts) stay where they are; the index points to them.

## File naming

```
drafts/commercialista-packet-2026-10.md
drafts/commercialista-packet-2026-10-email.md   (only if the Outlook draft can't be created)
```

Use `YYYY-MM` for the month.

---

## Index file

### Header

```
# Packet for the commercialista — October 2026
Company: <name>   Prepared: <date>   For: <commercialista name>   Due by: <deadline from roles/finance.md>
Sources: <what was used, with as-of dates>
Not available: <sources missing this month, and what that leaves unchecked>
```

### 1. Documents

| Document | Period | Location |
|---|---|---|
| Bank statement, account <last 4 digits or nickname> | 1–31 Oct | <SharePoint/OneDrive link or file path> |
| SDI export, invoices issued | Oct | |
| SDI export, invoices received | Oct | |
| Receivables list | at 31 Oct | |
| Payables list | at 31 Oct | |
| Expense receipts | Oct | <folder> |

Refer to accounts by nickname or last four digits, never the full IBAN.

### 2. Bank

| Account | Opening | Closing | Continuity with last month |
|---|---|---|---|
| | EUR | EUR | OK / gap of EUR X |

### 3. Receivables

Invoices issued in the month and their SDI status, receipts in the month matched to invoices, and the open list with ageing.

| Invoice | Client | Date | Due | Amount | SDI | Paid on | Status |
|---|---|---|---|---|---|---|---|
| | | | | EUR | delivered / rejected / not found | | MATCHED / OPEN / OVERDUE (X days) / NOT IN SDI / NOT IN LIST |

### 4. Payables

| Supplier | Invoice | Date | Due | Amount | SDI | Paid on | Status |
|---|---|---|---|---|---|---|---|
| | | | | EUR | | | MATCHED / OPEN / PAID, NO INVOICE / INVOICE, NOT IN LIST |

### 5. Expenses without an SDI invoice

| Date | Amount | Counterparty | Payment | Receipt |
|---|---|---|---|---|
| | EUR | | card / cash / transfer | on file: <location> / MISSING / not available (CEO) |

### 6. Salaries and F24 (totals only)

| Item | Per commercialista | Per bank | Delta |
|---|---|---|---|
| Net salaries (X payslips) | EUR | EUR | EUR |
| F24 of the 16th | EUR | EUR | EUR |

No names or per-person amounts.

### 7. Open questions

| # | Date | Amount | Counterparty | Question | Document | Proposed treatment |
|---|---|---|---|---|---|---|
| 1 | | EUR | | | attached / missing | |

Questions deferred by the CEO at the review gate are listed here, marked "deferred". If there are none: "No open questions this month."

### 8. Month in brief (optional)

The 100–200 word note from Step 10, marked as a cash view.

---

## Cover email (Outlook draft)

To the commercialista, from the CEO's mailbox, not sent.

```
Subject: <Company> — documents for <Month Year>

Dear <title and name>,

attached / in the shared folder you'll find the documents for <month>:
bank statement(s), SDI exports of issued and received invoices,
receivables and payables lists, and expense receipts.

There are <X> open questions, listed at the end of the summary; the
most important is <one line>. <X> receipts are still missing; we'll
send them as soon as we have them.

Kind regards,
<CEO name>
```

Write it in the language the company uses with the commercialista (normally Italian). Attaching the files and sending are the CEO's.
