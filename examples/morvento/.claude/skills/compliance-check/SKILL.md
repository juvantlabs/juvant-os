---
name: compliance-check
description: "Check a proposed action, product feature, campaign or initiative for compliance: which rules apply, what approvals are needed, what the risks are. Use before launching something that touches personal data, before a marketing or product idea with regulatory implications, when reviewing a DPA, or when a data subject request arrives."
argument-hint: "<action or initiative to check>"
---

> Adapted from anthropics/knowledge-work-plugins `legal/skills/compliance-check` at commit e050c2e (Apache-2.0). Modified for juvant-os: focused on GDPR and Italian rules for a small EU company, US and other-country privacy laws removed, output fitted to the legal reviewer's VERDICT / FINDINGS / NOT CHECKED shape.

# Compliance check

Check a proposed action, product feature, marketing campaign or business initiative: $ARGUMENTS

**Important**: you assist with legal work; you do not give legal advice. Compliance assessments must be reviewed by a qualified professional. Rules and guidance change often; verify current requirements with authoritative sources (the Garante, the EDPB, official texts) or with the counsel named in `roles/legal.md`.

## What you need

A description of what the company plans to do. Good inputs are specific about:
- **The action**: "send a newsletter to all trial users" beats "marketing campaign".
- **Who and where**: business clients or consumers; Italy, EU, outside the EU.
- **The data**: what personal data, whose, from where, kept for how long, shared with whom.

Examples:
- "We want to add a feature that reads client support tickets with an AI model hosted by a US provider."
- "We want to email everyone who downloaded our white paper."
- "We want to use a client's logo and a quote in our case studies."
- "We want to give partners a referral fee."

