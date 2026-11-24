---
name: vendor-check
description: "Check the status of the company's agreements with a supplier (or client or partner): what is signed, what is missing (NDA, contract, DPA, order forms), and which deadlines are coming. Use when onboarding or renewing a supplier, before a new order with an existing one, or when checking for approaching renewals, notice windows and surviving obligations."
argument-hint: "[vendor name]"
---

> Adapted from anthropics/knowledge-work-plugins `legal/skills/vendor-check` at commit e050c2e (Apache-2.0). Modified for juvant-os: searches SharePoint/OneDrive, Outlook and Teams through the Microsoft 365 connector plus repo files (no CLM or CRM), adds local renewal and DPA checks, output fitted to the legal reviewer's VERDICT / FINDINGS / NOT CHECKED shape, country-neutral; local rules from the country pack.

# Vendor agreement status

Check the status of existing agreements with a counterparty and give one consolidated view of the legal relationship: $ARGUMENTS

**Important**: you assist with legal work; you do not give legal advice. A status report must be checked against the original signed documents by a qualified professional before anyone relies on it.

## Step 1: Identify the counterparty

Take the name from the request. If none was given, say so and stop. Handle variations:
- Legal name vs brand (e.g. "Rossi Software Ltd" vs "RossiSoft").
- Abbreviations and former names.
- Group companies (parent, subsidiaries, local branch of a foreign company). The VAT number or company registration number identifies the entity; use it if you find it.

**Local rules.** If `.claude/country/legal.md` or `country/legal.md` exists, apply its checks and use its terms (entity identifiers, formalities for standard terms, renewal notice terms). If neither exists, say which points depend on local law or practice and list them under NOT CHECKED ("to check with local counsel").

If the name is ambiguous, check all plausible entities and say which you found; list the ambiguity under NOT CHECKED.

## Step 2: Search the sources

Read `roles/legal.md` ("Where documents live") and `memory/map.md` first: they say where contracts are kept. Then search, in this order:

**Repo files**
- `memory/decisions/`: decisions about this counterparty (approvals, accepted deviations, renewals).
- `memory/knowledge/`: any file describing suppliers or the tools we use (e.g. which services process personal data).
- Any contracts or registers in the repo that `memory/map.md` points to.

**SharePoint / OneDrive** (Microsoft 365 connector)
- Signed agreements: contract, general terms accepted, order forms, DPA, NDA, amendments.
- Drafts and redlines in progress.
- Supporting documents: security certifications, insurance certificates.

**Outlook mail** (Microsoft 365 connector)
- Contract-related threads in the last 6 months: negotiations, signed copies sent as attachments, renewal or price-change notices, notices of non-renewal, terms-of-service update notices.

**Teams** (Microsoft 365 connector)
- Recent mentions in the last 3 months: requests involving the counterparty, open questions, problems.

**CEO-provided exports**
- If the CEO provided bank exports or e-invoice exports (from the e-invoicing system, if the country has one), they show whether we actually pay or bill this counterparty and since when. A relationship that is invoiced but has no contract on file is a finding. You don't look into amounts; that is the finance reviewer's job.

Many SaaS suppliers have no signed contract: we accepted their online terms. Then the "agreement" is the version of their terms and DPA in force; record where it is published and whether we kept a copy.

## Step 3: Agreement status

For each agreement found:

| Field | Details |
|---|---|
| **Type** | NDA, contract/MSA, online terms, order form/SOW, DPA, SLA, licence |
| **Status** | Active, expired, in negotiation, awaiting signature |
| **Start date** | |
| **End / renewal date** | |
| **Renewal** | Tacit renewal yes/no; renewal term; notice-of-non-renewal deadline as a date |
| **Key terms** | Liability cap, governing law and court, withdrawal and termination, payment terms |
| **Amendments** | Amendments, addenda, price changes |
| **Where** | Exact location of the signed copy |

Compare key terms with `roles/legal.md` and note deviations briefly; for a full review use `review-contract`.

## Step 4: Gap analysis

```
## Coverage

[OK/MISSING] NDA — [status]
[OK/MISSING] Contract or accepted terms — [status or "not found"]
[OK/MISSING] DPA (GDPR art. 28 or local equivalent) — [status or "not found"]
[OK/MISSING] Order forms / SOWs — [status or "not found"]
[OK/MISSING] SLA — [status or "not found"]
[OK/MISSING] Insurance certificate — [status or "not found", only if required]
```

Flag gaps that the relationship needs:
- **Personal data without a DPA**: if the counterparty processes personal data for us (or we for them) and no DPA is on file, that is a high finding. Check sub-processors and processing locations against our position.
- **Invoiced but no contract**: from CEO-provided exports.
- **Clauses needing a statutory formality** (e.g. specific written approval of onerous standard terms, per the country pack) in their standard terms with no signed approval, where we rely on our position (e.g. jurisdiction, tacit renewal).
- **Expired but still used**: services still paid for under an expired contract.

## Step 5: Deadlines and surviving obligations

- **Within 90 days**: any end date or **notice-of-non-renewal** deadline. Highlight it. For tacit renewals, the date that matters is the last day to give notice, not the end date.
- **Surviving obligations** of expired agreements: confidentiality, indemnities, data deletion or return, non-solicitation.
- Calendar: if a deadline is found, propose that the Chief of Staff adds it to the CEO's Outlook calendar. You don't create events yourself.

## Output

```
VERDICT: OK | CHANGES | STOP
(STOP = do not sign or send before the CEO has read this)

FINDINGS
1. [high|medium|low] <agreement or clause> — <the gap, deviation or deadline> — <the action or text you propose>
...

NOT CHECKED
<sources not searched or not reachable, ambiguous entities, agreements referenced but not found,
 online terms whose version in force you couldn't confirm>
```

Mapping: **STOP** if a new order or renewal is about to be signed and a blocking gap exists (personal data without DPA, a *We never sign* term from the role card in force, no contract at all for a material relationship); **CHANGES** if there are gaps or a deadline within 90 days needing action; **OK** if coverage is complete and nothing is due. Deadlines within 30 days and missing DPAs are high.

Then, below the three blocks:

```
## Vendor agreement status: [name]

**Date**: [today] · **Sources searched**: [list] · **Not reachable**: [list]

### Relationship
**Counterparty**: [legal name, VAT number if found]
**Relationship**: supplier / client / partner
**Personal data involved**: yes / no / unknown

### Agreements
#### [Type] — [status]
- **Start**: [date] · **End**: [date] ([tacit renewal, notice by DATE] / no renewal)
- **Key terms**: [...]
- **Where**: [location]

### Coverage
[Gap analysis block]

### Coming up
- [Deadlines, notice dates]
- [Agreements to put in place]
- [Amendments needed]

### Context
[Relevant mail or Teams threads, with dates]
```

If asked for a follow-up (a request for a DPA, a notice-of-non-renewal letter), write it as a draft: `drafts/<vendor>-<topic>.md` or an Outlook draft through the connector, and tell the Chief of Staff it is ready for the CEO to send. Never send it yourself.

## Notes

- If nothing is found anywhere, say so plainly and note under NOT CHECKED that agreements may be kept somewhere you didn't search; if the CEO names that place, propose adding it to `memory/map.md`.
- For groups, say whether you checked one entity or all.
- Always state which sources were searched and which weren't, so the reader knows how complete the report is.
