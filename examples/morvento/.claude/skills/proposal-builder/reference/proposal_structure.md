# Proposal structure

> Adapted from anthropics/knowledge-work-plugins `small-business/skills/proposal-builder` at commit e050c2e (Apache-2.0). Modified for juvant-os: manifesto rules for proposals, VAT and standard-terms checks, reviewer checkpoints, no e-signature fields; template saving becomes a proposal to the CEO; country-neutral; local rules from the country pack.

Use the company's own template when one exists (`memory/map.md`). This structure
is the fallback, and what to propose as a template if the company has none.

If the manifesto sets a rule for proposals, it overrides this structure.
Morvento's: every proposal opens with one page in plain words (what they get,
when, for how much). In that case sections 2, 3, 6 and 7 are summarised on page
one, and detailed after.

---

## Sections, in order

**1. Header**

Company name and details (name, address, VAT or registration number, as the
locale file says), client name and contact, date, proposal number, validity
date.

**2. What you asked for**

Two or three sentences restating the client's need in their words. Clients scan
for whether the supplier understood the job.

**3. What we'll do**

The scope, in specifics: what is configured, built or delivered, for how many
users, channels or sites, in which languages, in what order. Write it so a
stranger could tell whether it was done. "Set up the assistant" isn't scope.
"Configure Morvento Assist for the shared inbox and web chat of 4 shops, in
two named languages, with 12 user accounts and a half-day training" is.

**4. What's not included**

The most valuable section. Include anything a reasonable client might assume is
covered:

```
Not included:
  - Integrations beyond the two named above
  - Migration of historical messages older than 12 months
  - Changes to the client's website beyond adding the chat widget
  - Auto-replies without approval (available, but configured only on the
    client's written request)
  - Support outside working hours
```

**5. Assumptions**

The conditions the price depends on, in client-visible language, each with what
happens if it turns out otherwise:

```
This offer assumes:
  - Access to the e-commerce platform's API on the client's current plan.
    If an upgrade is needed, its cost is the client's.
  - One contact person on the client's side for the setup weeks.
```

**6. Investment**

Price lines the client recognises as decisions; one-off and recurring amounts
shown separately; net of VAT or sales tax, with the locale file's wording.
Options as labelled tiers, with the recommended one named.

**7. Timeline**

Start window, duration and what it depends on (the client's approvals, access,
third parties). Marked as confirmed by the team, or "indicative, to be confirmed"
until it is. A timeline with no dependencies is a promise the company can't
keep.

**8. Terms**

Payment terms and schedule (from `roles/finance.md`), change process, validity,
reference to the general terms or contract that will govern the work. Data
processing: if the work involves personal data the client controls, say a data
processing agreement (e.g. GDPR art. 28 in the EU) will be signed; the text
comes from the `legal` reviewer, not from here.

**Local rules.** If `.claude/country/legal.md` or `country/legal.md` exists,
apply its checks on standard terms: some countries require the client's
specific written approval of certain clauses in standard terms (for example
limitation of liability, termination, choice of court). If the proposal attaches
the company's general terms with such clauses, flag it for the `legal` reviewer;
don't draft those clauses. If neither file exists, list the point under NOT
CHECKED (to check with local counsel).

**9. Next step**

One sentence, an actual instruction:

```
Reply to confirm and we'll send the order confirmation; setup can start
two weeks later.
```

**10. Acceptance**

Space for the client's acceptance (name, role, date, signature), unless the
company's practice is acceptance by email or a separate contract.

---

## Length

Two to four pages for most proposals. An RFP response goes as long as the RFP
requires. A repeat client for routine work can take one page.

---

## Tone

Match the company's voice ([voice](../../kwp-shared/voice-profile.md)) and the
client's language. If the company's files say nothing about voice, write plain
and neutral and say the proposal is un-voiced.

No padding: no mission statement, no "why choose us" page, no stock photos.
Claims about the product only as `memory/knowledge/product.md` supports them, and
never one the brand file or the manifesto rules out.

---

## Formatting

- Markdown in `drafts/` as the working copy; DOCX for editing and PDF for sending
  when asked
- Company logo and colors from the template or `memory/knowledge/brand.md`
- Price table right-aligned, in the locale's currency format (e.g. `€ 4.550`)
- Page numbers and the proposal number in the footer

---

## Proposing it as a template

If the company had no template and the proposal comes out well, offer once:

```
Want to keep this layout as the standard proposal template? If so, tell me
where it should live and I'll propose the line for memory/map.md.
```
