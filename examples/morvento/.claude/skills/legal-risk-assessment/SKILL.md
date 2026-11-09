---
name: legal-risk-assessment
description: "Assess and classify a legal risk with a severity-by-likelihood matrix and clear escalation rules. Use when evaluating contract or deal exposure, a dispute or threatened claim, a regulator's letter, a data incident, or when deciding whether a matter needs the outside counsel named in roles/legal.md."
---

> Adapted from anthropics/knowledge-work-plugins `legal/skills/legal-risk-assessment` at commit e050c2e (Apache-2.0). Modified for juvant-os: sized for a small company, escalation tied to roles/legal.md and the manifesto, no own risk register, output fitted to the legal reviewer's VERDICT / FINDINGS / NOT CHECKED shape, country-neutral; local rules from the country pack.

# Legal risk assessment

Evaluate, classify and document legal risks with a framework based on severity and likelihood.

**Important**: you assist with legal work; you do not give legal advice and you are not the company's lawyer. Risk assessments must be reviewed by a qualified professional. The framework is a starting point; the company's own risk appetite is in `manifesto.md` and `roles/legal.md`, and those win where they say something different.

## Before you start

Read:
- `roles/legal.md`: positions, checklist, value thresholds, people of reference (outside counsel, DPO or whoever handles data protection).
- `manifesto.md`: what the company will and won't risk; approval thresholds.
- `memory/decisions/`: earlier decisions on the same counterparty or kind of risk.
- `memory/knowledge/` as needed (e.g. `product.md` for what is core to the business).

Work from the facts you were given. Don't fill gaps with assumptions you then rely on; list them under NOT CHECKED.

**Local rules.** If `.claude/country/legal.md` or `country/legal.md` exists, apply its checks and use its terms (authorities, formal court acts, corporate liability regimes, data protection specifics). If neither exists, say which points depend on local law or practice and list them under NOT CHECKED ("to check with local counsel").

## Severity × likelihood

**Severity** (impact if it happens). Percentages are of the relevant contract or deal value; for a company of this size also compare to annual revenue and cash, if the finance role card or the CEO gives you those figures.

