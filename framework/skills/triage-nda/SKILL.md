---
name: triage-nda
description: "Quickly triage an incoming NDA and classify it GREEN (fine to sign as is), YELLOW (small changes needed) or RED (full review, do not sign). Use when a new NDA arrives from a prospect, partner or supplier, when screening for hidden non-solicits, non-competes, penalties or missing carve-outs, or when deciding whether an NDA can go to the CEO for signature as is."
argument-hint: "<NDA file or text>"
---

> Adapted from anthropics/knowledge-work-plugins `legal/skills/triage-nda` at commit e050c2e (Apache-2.0). Modified for juvant-os: screening criteria read from roles/legal.md, local law checks added, country-neutral; local rules from the country pack, output fitted to the legal reviewer's VERDICT / FINDINGS / NOT CHECKED shape, no signature routing.

# NDA triage

Triage the NDA: @$1

Screen an incoming NDA against standard criteria and classify it: fine as is, small changes, or full review.

**Important**: you assist with legal work; you do not give legal advice. This is a screening tool. Items the reader is unsure about should go to the counsel named in `roles/legal.md`.

## Step 1: Get the NDA

From a file in the repo, a SharePoint/OneDrive document read through the Microsoft 365 connector (see `roles/legal.md` "Where documents live" and `memory/map.md`), or pasted text. If no NDA was provided, say so and stop.

## Step 2: Load the criteria

Read `roles/legal.md`. Use any NDA-specific positions it has, plus the general ones that apply (personal data, governing law and courts, penalties, IP). Check `memory/decisions/` for earlier decisions on this counterparty.

Where the role card is silent, use these market defaults and say so in NOT CHECKED:
- Mutual obligations (unless only we are disclosing, or only they are).
- Agreement term 1–3 years; confidentiality surviving 2–5 years; longer only for trade secrets.
- Standard carve-outs: public, already known, independently developed, rightfully received from a third party, required by law.
- No non-solicitation, non-compete or exclusivity.
- No residuals clause, or a narrow one.
- No penalties.
- Our own country's law and courts for counterparties in our own country; the court in the role card if it names one.

**Local rules.** If `.claude/country/legal.md` or `country/legal.md` exists, apply its checks and use its terms (penalty rules, formalities for standard terms, default law and court, advisers who may receive information). If neither exists, say which points depend on local law or practice and list them under NOT CHECKED ("to check with local counsel").

## Step 3: Screen

### 1. Structure
- [ ] **Type**: mutual, one-way (we disclose) or one-way (we receive).
- [ ] **Fits the relationship**: mutual for exploratory talks; one-way only if disclosure really goes one way.
- [ ] **Really an NDA**: a standalone confidentiality agreement, not a commercial contract in disguise.

### 2. Definition of confidential information
- [ ] **Reasonable scope**: not "all information of any kind whether or not marked".
- [ ] **Marking**: if required, workable (written confirmation within ~30 days of oral disclosure is common).
- [ ] **Exclusions present** (see carve-outs).
- [ ] **No problematic inclusions**: public or independently developed information is not defined as confidential.

### 3. Receiving party's obligations
- [ ] **Standard of care**: reasonable care, or the same care used for its own information.
- [ ] **Use**: limited to the stated purpose.
- [ ] **Disclosure**: limited to people who need to know and are bound by similar duties.
- [ ] **Nothing impractical** for a six-person company (e.g. encrypting every communication, physical access logs).

### 4. Standard carve-outs
All should be present:
- [ ] **Public**: public or becomes public through no fault of the recipient.
- [ ] **Already known**: known to the recipient before disclosure.
- [ ] **Independent development**: developed without use of the confidential information.
- [ ] **Third party**: rightfully received from a third party without restriction.
- [ ] **Required by law**: disclosure required by law, regulation, court or authority, with notice to the discloser where allowed.

### 5. Permitted disclosures
- [ ] **Employees** who need to know.
- [ ] **Contractors and advisers** (including our external accountant and lawyer) under similar duties.
- [ ] **Affiliates**, if relevant.
- [ ] **Law and authorities**.

### 6. Term
- [ ] **Agreement term** reasonable (1–3 years).
- [ ] **Survival** reasonable (2–5 years; trade secrets may be longer).
- [ ] **Not perpetual** without a trade-secret reason.

### 7. Return and destruction
- [ ] **Trigger**: on termination or on request.
- [ ] **Scope**: return or destroy information and copies.
- [ ] **Retention exception**: copies kept by law (e.g. accounting and tax retention) or in routine backups.
- [ ] **Certification**: a written confirmation is fine; a sworn statement is onerous.

### 8. Remedies and penalties
- [ ] **Injunctive relief**: acknowledging that urgent court measures may be sought is standard.
- [ ] **No penalty clause** or liquidated damages. NDAs from larger companies often include one; check its amount against the role card's penalty position. Whether a court can reduce an excessive penalty, and whether a penalty in standard terms needs a formality, depends on local law: apply the country pack, and don't plan on a reduction; open questions go to counsel.
- [ ] **Symmetric** in a mutual NDA.

### 9. Problem provisions
- [ ] **No non-solicitation** of employees.
- [ ] **No non-compete**.
- [ ] **No exclusivity** on talking to others.
- [ ] **No standstill** (unless an M&A context).
- [ ] **No residuals clause**, or limited to unaided memory and excluding trade secrets and patentable information.
- [ ] **No IP assignment or licence**.
- [ ] **No audit rights**.

