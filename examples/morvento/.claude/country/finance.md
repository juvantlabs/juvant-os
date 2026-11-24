# Finance — Italy

> Country pack for juvant-os. Facts to verify with a professional before relying on them; last reviewed 2026-11-09.

Used by the finance skills (`variance-analysis`, `reconciliation`, `financial-statements`, `cash-flow-snapshot`, `invoice-chase`, `month-end-prep`). The skills hold the method; this file holds what is specific to an Italian company. Amounts, exact dates and thresholds that change from year to year are the commercialista's call: don't state them as facts without the commercialista's confirmation.

Late-payment interest and formal notices are legal matters: see `legal.md` (and `_finance-legal-facts.md` until `legal.md` absorbs it).

---

## 1. The external accountant (commercialista)

- [ ] The books are kept by an external **commercialista**; bookkeeping entries, payroll (or a payroll provider), tax filings and the statutory accounts are theirs. The finance agent finds and explains differences and proposes what the commercialista should book; it never posts.
- [ ] Address the commercialista with their title (e.g. "Dott. Rinaldi") and write to them in Italian.
- [ ] The commercialista communicates the **F24** amounts and the income-tax advance amounts; take them from the commercialista (latest email or the CEO), never estimate them.
- [ ] The commercialista sends the payroll summary (total net pay, number of payslips) used for the salary cross-check.
- [ ] The monthly packet to the commercialista has a deadline set in `roles/finance.md` (Morvento example: bank statement, receivables and payables lists, expense receipts, by the 5th).
- [ ] The packet is titled "Packet for the commercialista" and the cover email goes to the commercialista in Italian; the documents in it are the bank statement(s), the SDI exports of issued and received invoices, the receivables and payables lists and the expense receipts. (Files keep the neutral names `drafts/accountant-packet-<YYYY-MM>.md`; earlier versions used `drafts/commercialista-packet-<YYYY-MM>.md`.)
- [ ] The periodic tax payment in the packet's salaries section is "F24 of the 16th".

### Documents the commercialista prepares

| Italian term | Meaning | Used by |
|---|---|---|
| *situazione contabile* | periodic (monthly/quarterly) interim statement | `financial-statements`, `variance-analysis` |
| *bilancio di verifica* | trial balance | `financial-statements`, `reconciliation` |
| *partitari* | subsidiary ledgers (per client/supplier) | `reconciliation` |
| *bilancio d'esercizio* | annual statutory accounts | `financial-statements` |
| *nota integrativa* | notes to the annual accounts | `financial-statements` |

When asking the CEO for a missing statement, name it: "the September situazione contabile from Dott. Rinaldi".

---

## 2. Recurring obligations and calendar

Place each on its own date in a cash forecast; amounts from the commercialista.

| When | Obligation | Notes |
|---|---|---|
| By the **16th of each month** | **F24** payment form | VAT (monthly or quarterly settlement), withholdings on salaries and professional fees, INPS contributions |
| Month end, or by the **10th of the following month** | Net salaries | depends on the company |
| With **December** salaries | 13th month (*tredicesima*) | in most collective agreements |
| **June or July** | 14th month (*quattordicesima*) | only where the collective agreement provides it |
| **January** F24 | larger than usual | includes withholdings on the 13th month |
| Around **end of June** | IRES and IRAP: balance and first advance | amounts and exact dates from the commercialista |
| Around **end of November** | IRES and IRAP: second advance | amounts and exact dates from the commercialista |
| Annual | VAT annual balance, chamber of commerce fee | plus insurance and software renewals (not country-specific) |

Checks:
- [ ] Every F24 in the window is in the outflows, with the commercialista's amount.
- [ ] December carries salaries plus the 13th month; January carries a larger F24.
- [ ] End of June and end of November carry income-tax payments.
- [ ] Bank reconciliation: scheduled F24 payments ordered but not yet debited are a timing difference.
- [ ] Month-end: the F24 paid on the 16th (bank) matches the amount the commercialista communicated.
- [ ] Risk wording: "Salary or F24 crunch" — cash on the day of salaries, the 13th month or the F24.