Read first: `roles/legal.md` (positions, checklist, who handles data protection), `manifesto.md` (what we will and won't do), `memory/knowledge/product.md` (how the product handles data), `memory/map.md` (where our privacy notice, records of processing and DPAs live), `memory/decisions/` (earlier rulings on similar questions). If what you need isn't there, list it under NOT CHECKED; don't invent the company's practice.

## How to check

1. Identify the rules that apply (below).
2. For each, list what it requires and whether it is met, not met, or unknown from what you have.
3. Identify the risks and rate them (high/medium/low; for a full rating use the `legal-risk-assessment` skill).
4. Say what has to happen before going ahead, and who has to approve.
5. If the initiative raises questions of fairness, transparency to users, or use of AI on people's data, recommend the ethics reviewer as well.

## Main rules for a small Italian company

### GDPR and the Italian Privacy Code

GDPR applies to processing of personal data of people in the EU/EEA. In Italy it is complemented by the Privacy Code (D.Lgs. 196/2003, as amended by D.Lgs. 101/2018); the supervisory authority is the Garante per la protezione dei dati personali.

Key obligations:
- **Lawful basis** for each processing activity (consent, contract, legal obligation, legitimate interest, etc.), documented. Legitimate interest needs a balancing test.
- **Transparency**: a privacy notice (informativa, artt. 13–14) at or before collection.
- **Data subject rights**: access, rectification, erasure, restriction, portability, objection; answer within one month, extendable by two further months for complex requests (art. 12(3)).
- **DPIA** (art. 35) for processing likely to result in high risk (e.g. systematic monitoring, large-scale special categories, innovative technology such as AI on personal data). The Garante publishes a list of processing types that require one.
- **Records of processing** (art. 30). The exemption for companies under 250 employees does not apply when processing is not occasional, so most companies need them.
- **Security** (art. 32) and **breach notification**: to the Garante within 72 hours of becoming aware (art. 33), to the people affected without undue delay if high risk (art. 34).
- **Processors**: a DPA under art. 28 with every supplier processing personal data on our behalf, and with every client for whom we process.
- **Transfers outside the EU/EEA**: adequacy decision, SCCs or another valid mechanism (Chapter V).
- **DPO**: required only in specific cases (core activities involving large-scale regular monitoring or special categories). Check the role card for who handles data protection.

Common touchpoints: supplier DPAs, privacy by design for new features, privacy notice updates, cookie banners, direct marketing, responding to the Garante.

### Direct marketing

- Email, SMS and automated calls to individuals generally need prior consent (art. 130 Privacy Code). The narrow exception for existing customers (similar products, email given in a sale, opt-out offered each time) needs checking case by case.
- B2B email to named people at companies is still personal data; check the basis with counsel rather than assuming.
- Telephone marketing: check the Registro pubblico delle opposizioni.
- Cookies and trackers on our websites: consent for non-technical cookies, per the Garante's guidelines.

### Consumers

If the initiative reaches consumers (not only businesses), the Consumer Code (D.Lgs. 206/2005) applies: pre-contract information, withdrawal rights for distance contracts, unfair commercial practices. Flag it and route to counsel; our standard positions are B2B.

### AI

If the initiative uses AI on people's data or makes decisions about people: GDPR art. 22 (automated decisions), a DPIA, transparency, and the EU AI Act (Regulation (EU) 2024/1689), whose obligations depend on the use case and are phasing in. Don't classify the AI Act risk level yourself beyond a first view; mark it for counsel.

### Other areas to flag, not resolve

Employment (monitoring of employees' devices or mail is tightly restricted in Italy), tax and e-invoicing (route to the finance reviewer and the commercialista), advertising claims, competition, sector rules of the client (health, finance, public administration). Data subjects outside the EU (UK, Switzerland, US) may bring their own laws: list them under NOT CHECKED.

## DPA review checklist (GDPR art. 28)

Use this when reviewing a data processing agreement, ours or theirs. Compare with the personal data position in `roles/legal.md`.

### Required content
- [ ] **Subject matter and duration** of the processing.
- [ ] **Nature and purpose**.
- [ ] **Types of personal data**.
- [ ] **Categories of data subjects**.
- [ ] **Controller's obligations and rights**.

### Processor obligations
- [ ] **Only on documented instructions** (except where law requires otherwise).
- [ ] **Confidentiality** of authorised personnel.
- [ ] **Security measures** (art. 32), described.
- [ ] **Sub-processors**:
  - [ ] Prior written authorisation (specific or general).
  - [ ] If general: notice of changes with a right to object.
  - [ ] Same obligations flowed down in writing.
  - [ ] Processor stays liable for sub-processors.
- [ ] **Help with data subject requests**.
- [ ] **Help with security, breach notification, DPIAs, prior consultation**.
- [ ] **Deletion or return** at the end, at the controller's choice, unless law requires retention.
- [ ] **Audits**: controller can audit or accept third-party reports.
- [ ] **Breach notice** to the controller without undue delay (24–48 hours in practice, so the controller can meet 72 hours).

### Transfers outside the EU/EEA
- [ ] **Mechanism identified**: adequacy decision (including the EU–US Data Privacy Framework for certified US companies), SCCs, BCRs.
- [ ] **Current SCCs** (2021 version) and the right module (controller-to-processor, processor-to-processor, etc.).
- [ ] **Transfer impact assessment** where there is no adequacy decision.
- [ ] **Supplementary measures** where the assessment found gaps.
- [ ] **UK addendum** if UK personal data is involved.

### Practical points
- [ ] **Liability** in the DPA consistent with the main contract.
- [ ] **Term** aligned with the main contract.
- [ ] **Processing locations** listed and acceptable (our position may require EU only).
- [ ] **Security standards** (ISO 27001, SOC 2 or equivalent) if required.
- [ ] **Insurance** adequate for the processing.

### Common DPA issues

| Issue | Risk | Standard position |
|---|---|---|
| Blanket sub-processor authorisation, no notice | Loss of control of the chain | Notice with right to object |
| Breach notice later than 72 hours | Controller can't notify in time | 24–48 hours |
| No audit rights, or only reports | Can't verify | Recent certification or report, plus audit for cause |
| No deletion deadline | Data kept indefinitely | Deletion within 30–90 days of the end |
| No processing locations | Data could be anywhere | Locations listed |
| Old SCCs | Invalid transfer mechanism | 2021 SCCs |

## Data subject requests

When a request arrives (usually by mail; read it through the Microsoft 365 connector):

1. **Type**: access, rectification, erasure, restriction, portability, objection, withdrawal of consent.
2. **Our role**: if we are processor for a client, the request goes to the client (controller); we help as the DPA says. If we are controller, we answer.
3. **Identity**: verify proportionately; don't ask for more documents than needed.
4. **Deadline**: one month from receipt (art. 12(3)); extension of two further months only for complex or numerous requests, with reasons given within the first month.
5. **Exemptions**: legal retention (accounting and tax records have mandatory retention periods; ask the commercialista), establishment or defence of legal claims, rights of others, freedom of expression for erasure.
6. **Response**: draft it to `drafts/dsr-<date>.md` or as an Outlook draft through the connector. Include what was done, or the legal basis for refusing in whole or part, and the right to complain to the Garante. The CEO sends it; you never do.
7. **Record**: propose a note for `memory/decisions/` (date, type, deadline, outcome). Don't keep your own log.

## Watching for changes

You don't run monitoring. When a check depends on guidance that may have changed (Garante guidelines, EDPB opinions, AI Act phase-in dates, SCC updates, adequacy decisions), say so under NOT CHECKED and recommend verification with counsel. Escalate to the CEO when a change hits core activities, an authority contacts us, a deadline requires changes to how we work, or a transfer mechanism we rely on is challenged.

## Output

```
VERDICT: OK | CHANGES | STOP
(STOP = do not sign or send before the CEO has read this)

FINDINGS
1. [high|medium|low] <rule or requirement> — <the gap or risk> — <what must change, as text or action>
...

NOT CHECKED
<facts you don't have (data categories, locations, sub-processors), documents not seen,
 non-EU laws, guidance that may have changed, AI Act classification>
```

Mapping: **OK** = proceed; **CHANGES** = proceed with conditions (the findings); **STOP** = requires further review before anything goes live or out (e.g. no lawful basis, no DPA, a transfer without a mechanism, a DPIA needed and not done, consumer rules untested). Most important first.

Then, below the three blocks:

```
## Compliance check: [initiative]

### Rules that apply
| Rule | Why it applies | What it requires |
|---|---|---|

### Requirements
| # | Requirement | Status (met / not met / unknown) | Action |
|---|---|---|---|

### Approvals needed
| Who | Why | Status |
|---|---|---|
| CEO | decides | pending |
| [ethics / finance reviewer, counsel from roles/legal.md, commercialista] | [...] | pending |

### Further review recommended
[Where counsel or a specialist should look, and why]
```

If a durable rule comes out of the check (e.g. "AI features need a DPIA before launch"), propose adding it to `roles/legal.md` or `memory/knowledge/<file>.md`; don't edit them yourself.
