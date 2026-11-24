# Legal — Italy

> Country pack for juvant-os. Facts to verify with a professional before relying on them; last reviewed 2026-11-09.

Used by the legal skills (`review-contract`, `triage-nda`, `legal-risk-assessment`, `compliance-check`, `vendor-check`). Each section is a checklist the skill applies on top of its own method. Where a point is marked "check with counsel", the skill must not state it as settled: it routes it to the counsel named in `roles/legal.md`.

Direct-marketing, consumer and advertising rules are in `marketing.md`.

## Terms the skills will meet

| Neutral concept | Italian term |
|---|---|
| Civil code | codice civile (c.c.) |
| Withdrawal for convenience | recesso |
| Notice of non-renewal | disdetta |
| Express termination clause | clausola risolutiva espressa (art. 1456 c.c.) |
| Penalty clause | clausola penale |
| Specific written approval of unfair standard terms | approvazione specifica per iscritto (artt. 1341–1342 c.c.) |
| NDA | accordo di riservatezza |
| Directors | amministratori |
| Writ of summons | atto di citazione |
| Payment order (injunction) | decreto ingiuntivo |
| External accountant | commercialista |
| VAT number (identifies the legal entity) | partita IVA |
| VAT | IVA |
| Limited company suffix | S.r.l. (e.g. "Rossi Software S.r.l.") |
| Data protection authority | Garante per la protezione dei dati personali ("the Garante") |

Contracts and NDAs are often in Italian: review in the original language, quote it as is, write proposed text in the contract's language, explain in the language of the request.

## Contract law checklist (review-contract, triage-nda, vendor-check)

Apply on every contract, together with the role card checklist.

### 1. Unfair standard terms: specific written approval (artt. 1341–1342 c.c.)
- [ ] When one party's standard terms or a form contract impose terms such as **limitation of liability, withdrawal (recesso), suspension, tacit renewal, limits on raising defences, restrictions on contractual freedom with third parties, arbitration clauses or derogations from court jurisdiction**, they need specific written approval.
- [ ] Check that the specific-approval block exists and lists every such clause, **in our own templates and in the counterparty's**. A missing or incomplete block is a finding.
- [ ] Tacit renewal and withdrawal rights are among the terms that need specific approval.
- [ ] Jurisdiction clauses without specific approval are a common issue.
- [ ] NDAs: if the NDA is the counterparty's standard form and contains a jurisdiction clause, tacit renewal, arbitration or limits on our rights, the specific-approval block should list them.
- [ ] Vendor status: clauses needing specific approval in a supplier's standard terms with no signed approval block, where we rely on our position (e.g. jurisdiction, tacit renewal), are a gap finding.
- [ ] **Verdict impact** (review-contract): a missing specific approval on a clause we need to rely on → STOP.
- [ ] Whether a penalty clause in standard terms needs specific approval is a question for counsel.

### 2. Payment terms and late-payment interest (D.Lgs. 231/2002)
- [ ] B2B payment terms over **60 days** need to be expressly agreed and not grossly unfair; check what the role card allows.
- [ ] Statutory late-payment interest runs by law; clauses excluding it are suspect.
- [ ] Check the starting point of the term (invoice date, end of month) and how IVA is treated.
- [ ] A term conflicting with D.Lgs. 231/2002 is a must-have (mandatory law), not a concession.

### 3. Limits on excluding liability (art. 1229 c.c.)
- [ ] Clauses excluding or limiting liability for **wilful misconduct (dolo) or gross negligence (colpa grave)** are not valid; carve-outs from the cap for those are therefore normal.
- [ ] Nullity under art. 1229 c.c. is a must-have point in negotiation.
- [ ] Check with counsel before relying on anything finer.

### 4. Termination and renewal
- [ ] **Express termination clause** (art. 1456 c.c.): check whether there is one and which breaches it lists.
- [ ] **Tacit renewal**: identify the notice (disdetta) window and compute the last day to give notice as a date; for tacit renewals that date matters, not the end date.
- [ ] Withdrawal (recesso) for convenience: notice and fees.
- [ ] Both tacit renewal and withdrawal need specific approval in standard terms (see 1).

### 5. Penalties (clausola penale)
- [ ] Italian NDAs and contracts from larger companies often include a penalty; check its amount against the role card's penalty position.
- [ ] A judge can reduce a manifestly excessive penalty (**art. 1384 c.c.**), but don't plan on it.
- [ ] Standard counter-position: prefer deletion; if they insist, a fixed, capped amount within the role card position, mutual, without prejudice to proving lower actual damage.

### 6. Governing law, courts and mediation
- [ ] Default for Italian counterparties: **Italian law and an Italian court** (the court in the role card if it names one).
- [ ] Foreign law or a remote court for an Italian counterparty, or foreign law for an Italian client, is a RED example.
- [ ] For civil and commercial disputes, Italian law requires an **attempt at mediation before court for some matters**; check with counsel whether it applies rather than assuming.