| Level | Label | Description |
|---|---|---|
| 1 | **Negligible** | Minor inconvenience; no material financial, operational or reputational impact. |
| 2 | **Low** | Limited impact; small exposure (< 1% of relevant value); minor disruption; no public attention. |
| 3 | **Moderate** | Material exposure (1–5%); noticeable disruption; possible limited public attention. |
| 4 | **High** | Substantial exposure (5–25%); significant disruption; likely public attention; possible regulatory scrutiny (e.g. the data protection authority). |
| 5 | **Critical** | Major exposure (> 25%, or a threat to the company's cash position); fundamental disruption; serious reputational damage; regulatory action likely; possible personal liability of the directors. |

**Likelihood**:

| Level | Label | Description |
|---|---|---|
| 1 | **Remote** | Highly unlikely; no known precedent; needs exceptional circumstances. |
| 2 | **Unlikely** | Could happen but not expected; limited precedent. |
| 3 | **Possible** | May happen; some precedent; triggers are foreseeable. |
| 4 | **Likely** | Probably will happen; clear precedent; triggers are common. |
| 5 | **Almost certain** | Expected; triggers present or imminent. |

**Risk score = severity × likelihood**

| Score | Level |
|---|---|
| 1–4 | **GREEN**: low |
| 5–9 | **YELLOW**: medium |
| 10–15 | **ORANGE**: high |
| 16–25 | **RED**: critical |

```
                    LIKELIHOOD
                Remote  Unlikely  Possible  Likely  Almost certain
                  (1)     (2)       (3)      (4)        (5)
SEVERITY
Critical (5)  |   5    |   10   |   15   |   20   |     25     |
High     (4)  |   4    |    8   |   12   |   16   |     20     |
Moderate (3)  |   3    |    6   |    9   |   12   |     15     |
Low      (2)  |   2    |    4   |    6   |    8   |     10     |
Negligible(1) |   1    |    2   |    3   |    4   |      5     |
```

Give a rationale for each rating. When you are unsure between two levels, pick the higher and say why.

## Levels and recommended actions

You recommend; the CEO decides and the Chief of Staff acts. You never contact counsel, insurers, authorities or the other side yourself.

### GREEN: low (1–4)
Minor, unlikely, within normal operations, with known mitigations.
- **Accept** and proceed with normal controls.
- **Record**: propose a one-line entry for `memory/decisions/` if the CEO accepts it.
- **No escalation.**

Examples: a supplier contract with a minor deviation in a non-critical area; a routine NDA with a known counterparty under our own country's law.

### YELLOW: medium (5–9)
Could happen in foreseeable circumstances; needs attention, not urgency.
- **Mitigate**: negotiate or add controls (give the wording).
- **Owner**: say who should watch it (CEO or a named role).
- **Triggers**: state what would raise the level.
- **Record**: propose the risk, mitigation and rationale for `memory/decisions/`.

Examples: liability cap below our position but negotiable; a supplier processing personal data outside the EU with an unclear transfer mechanism; an upcoming regulatory change affecting a product line; an IP clause broader than we like but common.

### ORANGE: high (10–15)
Significant and with a real chance of happening.
- **Escalate** to the CEO now, with a short memo (format below).
- **Outside counsel**: recommend involving the counsel named in `roles/legal.md`.
- **Mitigation and contingency plan**: what we do to reduce it, and what we do if it happens.
- **Review**: at defined milestones or weekly until it drops.

Examples: uncapped indemnity in a material area; a data processing activity that may breach GDPR unless restructured; a threatened claim from a significant client; an IP infringement allegation with some basis; a letter or inspection request from an authority (data protection, tax, financial police, labour inspectorate; the country pack names them).

### RED: critical (16–25)
Severe and likely or certain.
- **Immediate escalation** to the CEO, before anything else is signed, sent or deleted.
- **Outside counsel now**: name them from the role card.
- **Insurance**: recommend checking whether a policy (e.g. professional or cyber liability) requires notice, and its deadline.
- **Preserve evidence**: recommend that nothing related is deleted (mail, files, logs) until counsel says otherwise.
- **Mandatory notices**: flag any legal deadline, e.g. under GDPR a personal data breach must be notified to the supervisory authority within 72 hours of becoming aware of it, unless unlikely to result in a risk (art. 33); affected people without undue delay if high risk (art. 34). Outside GDPR, use the local deadline from the country pack, or list it under NOT CHECKED. Draft the notice for the CEO if asked; never file it.
- **Accountant**: if tax or contributions are involved, the external accountant must be told.

Examples: a lawsuit or injunction served (the country pack names the local formal acts); a personal data breach; an enforcement action; a material contract breach by or against us; a credible IP claim against our core product.

## Memo format

Use this for ORANGE and RED, or when asked for a formal assessment. If a durable document is wanted, write it to `drafts/risk-<matter>.md`.

```
## Legal risk assessment

**Date**: [date]
**Matter**: [what is being assessed]
**Confidential**: yes

### 1. Risk
[Clear, short description]

### 2. Background
[Facts, history, business context; source of each fact]

### 3. Analysis
**Severity**: [1–5, label] — [rationale: exposure, operational impact, reputation]
**Likelihood**: [1–5, label] — [rationale: precedent, triggers, current conditions]
**Score**: [n] — [GREEN/YELLOW/ORANGE/RED]

### 4. Contributing factors
### 5. Mitigating factors

### 6. Options
| Option | Effectiveness | Cost/effort | Recommended? |
|---|---|---|---|

### 7. Recommendation
[Course of action and why]

### 8. Residual risk
[Expected level after mitigation]

### 9. Monitoring
[What to watch; events that trigger reassessment]

### 10. Next steps
1. [Action — who (CEO, counsel, external accountant, Chief of Staff) — by when]
```

## Risk record

There is no separate risk register. When the CEO accepts or mitigates a risk, propose an entry for `memory/decisions/` with: date, description, category (contract, regulatory, dispute, IP, data protection, employment, corporate, tax), severity, likelihood, score, level, owner, mitigations, status (open / mitigated / accepted / closed), next review date. Don't write it yourself unless asked.

## When to involve outside counsel

Start from "People of reference" in `roles/legal.md`; the role card may set value thresholds (e.g. anything above a given amount).

**Always**
- Any lawsuit, injunction or formal claim by or against the company.
- Any inquiry, inspection or request from an authority or law enforcement.
- Any possible criminal exposure for the company or its people (including any corporate criminal or administrative liability regime of the entity; the country pack names it).
- Matters that need a shareholders' or board decision.

**Strongly recommended**
- New or unsettled legal questions.
- Foreign law or several jurisdictions.
- Exposure above the company's tolerance or the role card's thresholds.
- Specialist areas (antitrust, patents, employment litigation, tax disputes).
- New regulation that requires changing how we operate.
- Acquisitions, investments, sale of the company.

**Consider**
- Contract disputes with important counterparties.
- Employment matters (dismissals, discrimination or harassment claims, whistleblowing).
- Data incidents that may require notification.
- IP disputes, sent or received.
- Insurance coverage disputes.

If no suitable counsel is in the role card, say what expertise is needed (subject, jurisdiction, industry), that conflicts must be cleared, and that fees should be agreed up front; the CEO chooses.

## Output

```
VERDICT: OK | CHANGES | STOP
(STOP = do not sign or send before the CEO has read this)

FINDINGS
1. [high|medium|low] <risk or clause> — <the problem, with severity × likelihood = score, level> — <the mitigation you propose, as text or action>
...

NOT CHECKED
<facts you don't have, documents you didn't see, foreign law, figures (revenue, cash, insurance cover) you couldn't confirm>
```

Mapping: any RED or ORANGE → STOP; YELLOW → CHANGES; only GREEN → OK. RED/ORANGE findings are high, YELLOW medium, GREEN low. Most important first. Put the memo (if any) below the three blocks.

Always remind the reader that the assessment must be reviewed by qualified counsel before being relied on.
