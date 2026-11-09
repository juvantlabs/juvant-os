# Currency, dates and periods

> Adapted from anthropics/knowledge-work-plugins `small-business/shared/currency-and-locale.md` at commit e050c2e (Apache-2.0). Modified for juvant-os: defaults to EUR, Italian number and date formats and the Italian tax calendar; values come from the role card instead of an onboarding block; US-only paths removed.

Scope: **every skill that emits an amount, a date in prose, or a period** ("this
quarter", "year to date"). juvant-os is built for Italian companies: unless the
company's files say otherwise, money is in euro and formats are Italian.

---

## Where the values come from

Read, in this order, and ask only for what none of them says:

1. `roles/finance.md` (currency, payment terms, thresholds, deadlines)
2. `memory/knowledge/` (for example a company facts file) and `memory/map.md`
3. The defaults below

**Defaults:** country IT, currency EUR, financial year = calendar year
(1 January to 31 December, the usual case for an Italian srl). If the company's
financial year is different, it should be written in `roles/finance.md`; if it
isn't and it matters for the output, ask once and propose adding it there.

Never keep these values in a skill's own config or in session memory: the role
card is the single place.

---

## Amounts

- **Italian separators:** dot for thousands, comma for decimals.
  `€ 1.240`, `€ 18.400,50`, `€ 0,50`.
- **Euro sign before the figure, with a space**, in prose and in tables:
  `€ 1.240`. Abbreviations keep the sign: `€ 43k`, `€ 1,2 mln`.
- **Any other currency uses its ISO code**, never a bare symbol: `USD 1.240`,
  `GBP 980`, `CHF 2.000`. A bare `$` is ambiguous across several dollar
  currencies.
- **Never convert silently.** A payment received in another currency is shown in
  its own currency, with the euro equivalent only if the source (bank statement,
  invoice) gives it, and the source named.
- **VAT is explicit.** Say whether an amount is net of VAT (imponibile) or
  including VAT (IVA inclusa). B2B prices and proposals are normally stated net
  of VAT with "+ IVA"; if the source does not say, flag it rather than assume.
- **Spreadsheet formats:** `#.##0,00 €` style (or the locale's equivalent), never
  a dollar format.
- **Numbers in a column are right-aligned**, same number of decimals throughout.

---

## Thresholds

Skills carry attention thresholds ("flag a difference over 0,50", "payments over
200"). Write them as plain numbers in euro. They are judgement lines, not legal
ones.

**A legal threshold names its law.** If a skill uses a threshold or a rule that
comes from Italian law (late-payment interest under D.Lgs. 231/2002, VAT
regimes, cash-payment limits), it names the source and says "check with the
commercialista" or "check with counsel" when the exact figure matters. Do not
state a legal figure you are not sure of.

---

## Dates and times

- **Day before month, always.** In Italian prose: `14 marzo 2026`; in English
  prose: `14 March 2026`; short numeric form: `14/03/2026`. Never `March 14` or
  `03/14`.
- **24-hour times:** `15:00`, not `3:00 PM`.
- **Filenames and metadata stay ISO:** `2026-03-14`.
- **Week starts on Monday.** Italian public holidays (including the company's
  local patron saint day, if written in `memory/knowledge/`) are not working
  days when counting deadlines.

---

## Periods and deadlines

- **"This quarter", "year to date", "last year"** resolve against the financial
  year in `roles/finance.md` (calendar year by default). Q1 = January to March.
- **Deadlines belong to a regime.** Italian ones that commonly matter:
  - F24 payments (VAT monthly settlement, withholdings, INPS contributions) by
    the 16th of the month;
  - quarterly VAT communication (LIPE) and the annual returns, filed by the
    commercialista;
  - e-invoices through SDI, with their issue and receipt dates.

  Take the exact dates and which ones apply from `roles/finance.md` and the
  commercialista, not from memory: deadlines move (weekends, holidays,
  extensions) and some depend on the company's regime.
- **No US paths.** There is no sales tax, 1099, W-9 or US estimated tax in
  juvant-os. If a source document is from a non-Italian counterparty, show its
  amounts and dates as given, and do not apply Italian tax logic to it without
  saying so.

---

## Worked examples

Reference files use Morvento (a fictional six-person company in Bologna) and
euro amounts. They are examples of shape and tone, not output: a skill always
takes real figures from the company's own files.
