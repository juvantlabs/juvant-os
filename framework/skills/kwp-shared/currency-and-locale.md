# Currency, dates and periods

> Adapted from anthropics/knowledge-work-plugins `small-business/shared/currency-and-locale.md` at commit e050c2e (Apache-2.0). Modified for juvant-os: values come from the role card and the country pack instead of an onboarding block; US-only paths removed; country-neutral; local rules from the country pack.

Scope: **every skill that emits an amount, a date in prose, or a period** ("this
quarter", "year to date").

---

## Where the values come from

Read, in this order, and ask only for what none of them says:

1. `roles/finance.md` (currency, payment terms, thresholds, deadlines, financial
   year)
2. `memory/knowledge/` (for example a company facts file) and `memory/map.md`
3. **The country pack's locale file**: `.claude/country/locale.md` or
   `country/locale.md`

**Use the formats in the country pack's locale.md; if none, ask the CEO once and
propose recording them in `memory/knowledge/`.** Ask in one message for what the
output needs: currency, thousands and decimal separators, date order, 12- or
24-hour time, the financial year if it isn't the calendar year, and the language
and register for counterparties. Quote the lines you'd add; write them only on
a yes.

Never keep these values in a skill's own config or in session memory: the role
card, `memory/knowledge/` and the country pack are the only places.

---

## Amounts

- **Separators and symbol position** as the locale file says, the same in prose
  and in tables.
- **The company's currency uses its symbol or code as the locale file says.
  Any other currency uses its ISO code**, never a bare symbol: `USD 1,240`,
  `GBP 980`, `CHF 2,000`. A bare `$` is ambiguous across several dollar
  currencies.
- **Never convert silently.** A payment received in another currency is shown in
  its own currency, with the company-currency equivalent only if the source (bank
  statement, invoice) gives it, and the source named.
- **Sales tax / VAT is explicit.** Say whether an amount is net of VAT (or sales
  tax) or includes it. Use the wording the locale file gives (for example the
  suffix used after a net B2B price). If the source does not say, flag it rather
  than assume.
- **Spreadsheet formats** follow the locale's number format, never a default
  dollar format.
- **Numbers in a column are right-aligned**, same number of decimals throughout.

---

## Thresholds

Skills carry attention thresholds ("flag a difference over 0.50", "payments over
200"). Write them as plain numbers in the company's currency. They are judgement
lines, not legal ones.

**A legal threshold names its law.** If a skill uses a threshold or a rule that
comes from law (statutory late-payment interest, VAT or sales-tax regimes,
cash-payment limits), it names the source, taking it from the country pack
(`legal.md`, `finance.md`), and says "check with the external accountant" or
"check with counsel" when the exact figure matters. Do not state a legal figure
you are not sure of. Without a country pack, say the point depends on local law
and list it under NOT CHECKED.

---

## Dates and times

- **Date order and time format** as the locale file says. Whatever the locale,
  never write an ambiguous numeric date: if the order isn't known, spell the
  month (`14 March 2026`).
- **Filenames and metadata stay ISO:** `2026-03-14`.
- **First day of the week** as the locale file says.
- **Public holidays** (and any local holiday the company records in
  `memory/knowledge/`) are not working days when counting deadlines. Take them
  from the locale file or an official calendar, never from memory.

---

## Periods and deadlines

- **"This quarter", "year to date", "last year"** resolve against the financial
  year in `roles/finance.md` (the country pack's default, or the calendar year,
  if it says nothing). Q1 = the first three months of the financial year.
- **Deadlines belong to a regime.** Tax payments, VAT or sales-tax returns,
  social contributions and the e-invoicing system (if the country has one) have
  their own calendars, listed in the country pack's `finance.md`.

  Take the exact dates and which ones apply from `roles/finance.md` and the
  external accountant, not from memory: deadlines move (weekends, holidays,
  extensions) and some depend on the company's regime.
- **One country's logic at a time.** If a source document is from a counterparty
  in another country, show its amounts and dates as given, and do not apply the
  company's tax logic to it without saying so.

---

## Worked examples

Reference files use Morvento (a fictional six-person company) and euro amounts
in its locale's formats (e.g. `€ 1.240`). They are examples of shape and tone,
not output and not a format rule: a skill always takes real figures from the
company's own files and formats from the locale file.
