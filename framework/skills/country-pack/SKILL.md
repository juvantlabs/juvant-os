---
name: country-pack
description: "Draft a country pack (the local legal, fiscal, marketing and format rules the skills apply) for a country juvant-os doesn't ship one for. Use in the first session when .claude/juvant-os.json names a country with country_pack none, or when the CEO asks for local rules for a new country."
---

# Draft a country pack

The skills carry the method and stay country-neutral. Local rules come from a **country pack**: four files the skills read when they exist.

| File | What it holds |
|---|---|
| `legal.md` | Contract law checks (unfair or one-sided standard terms and how they must be approved, statutory payment terms and late-payment interest, limits on excluding liability, penalties, renewal and termination notice, courts and mediation), data protection specifics beyond the GDPR or its local equivalent, corporate liability regimes, the authorities |
| `finance.md` | Taxes and recurring obligations with their calendar, the e-invoicing system if any, statutory accounts and standards, payroll items, the external accountant's role, withholding taxes and duties |
| `marketing.md` | Consent for direct marketing, opt-out registers, consumer protection, advertising rules, contests and prize promotions |
| `locale.md` | Currency, number, date and time formats, business language and register, public holidays, the names of common company documents and identifiers |

Packs shipped with the framework are in `.claude/country/` (see `framework/countries/` upstream for the list). A pack you draft lives in the company's own `country/` folder.

## Steps

1. Tell the CEO what a pack is for, and that a drafted pack is a starting point **to be checked by a local lawyer and accountant**, not advice.
2. Look at an existing pack in `.claude/country/` or ask the CEO whether one exists for a neighbouring country: follow its structure, never its content.
3. Draft the four files in `country/`, from what you know with confidence. For each point you are unsure of, write the question instead of an answer (`- [ ] To verify: …`). Each file starts with:

```
# <Topic> — <Country>

> Country pack drafted with the CEO on <YYYY-MM-DD>. Not verified by a professional yet: every item marked "To verify" must be checked before relying on it.
```

4. Ask the CEO who will verify each file (their lawyer, their accountant) and add that to `memory/map.md` under "People".
5. Record the decision with the `decision` skill ("Draft country pack for <country>, to be verified by …").
6. Tell the CEO they can contribute the pack to juvant-os once verified: a pull request adding `framework/countries/<code>/` to `juvantlabs/juvant-os`, with the "Not verified" line replaced by who verified it and when.

Never put secrets, tax identifiers or personal data in a pack.