---

## 3. Taxes and withholdings

- [ ] **VAT**: settled monthly or quarterly through the F24; VAT credit appears among tax receivables (balance sheet C.II); VAT payable among tax payables (D).
- [ ] **Corporate income taxes**: **IRES** and **IRAP** (income-statement line 20; tax payables).
- [ ] **Withholding tax (*ritenuta d'acconto*)**: where the client is a withholding agent (e.g. on professional fees), the client pays the invoice net of the withholding.
  - The inflow is the net amount; the withheld part is a tax credit, not cash.
  - A short payment equal to the withholding is not a short payment: don't chase it, don't flag it as partial.
  - If unsure whether an invoice carries one, check the e-invoice and ask the commercialista.
- [ ] **Stamp duty (*imposta di bollo*)** on bank statements: a bank item often missing from the records; a reconciling item (correction needed).

---

## 4. E-invoicing: SDI

- [ ] Every invoice issued and received by an Italian company goes through **SDI** (Sistema di Interscambio), so the SDI export is the complete record of invoices. The CEO downloads issued and received exports from the e-invoicing portal.
- [ ] An invoice rejected by SDI (*scartata*) was never legally issued and must be reissued; the client may not even have it. Flag it for the CEO and the commercialista; don't chase it.
- [ ] Check SDI delivery status for each issued invoice (delivered / rejected / not found).
- [ ] Credit notes (*note di credito*) reduce the open amount; match them to the invoice they correct. A supplier may cancel an invoice with a credit note and reissue it: both reach SDI.
- [ ] Received invoices in the payables list with no SDI invoice may be pro-forma or from foreign suppliers (which go through other reporting): ask.
- [ ] Card payments to foreign (non-Italian) suppliers — cloud hosting, SaaS, travel, online services — don't come through SDI; the commercialista still needs the supplier's invoice or receipt.
- [ ] The client's legal name and VAT number (*partita IVA*) are on the e-invoice (needed for a counsel handoff).

---

## 5. Payroll items

- [ ] Personnel cost = gross salary + employer social contributions (**INPS**, **INAIL**) + **TFR** accrual + 13th month (and sometimes a 14th) accrued across the year under most collective agreements.
- [ ] **TFR** (*trattamento di fine rapporto*, employee severance indemnity): accrues every month, is a real liability (balance sheet C), and is paid out when people leave — departures save salary but trigger a TFR payout.
- [ ] Accrual timing variance: 13th/14th month booked in one month instead of spread.
- [ ] Payroll figures come from the commercialista or payroll provider; totals only.

---

## 6. Statutory accounts: layout and standards

- [ ] Layout set by the civil code: balance sheet **art. 2424 c.c.**, income statement **art. 2425 c.c.** (costs classified by nature), cash flow statement **art. 2425-ter c.c.**
- [ ] Accounting principles: **OIC**. Cash flow statement usually by the indirect method (**OIC 10**).
- [ ] Cash flow statement required for companies filing the full *bilancio*; companies filing the abridged form (**art. 2435-bis c.c.**) or as micro-companies (**art. 2435-ter c.c.**) are exempt, so it may not exist.
- [ ] The annual *bilancio* is approved by the shareholders and filed with the Companies Register (*Registro delle Imprese*); for a small company usually in abridged form under OIC. Thresholds, deadlines and the applicable form are the commercialista's call.
- [ ] Equity: losses that erode share capital beyond the civil-code thresholds trigger obligations for the directors. If equity looks low against share capital, raise it with the commercialista and counsel without stating the legal consequences yourself.

### Income statement (Conto economico), art. 2425 c.c.

Use this numbering when presenting an Italian statement; show only the lines the statement contains.

```
A) VALUE OF PRODUCTION (Valore della produzione)
   1) Revenue from sales and services
   5) Other revenue and income
   Total A
B) COSTS OF PRODUCTION (Costi della produzione)
   6) Raw materials and goods
   7) Services
   8) Use of third-party assets (rent, leases)
   9) Personnel (wages, social contributions, TFR, other)
  10) Depreciation, amortisation and write-downs
  14) Other operating costs
   Total B
DIFFERENCE A - B (operating result)
C) FINANCIAL INCOME AND CHARGES
D) VALUE ADJUSTMENTS OF FINANCIAL ASSETS
RESULT BEFORE TAXES
  20) Income taxes (IRES, IRAP)
NET RESULT FOR THE PERIOD
```

EBITDA from this layout: A − B excluding item 10.

### Balance sheet (Stato patrimoniale), art. 2424 c.c.

```
ASSETS (Attivo)
A) Amounts due from shareholders for unpaid capital
B) Fixed assets
   I   Intangible (software, development costs, trademarks)
   II  Tangible (equipment, furniture, hardware)
   III Financial (shareholdings, long-term receivables)
C) Current assets
   I   Inventory (incl. work in progress on orders)
   II  Receivables (trade receivables, tax receivables such as VAT credit, other)
       — shown separately when due beyond 12 months
   III Current financial assets
   IV  Cash and bank
D) Accrued income and prepaid expenses (ratei e risconti attivi)

LIABILITIES AND EQUITY (Passivo)
A) Equity (share capital, reserves, retained earnings, result for the year)
B) Provisions for risks and charges
C) Employee severance indemnity (TFR)
D) Payables (bank loans, trade payables, tax payables, social security payables, other)
   — shown separately when due beyond 12 months
E) Accrued expenses and deferred income (ratei e risconti passivi)
```

What to look at, by section: cash C.IV vs the buffer; trade receivables C.II vs the receivables list; tax and social-security payables D (VAT, withholdings and INPS due with the next F24); TFR C; deferred income E (annual licences invoiced in advance); equity A.

### Cash flow statement (Rendiconto finanziario), art. 2425-ter c.c., OIC 10

```
A) Cash flow from operating activities
B) Cash flow from investing activities
C) Cash flow from financing activities
Increase (decrease) in cash = A ± B ± C
```

For an indicative cash view without one: result + depreciation ± change in receivables, payables and TFR.

### Period-end entries Italian interim statements usually lack

- [ ] Accruals and deferrals (*ratei e risconti*).
- [ ] Depreciation and amortisation.
- [ ] TFR accrual for the period.
- [ ] 13th/14th month accruals where the collective agreement provides them.
- [ ] Provision for doubtful receivables.
- [ ] Invoices to issue or receive (*fatture da emettere / da ricevere*).
- [ ] IRES and IRAP for the year.
- [ ] Work in progress on orders spanning year end.

---

## 7. Bank data

- [ ] Italian bank exports name columns: "Data contabile", "Data valuta", "Data operazione", "Importo", or separate "Dare" (debit) and "Avere" (credit) columns; description as "Causale" or "Descrizione". Amount = avere − dare. Use the value date (*data valuta*) for cash timing.
- [ ] Payment methods to recognise: SEPA transfers (*bonifico*), SDD direct debits, F24 debits.
- [ ] A client's payment notice often reads "bonifico disposto" (transfer ordered): treat as "possibly paid — verify".
- [ ] Invoices often go to an accounts address such as *amministrazione@*; reminders go to the address the invoice was sent to.
- [ ] Test rows may be named "prova" as well as "test" or "demo".

---

## 8. Seasonality and language

- [ ] August and December are usually unrepresentative months in Italy: prefer same-period-last-year comparisons.
- [ ] Reminders to Italian clients and mail to the commercialista are written in Italian.

## Also relevant (from locale.md)

- [ ] **LIPE**: the quarterly communication of periodic VAT settlements; the commercialista files it.
- [ ] A supplier's emailed PDF invoice is a *copia di cortesia*: the e-invoice received through SDI is the one the commercialista books.
- [ ] An srl's financial year is usually the calendar year; check the company's statute.
