# Gotchas

> Adapted from anthropics/knowledge-work-plugins `small-business/skills/business-pulse` at commit e050c2e (Apache-2.0). Modified for juvant-os: QuickBooks, Gmail and Slack cases replaced by stale exports, double counting, Outlook errors and sharing; the "don't ask before reading" rule kept; country-neutral; local rules from the country pack.

Known failure modes, with good and bad versions.

---

## An old export presented as today

A bank export is a snapshot. Showing its balance as "cash today" leads the CEO to
decide on a number that may be two weeks old.

**Bad**
```
Cash: € 112.400
```

**Good**
```
Cash: € 112.400 at 30/10 (latest bank export; 10 days old)
```
…and the Cash section capped at Review if a decision depends on it.

---

## The same figure counted twice

Receivables appear in the e-invoicing export and in the external accountant's
spreadsheet.
Adding them doubles the total.

**Good**: one source of record per figure, named in the appendix; the other
source is used only to flag differences
([sources](../../kwp-shared/connector-neutrality.md)).

---

## A missing source treated as "nothing to report"

No receivables export is not "no overdue invoices".

**Bad**: omit Receivables silently; the CEO assumes nobody owes anything.

**Good**: "Receivables: n/a, no export provided" in the section and the appendix,
with what would fill it.

---

## An Outlook error in the middle of the pulse

**Bad**: a raw error message in the Watch list.

**Good**: the pulse continues without the Watch list; the appendix says "Outlook:
error, watch list not checked this run".

---

## Asking permission before reading

The CEO invoked the pulse; that's the permission.

**Bad**
```
Should I look at the receivables file? And may I read your calendar?
```

**Good**: read everything available, deliver the page.

The exception is a mailbox or file store that doesn't look like the company's
([tenant scope](../../kwp-shared/tenant-scope.md)): ask once, in one line.

---

## Sharing the pulse

The pulse can carry cash and client figures. It is not posted to Teams or emailed
by this skill.

**Bad**: "I've posted the pulse to the team channel."

**Good**: deliver it in chat (and `drafts/` if asked). If the CEO wants to share
it, they do, and you mention any figure they may not want everyone to see.
