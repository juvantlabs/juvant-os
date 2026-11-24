# Locale — Italy

> Country pack for juvant-os. Facts to verify with a professional before relying on them; last reviewed 2026-11-09.

Used by every skill that writes an amount, a date, a period or a message in the
company's name, through `kwp-shared/currency-and-locale.md` and
`kwp-shared/voice-profile.md`. The skills hold the method; this file holds the
Italian formats, words and calendar. Where the company's own files
(`roles/finance.md`, `memory/knowledge/`, the manifesto) say something different,
the company's files win.

Tax and contribution deadlines are in `finance.md`; contract and data-protection
rules in `legal.md`; consent, consumer and advertising rules in `marketing.md`.

---

## 1. Defaults

- [ ] Country: IT. Currency: **EUR**.
- [ ] Financial year: the **calendar year** (1 January to 31 December), the usual
  case for an Italian srl. A different financial year should be written in
  `roles/finance.md`.
- [ ] Q1 = January to March.

---

## 2. Amounts

- [ ] **Separators**: dot for thousands, comma for decimals: `€ 1.240`,
  `€ 18.400,50`, `€ 0,50`.
- [ ] **Euro sign before the figure, with a space**, in prose and in tables:
  `€ 1.240`. Abbreviations keep the sign: `€ 43k`, `€ 1,2 mln`.
- [ ] Arrows and signs keep the space: `▲ € 2.000`, not `▲€2.000`.
- [ ] **Percentages**: `8,3%` (comma decimal); `50 per cento` is the spelled-out
  alternative in prose, if the brand file prefers it.