### 10. Personal data
- [ ] If personal data will be exchanged (e.g. client user lists, employee data), the NDA is not enough: a DPA (GDPR art. 28 where GDPR applies, or the local equivalent) or a data-sharing agreement is needed. Flag it.

### 11. Governing law and courts
- [ ] **Law and court** per the role card (for counterparties in our own country: our law and the court the role card names).
- [ ] **Consistent**: law and court in the same jurisdiction.
- [ ] **No mandatory arbitration** in a standard NDA.
- [ ] **Standard-terms formalities**: if the NDA is the counterparty's standard form and contains a jurisdiction clause, tacit renewal, arbitration or limits on our rights, check whether local law requires a specific approval or other formality for them (country pack) and whether it is met.

## Step 4: Classify

### GREEN: fine as is
All true: right type for the relationship; all carve-outs present; term and survival within range; no non-solicit, non-compete or exclusivity; no or narrow residuals; acceptable law and court; no penalties; permitted disclosures include employees, contractors and advisers; retention exception present; reasonable definition.

→ The CEO can sign it as is. You don't sign or route it for signature yourself.

### YELLOW: small changes
One or more, but not fundamentally problematic: definition broader than preferred but not unreasonable; term longer than standard but within market range (e.g. 5-year term, 7-year survival); one missing carve-out easy to add; narrow residuals clause; acceptable but non-preferred court; minor asymmetry; workable marking requirement; no explicit retention exception; unusual but harmless provisions; a modest capped penalty.

→ Propose the exact replacement text; one round of edits should resolve it.

### RED: do not sign
One or more: one-way when it should be mutual (or the wrong direction); missing independent-development or required-by-law carve-out; non-solicit or non-compete; exclusivity or standstill without a business reason; unreasonable term (10+ years, or perpetual without trade-secret justification); definition capturing public or independently developed information; broad residuals clause; hidden IP assignment or licence; uncapped or large penalty; broad audit rights; foreign law or arbitration where the role card says never; personal data exchanged with no DPA; **not really an NDA** (commercial terms, exclusivity, obligations beyond confidentiality: use `review-contract` instead).

→ Do not sign. Propose a counter-draft from our own template (see `roles/legal.md` "Where documents live") or targeted edits, and name who should review (role card "People of reference").

## Output

```
VERDICT: OK | CHANGES | STOP
(STOP = do not sign or send before the CEO has read this)

FINDINGS
1. [high|medium|low] <clause or section> — <the problem> — <the change you propose, as text>
...

NOT CHECKED
<what you couldn't verify and why: missing annexes, the business purpose if not stated,
 whether personal data will be exchanged, criteria taken from market defaults rather than the role card>
```

Mapping: GREEN → OK; YELLOW → CHANGES; RED → STOP. RED items are high, YELLOW items medium, notes low. Quote the clause; give the replacement text in the NDA's language.

Then, below the three blocks:

```
## Screening summary

**Classification**: GREEN / YELLOW / RED
**Parties**: [...] · **Type**: mutual / one-way (we disclose) / one-way (we receive)
**Term / survival**: [...] · **Law and court**: [...]
**Basis**: roles/legal.md | market defaults (say which)

| Criterion | Status | Notes |
|---|---|---|
| Mutuality | PASS/FLAG/FAIL | ... |
| Definition | PASS/FLAG/FAIL | ... |
| Carve-outs | PASS/FLAG/FAIL | ... |
| Term | PASS/FLAG/FAIL | ... |
| Problem provisions | PASS/FLAG/FAIL | ... |
| Penalties | PASS/FLAG/FAIL | ... |
| Personal data | PASS/FLAG/FAIL | ... |
| Law and court | PASS/FLAG/FAIL | ... |

## Next step
[GREEN: ready for the CEO to sign as is. YELLOW: edits above, then back to the CEO.
 RED: counter-draft or counsel review; who and why.]
```

If asked for a marked-up version or a counter-draft, write it to `drafts/<nda-name>.md`. You never send it to the counterparty and never sign.

## Common issues and standard positions

**Overbroad definition.** Limit to non-public information disclosed for the stated purpose that is marked or identified as confidential, or that a reasonable person would understand to be confidential.

**Missing independent development carve-out.** Must be there. Without it, our own later features could be claimed to derive from their information. Add the standard carve-out.

**Employee non-solicitation.** Doesn't belong in an NDA. Delete. If they insist, limit to active targeted solicitation (not general job ads), 12 months at most.

**Broad residuals clause.** Resist. If required: only general ideas and know-how kept in unaided memory of people with authorised access; excludes trade secrets and patentable information; grants no IP licence.

**Perpetual confidentiality.** Replace with 2–5 years from disclosure or termination, whichever is later; offer longer protection only for genuine trade secrets.

**Penalty clause.** Prefer deletion; damages are recoverable anyway. If they insist, a fixed, capped amount within the role card's penalty position, mutual, without prejudice to proving lower actual damage.

## Notes

- If it isn't really an NDA (labelled NDA but with commercial terms), flag it RED immediately and recommend `review-contract`.
- If the confidentiality clause sits inside a larger agreement (e.g. an MSA), say that the wider context may change the analysis.
- NDAs are often in the local business language (the country pack gives the local name). Review in the original language; quote it as is.
- If a recurring pattern emerges (e.g. a client group always sends the same form), propose adding the position to `roles/legal.md`; don't edit it yourself.
- This is screening; counsel should review anything the reader is unsure about.
