# Output template

> Adapted from anthropics/knowledge-work-plugins `small-business/skills/business-pulse` at commit e050c2e (Apache-2.0). Modified for juvant-os: sections match the juvant-os sources (bank export, receivables, proposals, deadlines, waiting on the CEO); euro and Italian formats; status words instead of colored emoji.

The structure every pulse follows. Don't reorder sections. Omit a section only if
it had no data; never leave an empty header.

`{{double braces}}` are placeholders. Arrows: ▲ up, ▼ down, ▬ flat (under 1%),
always followed by the change.

---

```markdown
# Business pulse, {{giorno mese anno, e.g. 9 novembre 2026}}

**Overall: {{OK | Review | Critical}}** {{one line, e.g. "Cash above buffer; one client 46 days late needs your call."}}

## Summary

- {{Most important number-backed fact}}
- {{Second}}
- {{Third}}

---

## Cash ({{status}})

- **Balance**: € {{BALANCE}} at {{export date}} ({{▲|▼|▬}} € {{DELTA}} on the previous export)
- **Buffer**: {{n,n}} months of fixed costs (rule: {{rule from roles/finance.md}})
- **Next commitments**: {{F24 on the 16th, recurring costs, known payments}}

---

## Receivables ({{status}})

- **Open**: € {{TOTAL}} across {{N}} invoices
- **Aging**: 0–30 days € {{A}} · 31–60 € {{B}} · 61+ € {{C}}

**Late**
| Client | Invoice | Amount | Days late | Next step (our rule) |
|---|---|---|---|---|
| {{client}} | {{n.}} | € {{amount}} | {{days}} | {{step}} |

---

## Proposals and deals ({{status}})

- **Open proposals**: {{N}}, € {{TOTAL}}
- **New inquiries this week**: {{N}} ({{names}})

**Needing attention**
- {{client}}: {{why: no answer for N days / promised date passed}}

---

## This week

- {{date}}: {{meeting or deadline, with whom, why it matters}}
{{3 to 5 items. Skip internal noise.}}

---

## Watch list

- {{sender / source}}: {{what needs attention}}
{{Or "No urgent threads." so the CEO knows the check ran.}}

---

## Waiting on you

- {{drafts ready in drafts/, reviews finished, decisions to record}}

---

## #1 priority

{{One specific thing to act on today, with names, amounts and dates.
Not "review receivables": "Studio Varenna owes € 4.880 on invoice 2026/079,
46 days late; our rule says you call them at 45 days. A second invoice of
€ 2.440 is 18 days late."}}

---

## Appendix

**Window**: {{date range}}
**Sources read**: {{list, with export dates}}
**Sources unavailable**: {{list with reason, e.g. "Bank: no export since 30/10"}}
**Defaults used**: {{thresholds not set in roles/finance.md}}
```

---

## Formatting rules

1. **Amounts**: `€ 43.200`, `€ 1,2 mln`; no unnecessary decimals; Italian
   separators.
2. **Percentages**: one decimal for trends (`▲ 8,3%`), integers elsewhere.
3. **Dates**: day before month in prose (`14 marzo` / `14 March`), `14/03` in
   tables, ISO in filenames.
4. **Arrow spacing**: `▲ € 2.000`, not `▲€2.000`.
5. **Length**: one page; two at most.
6. **Language**: the CEO's working language (per the manifesto or the
   conversation).