- [ ] **Spreadsheet format**: `#.##0,00 €` style (or the locale's equivalent),
  never a dollar format.
- [ ] Price tables in documents use euro formatting: `€ 4.550`.

### VAT wording

- [ ] VAT is **IVA**. An amount net of VAT is the *imponibile*; including VAT is
  *IVA inclusa*.
- [ ] B2B prices and proposals are normally stated **net of VAT with "+ IVA"**:
  `€ 4.875 + IVA`. If the source does not say, flag it rather than assume.
- [ ] Marketing copy aimed at businesses that shows a price without "+ IVA",
  where the VAT treatment isn't clear, needs a disclaimer (see `marketing.md`).

---

## 3. Dates and times

- [ ] **Day before month, always.** Italian prose: `14 marzo 2026`; English
  prose: `14 March 2026`; short numeric: `14/03/2026`; in tables `14/03`.
  Never `March 14` or `03/14`.
- [ ] Page and document titles in Italian: `# Business pulse, 9 novembre 2026`.
- [ ] **24-hour times**: `15:00`, never `3:00 PM`.
- [ ] Filenames and metadata stay ISO: `2026-03-14` (not country-specific; kept
  here so the list is complete).
- [ ] **Week starts on Monday.**
- [ ] Press-release dateline: city and date, `Bologna, 14 marzo 2026`.

---

## 4. Calendar

- [ ] **Italian public holidays are not working days** when counting deadlines.
  Take the list for the year from an official calendar; the dates are not
  repeated here.
- [ ] The company's **local patron saint day** is also a non-working day where
  it applies; record it in `memory/knowledge/` (for example a company facts
  file).
- [ ] Deadlines move when they fall on a weekend or a holiday, and some are
  extended: exact dates come from `roles/finance.md` and the commercialista
  (`finance.md`), never from memory.
- [ ] **August and the Christmas period**: B2B attention drops (campaign timing
  in `marketing.md`; comparisons in `finance.md`).

---

## 5. Business language and register

- [ ] **Language**: Italian with Italian counterparties (clients, the
  commercialista, counsel, authorities), unless the manifesto says otherwise.
  Searches and keywords for an Italian audience are in Italian.
- [ ] **Register**: *tu* (informal) or *Lei* (formal). Use the one the CEO
  already used with that person in the thread; for new contacts follow the
  brand file. Record the company's default in `memory/knowledge/brand.md`.
- [ ] **Greetings and titles**: informal `Ciao Marta,`; formal
  `Gentile dott.ssa Rossi,`, `Buongiorno avvocato,`. Professionals are
  addressed with their title (dott./dott.ssa, avvocato, ingegnere, notaio).
- [ ] **Filler to avoid** (Italian equivalents of the English never-dos), unless
  the company's files show the CEO uses them:
  - "Spero che questa email la trovi bene" / "spero che stia bene"
  - "Come da accordi"
  - "Come da mia precedente"
  - "Non esiti a contattarmi"
  - "Scusa il ritardo" when there was no delay
- [ ] **Links**: descriptive link text, never "clicca qui".
- [ ] **Headings**: sentence case in Italian.
- [ ] **Inclusive language**: where the person is unknown and the brand file
  doesn't specify, prefer neutral rewordings over forced gendered forms.
- [ ] **Promises in mail** often read "entro mercoledì", "entro venerdì",
  "vi mando la proposta entro…": these are commitments with a date.
- [ ] **Escalation words** to scan for in Italian mail: "reclamo" (complaint),
  "disdetta" (cancellation / notice of non-renewal), "urgente" (urgent).

---

## 6. Typical documents, identifiers and institutions

| Italian term | What it is | How skills treat it |
|---|---|---|
| **PEC** (posta elettronica certificata) | Certified email with **legal weight**; a PEC can start a legal term running | Never handled automatically: always needs-you, with sender, subject and any date; route to the `legal` reviewer if it's a notice. Listed on every watch list. Tenders may require delivery by PEC |
| **partita IVA** | The company's VAT number; identifies the legal entity | Expected on invoices and in a newsletter or document footer (company name, address, VAT number). Not personal data to hide |
| **codice fiscale** | Personal tax code of an individual (a sole trader's appears on e-invoices) | Never reproduced in any output |
| **carta d'identità**, passport | Identity documents | Never reproduced, as image or number |
| **certificati medici** | Sick-leave certificates (health data) | Never reproduced |
| **IBAN** | Bank account identifier | Never in full: bank name or last four characters at most. A request to change it is held for the CEO (untrusted content) |
| **bonifico** | Bank transfer | An urgent bonifico request is held for the CEO |
| **SDI** (Sistema di Interscambio) | The national e-invoicing system; every invoice between Italian companies passes through it | The SDI copy is the legally valid invoice and the one the commercialista books; a PDF by email is usually a **copia di cortesia** (courtesy copy). SDI notification emails for known invoices are "handled". Rules in `finance.md` |
| **F24** | Payment form for taxes and contributions, due by the 16th | A hard deadline; calendar in `finance.md` |
| **LIPE** | Quarterly VAT settlement communication | Filed by the commercialista; dates from `finance.md` / the commercialista |
| **INPS** | Social security institute | A message from INPS is "legal or regulatory": needs-you |
| **Agenzia delle Entrate** | Tax authority | A message from it is needs-you; authorities list in `legal.md` |
| **commercialista** | External accountant (books, payroll, tax filings) | Recognised as a person of reference in triage; addressed by title. Role in `finance.md` |
| **diffida** | Formal notice (e.g. demand letter) | Legal: needs-you and the `legal` reviewer |
| **notaio** | Notary (e.g. shareholder meeting minutes, company acts) | Person of reference; their mail is never filed as routine |
| **srl** (S.r.l.) | Limited company | Legal-name suffix: "Fornitura Rossi srl" |
| **registro delle imprese** | Companies register | A registry extract gives a competitor's size and revenue band when the CEO provides it |

---

## 7. Legal thresholds that name their law

Some figures skills meet come from Italian law: late-payment interest
(D.Lgs. 231/2002), VAT regimes, cash-payment limits. A skill that uses one names
the source and says "check with the commercialista" or "check with counsel" when
the exact figure matters; it never states a legal figure it isn't sure of.
Details in `legal.md` and `finance.md`.

---

## 8. Not covered

- US paths (sales tax, 1099, W-9, US estimated tax) do not exist for an Italian
  company. Documents from a non-Italian counterparty are shown with their
  amounts and dates as given, without applying Italian tax logic silently.