### 7. Mandatory law that is never a concession
- [ ] GDPR and the Privacy Code (see Data protection), D.Lgs. 231/2002 (payment terms), nullity under art. 1229 c.c.

### 8. NDA specifics
- [ ] Permitted disclosures should include our advisers under similar duties, **including the commercialista and the lawyer**.
- [ ] Return-and-destruction retention exception should cover copies kept by law, e.g. **accounting and tax retention** (periods: ask the commercialista).


## Late payment and collection (invoice-chase)

### Statutory late-payment interest (B2B)

- [ ] **D.Lgs. 231/2002** applies to B2B invoices (commercial transactions).
- [ ] Late-payment interest accrues **automatically from the day after the due date**, without a formal notice.
- [ ] A **lump-sum compensation for recovery costs** is also due.
- [ ] The rate is "the rate in force": confirm rate and applicability with counsel or the commercialista before claiming. An estimate may be computed for the CEO from the rate in force.
- [ ] Claiming interest is a relationship decision for the CEO: mention it in the summary (from the firm-reminder step onward), never in a reminder draft unless the CEO asks.

Example (from the firm-reminder example): invoice 2026/079 due 24 September; interest would apply from 25 September if the CEO chooses to claim it.

## Formal notice

- [ ] The last step before court is a formal notice from counsel, the ***diffida*** (formal demand for payment). Counsel drafts it; the finance agent prepares only the handoff note (client legal name and VAT number from the e-invoice, invoices with number, date, due date and amount, contract or order reference, reminders and call with dates, any dispute raised).

## Data protection beyond GDPR (compliance-check, review-contract, legal-risk-assessment)

- [ ] **Privacy Code**: GDPR is complemented in Italy by the Codice in materia di protezione dei dati personali (**D.Lgs. 196/2003, as amended by D.Lgs. 101/2018**).
- [ ] **Supervisory authority**: the Garante per la protezione dei dati personali. Breach notification (GDPR art. 33, within 72 hours of becoming aware) goes to the Garante; answers to data subjects must mention the right to complain to the Garante.
- [ ] **DPIA list**: the Garante publishes a list of processing types that require a DPIA; check it.
- [ ] **Cookies and trackers** on our websites: consent for non-technical cookies, per the Garante's guidelines (details in `marketing.md`).
- [ ] **Employee monitoring**: monitoring of employees' devices or mail is tightly restricted in Italy; flag and route to counsel.
- [ ] **Retention exemptions** for erasure requests: accounting and tax records have mandatory retention periods; ask the commercialista.
- [ ] **Authoritative sources** to verify current guidance: the Garante, the EDPB, official texts.
- [ ] Severity calibration: "possible regulatory scrutiny" for this country means e.g. the Garante.

## Corporate liability regimes (legal-risk-assessment)

- [ ] **Liability of the entity (D.Lgs. 231/2001)**: any possible criminal exposure for the company or its people includes liability of the entity under D.Lgs. 231/2001 → always outside counsel.
- [ ] **Directors' personal liability**: critical-severity risks may involve personal liability of the directors (amministratori).

## Authorities and formal acts (legal-risk-assessment)

A letter, inspection or request from any of these is at least ORANGE and always goes to outside counsel:
- [ ] Garante per la protezione dei dati personali (data protection).
- [ ] Agenzia delle Entrate (tax).
- [ ] Guardia di Finanza (tax and financial police).
- [ ] Labour inspectorate (Ispettorato del lavoro).

Formal acts that make a matter RED (lawsuit or injunction served):
- [ ] Atto di citazione (writ of summons).
- [ ] Decreto ingiuntivo (payment order).

If tax or contributions are involved, the commercialista must be told.

## Counterparty identification (vendor-check)

- [ ] The **partita IVA** (VAT number) identifies the legal entity; use it to tell apart group companies, brands and the Italian branch of a foreign company.
- [ ] Legal name vs brand (e.g. "Rossi Software S.r.l." vs "RossiSoft").
- [ ] **E-invoice exports**: if the CEO provides SDI (Sistema di Interscambio) e-invoice exports, they show whether we actually pay or bill the counterparty and since when; invoiced but no contract on file is a finding. Amounts are the finance reviewer's job.
- [ ] Mail threads to search include disdetta (notice of non-renewal) letters.

## Not placed here

- Thresholds for mandatory legal review or outside counsel are company choices: they stay in `manifesto.md` and `roles/legal.md`, not in the pack.

## Also relevant (from locale.md)

- [ ] A message received by **PEC** (certified email) has legal weight and can start a legal term running: never treat it as ordinary mail, route it to the CEO at once.
- [ ] Cash payments above the statutory limit are not allowed; the limit changes by law, so check the one in force before advising.
