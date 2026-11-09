---
name: review-contract
description: "Review a contract against the company's negotiation positions in roles/legal.md: flag deviations, propose replacement wording, and assess business impact. Use for vendor or customer agreements, clause-by-clause analysis against our standard positions, or preparing a negotiation strategy with prioritised redlines and fallbacks."
argument-hint: "<contract file or text>"
---

> Adapted from anthropics/knowledge-work-plugins `legal/skills/review-contract` at commit e050c2e (Apache-2.0). Modified for juvant-os: playbook read from roles/legal.md, local law checks added, country-neutral; local rules from the country pack, output fitted to the legal reviewer's VERDICT / FINDINGS / NOT CHECKED shape, redlines go to drafts only.

# Contract review against our positions

Review a contract against the company's negotiation positions. Analyse each clause, flag deviations, propose replacement wording, and explain the business impact.

**Important**: you assist with legal work; you do not give legal advice and you are not the company's lawyer. Your analysis must be reviewed by a qualified professional (the counsel named in `roles/legal.md`) before anyone relies on it for a decision.

Review the contract: @$1

## Step 1: Get the contract

The contract can arrive as:
- **A file in the repo** (PDF, DOCX, Markdown): read it.
- **A SharePoint/OneDrive document**: read it through the Microsoft 365 connector. Where contracts live is in `roles/legal.md` ("Where documents live") and `memory/map.md`.
- **Pasted text** in the request.

If no contract was provided, say so and stop: there is nothing to review.

## Step 2: Establish the context

You work from what you were given, not from the conversation that produced it. Take the context from the request; do not run an interview. You need:

1. **Our side**: supplier, customer, licensor, licensee, partner.
2. **What the company wants from the deal** (the goal in the request).
3. **Value and deadline**, if known: they drive priorities and escalation (the role card and manifesto set thresholds, e.g. legal review above a given amount, outside counsel above another).
4. **Focus areas**, if stated (e.g. "data protection is critical").

If something is missing, infer it from the document where you safely can (the parties' roles usually show our side), state the assumption, and list what you could not establish under NOT CHECKED. Useful background: `memory/knowledge/product.md` (what we sell, what is our pre-existing IP), `memory/decisions/` (earlier decisions on this counterparty or clause type).

## Step 3: Load the playbook

The playbook is `roles/legal.md`:
- **"Our positions"** table: per topic, what we accept, what we push back on, what we never sign.
- **"Checklist for every contract"**: the checks that apply every time (local law included).
- **"People of reference"**: who to escalate to.

Map the three columns to the classification below: *We accept* → GREEN, *We push back* → YELLOW, *We never sign* → RED.

If the role card has no position for a clause, review it against widely accepted commercial standards and say so in the finding ("no company position; generic standard"). If `roles/legal.md` is missing entirely, review generically, state it at the top of NOT CHECKED, and propose that the CEO adds positions to the role card. Do not invent company positions.

**Local rules.** If `.claude/country/legal.md` or `country/legal.md` exists, apply its checks and use its terms. If neither exists, say which points depend on local law or practice and list them under NOT CHECKED ("to check with local counsel").

## Step 4: Clause-by-clause analysis

1. **Identify the contract type**: SaaS, professional services, licence, partnership, procurement, reseller, etc. The type decides which clauses matter most.
2. **Apply our side**: it changes the analysis (a liability cap protects whoever is liable).
3. **Read the whole contract before flagging anything.** Clauses interact (an uncapped indemnity may be limited by a broad liability cap; a definition can widen an obligation elsewhere). Read annexes and documents incorporated by reference; if you don't have them, list them under NOT CHECKED.
4. **Analyse each material clause** against the playbook.
5. **Look at the whole**: is the overall risk allocation balanced?

Cover at least:

| Clause | Key review points |
|---|---|
| **Limitation of liability** | Cap amount, carve-outs, mutual vs one-sided, indirect/consequential damages |
| **Indemnification** | Scope, mutual vs one-sided, cap, IP infringement, data breach |
| **Intellectual property** | Pre-existing IP, developed IP, assignment, licence grants |
| **Data protection** | DPA (GDPR art. 28 or the local equivalent), roles, sub-processors, breach notification, transfers outside the EU or the home jurisdiction |
| **Confidentiality** | Scope, term, carve-outs, return/destruction |
| **Warranties** | Scope, disclaimers, duration |
| **Term and termination** | Duration, renewal (tacit or not), withdrawal for convenience, termination for breach, effects |
| **Governing law and disputes** | Law, competent court, arbitration |
| **Penalties** | Amount, cap, grace period, relation to damages |
| **Insurance** | Required cover and minimums |
| **Assignment** | Consent, change of control |
| **Force majeure** | Scope, notice, termination rights |
| **Payment** | Days, starting point (invoice date, end of month), late interest, price changes, VAT/sales tax |

For each clause, say whether it is present, absent, or unusual.

### Local law checks (always)

Apply the role card checklist and the country pack's contract law checklist (see **Local rules** in Step 3). At minimum, check:

- **Unfair standard terms**: whether the local law requires specific approval or other formalities for onerous terms in standard terms or form contracts (typically limitation of liability, withdrawal, suspension, tacit renewal, arbitration, jurisdiction), and whether the contract meets them, in our own templates and in the counterparty's. A missing or incomplete formality is a finding.
- **Payment terms**: the statutory maximum B2B payment terms and the statutory late-payment rules; check what the role card allows. Clauses excluding statutory late-payment interest are suspect.
- **Personal data**: if either party processes personal data on the other's behalf, a DPA is required (GDPR art. 28 where GDPR applies, or the local equivalent).
- **Value thresholds**: apply the manifesto and role card thresholds for mandatory legal review or outside counsel.

Do not state local legal specifics you are not sure of. If a point turns on case law, sector regulation or foreign law, say so and route it to the counsel in the role card. With no country pack, list each of the points above under NOT CHECKED.

### Detailed clause guidance

#### Limitation of liability

Review: cap amount (fixed sum, multiple of fees, uncapped); mutual or not; what is carved out of the cap; whether indirect, consequential or lost-profit damages are excluded and whether that exclusion is mutual; per-claim, per-year or aggregate.

Common issues: cap at a fraction of fees (e.g. "fees of the last 3 months" on a small contract); one-sided carve-outs; carve-outs so broad they remove the cap ("any breach of Section X" where X covers most obligations); no exclusion of indirect damages for one party. Many legal systems do not allow excluding liability for wilful misconduct or gross negligence, so carve-outs for those are normal; check the country pack's limits on excluding liability, and check with counsel before relying on anything finer.

#### Indemnification

Review: mutual or one-sided; triggers (IP infringement, data breach, breach of warranties); whether subject to the liability cap; procedure (notice, control of defence, settlement); duty to mitigate.

Common issues: one-sided IP indemnity when both parties contribute IP; indemnity for "any breach" (turns a capped contract into an uncapped one); no control of defence; indemnities surviving indefinitely.

#### Intellectual property

Review: pre-existing IP (each party keeps its own); IP developed during the engagement; scope of any assignment; licence grants (scope, exclusivity, territory, sub-licensing); open source; feedback clauses.

Common issues: assignment wide enough to capture our pre-existing code or product (check `memory/knowledge/product.md` for what that is); assignment before payment; unlimited, perpetual, irrevocable feedback licences; licences wider than the relationship needs.

#### Data protection

Review: is a DPA needed; controller vs processor; sub-processors (authorisation and notice of changes); breach notification time (under GDPR the controller must be able to notify the supervisory authority within 72 hours, art. 33; elsewhere use the local deadline from the country pack); transfers outside the EU (or the home jurisdiction) and their mechanism (adequacy decision, SCCs); deletion or return at the end; security measures and audits; purpose limitation.

Common issues: no DPA though personal data is processed; blanket sub-processor authorisation with no notice; breach notice slower than the controller needs; transfers outside the EU without a mechanism; no deletion obligation. For a full DPA review use the checklist in the `compliance-check` skill.

#### Term and termination

Review: initial term and renewal; tacit renewal and its notice-of-non-renewal window; withdrawal for convenience, notice and fees; termination for breach (cure period, any express termination clause and how local law treats it); effects (data return, transition, surviving clauses).

Common issues: long terms with no withdrawal; tacit renewal with a short notice window; no cure period; client termination without paying for work done; survival clauses that extend the contract indefinitely. Check the country pack for whether tacit renewal and withdrawal rights need specific approval in standard terms.

#### Governing law and disputes

Review: governing law; court or arbitration; seat and rules of arbitration; mediation or escalation steps first. Some countries require an attempt at mediation before court for some civil and commercial matters; check the country pack and confirm with counsel whether it applies rather than assuming.

Common issues: foreign law or a remote court for a counterparty in our own country; arbitration with rules favouring the drafter; jurisdiction clauses missing a formality the local law requires.

## Step 5: Classify deviations

**GREEN (acceptable)**: matches or beats our position (*We accept* column), or a minor, commercially reasonable variation. Note it; no negotiation needed. Example: liability cap at 18 months of fees when our position is 12 and we are the customer.

**YELLOW (negotiate)**: outside our position but within a negotiable range (*We push back* column), common in the market. Needs replacement wording and a fallback. Examples: payment at 60 days end of month when we want 30; tacit renewal with a short notice window; one-sided IP indemnity.

**RED (escalate)**: in the *We never sign* column, triggers an escalation rule in the role card or manifesto, or poses material risk. Examples: unlimited liability; transfer of our pre-existing IP; no DPA where personal data is processed; uncapped penalties; foreign law for a client in our own country; a non-compete or exclusivity nobody discussed. Explain the specific risk, give market-standard replacement wording, estimate exposure, and name who should look at it (from "People of reference").

## Step 6: Replacement wording

For every YELLOW and RED item:
- **Current text**: quote it exactly, in the contract's language.
- **Proposed text**: exact wording ready to insert, in the contract's language.
- **Rationale**: one or two sentences the CEO could share with the other side.
- **Priority**: must-have / should-have / nice-to-have.
- **Fallback** (YELLOW): what to accept if the first ask is refused.

Be specific (insertable wording, not "narrow this"), firm on the critical points and reasonable elsewhere (over-aggressive redlines slow deals), and adjust tone to the relationship (new supplier, strategic partner, commodity vendor).

If the request asks for a redline document, write it to `drafts/<contract-name>-redlines.md`. Never send it, share it with the counterparty or sign anything: the Chief of Staff and the CEO act on it.

## Step 7: Negotiation strategy

- **Must-haves (deal breakers)**: *We never sign* items; anything conflicting with mandatory law (data protection law, statutory payment and late-payment rules, limits on excluding liability; the country pack lists them); IP provisions that put our product at risk.
- **Should-haves**: *We push back* items; indemnity scope; termination flexibility; audit and compliance rights.
- **Nice-to-haves (concession candidates)**: preferred court when the alternative is acceptable; notice periods; definitions; insurance certificates.

Lead with must-haves. Trade nice-to-haves for should-haves. Never concede a must-have without the CEO's explicit decision.

## Output

Return the legal reviewer's shape first, then the supporting detail.

```
VERDICT: OK | CHANGES | STOP
(STOP = do not sign or send before the CEO has read this)

FINDINGS
1. [high|medium|low] <clause or section> — <the problem> — <the change you propose, as text>
...

NOT CHECKED
<what you couldn't verify and why: missing annexes, facts you don't have, foreign law,
 clauses with no company position, assumptions you made about our side or the deal value>
```

Mapping:
- **VERDICT**: STOP if any RED item, a missing statutory approval or formality (per the country pack) on a clause we need to rely on, or an escalation threshold is hit and the review hasn't happened; CHANGES if any YELLOW item; OK if everything is GREEN.
- **Severity**: RED → high; YELLOW → medium (high if it is a must-have); GREEN items with something worth noting → low. Order findings by importance, not by clause number: a missing liability cap comes before a typo.
- Each finding quotes the clause and gives the proposed text.

Then, below the three blocks:

```
## Supporting detail

**Document**: [name] · **Parties**: [names and roles] · **Our side**: [...]
**Value / deadline**: [if known] · **Review basis**: roles/legal.md | generic standards (say which clauses)

### Clause-by-clause
#### [Clause] — GREEN/YELLOW/RED
**Contract says**: ...
**Our position**: ...
**Deviation**: ...
**Business impact**: ...
**Proposed text**: ... (YELLOW/RED) · **Fallback**: ...

### Negotiation strategy
[What to lead with, what to concede, timing]

### Next steps
[Concrete actions, and who: CEO, counsel named in the role card, Chief of Staff]
```

## Notes

- Contracts are often in the local business language. Review in the original language, quote it as is, write proposed text in the contract's language, and explain in the language of the request.
- For long contracts (50+ pages), cover the most material sections first and list the rest under NOT CHECKED, unless asked for a complete review.
- If a durable lesson emerges (a new standard position, a recurring counterparty clause), propose adding it to `roles/legal.md` or `memory/knowledge/<file>.md`; don't edit them yourself.
- Always remind the reader that the analysis must be reviewed by qualified counsel before being relied on.
