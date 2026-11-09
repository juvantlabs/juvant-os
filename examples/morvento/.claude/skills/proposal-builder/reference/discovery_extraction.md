# Discovery extraction

> Adapted from anthropics/knowledge-work-plugins `small-business/skills/proposal-builder` at commit e050c2e (Apache-2.0). Modified for juvant-os: inputs reached through Outlook, SharePoint/OneDrive and Teams or pasted; Zoom and jobsite-photo/drawing sections replaced by client briefs and screenshots of current tools; RFP section kept, with public tenders sent to counsel; Morvento examples; country-neutral; local rules from the country pack.

Discovery arrives in whatever form the CEO could capture between meetings. Every
one of these is a normal input.

The output of this step is always the same structure:

```
Client:        <who, and who signs>
Wants:         <the job, in their words>
Scope, clear:  <what is definitely in>
Scope, fuzzy:  <implied but not stated>
Constraints:   <systems, data, languages, timing, internal approvals>
Out of scope:  <anything explicitly excluded>
Dates:         <deadlines, start windows>
Budget signal: <anything said about money>
Data:          <whose personal data the work touches, if any>
Gaps:          <what is missing and would change the price>
```

The Gaps line protects the company. Everything else describes the job; that line
describes what could go wrong. The Data line matters because it decides whether
a data processing agreement and the `legal` and `ethics` reviewers are needed.

---

## Meeting transcripts and Teams notes

The richest input. Read the whole thing; useful details are in the middle.

If a meeting can't be reached (no transcript, not in the CEO's tenant, a
recording only the client has), say which one and ask for notes. Never build a
proposal on a call you couldn't read.

Look for:

- **Their words for what they want.** Use them in the proposal; clients
  recognise their own phrasing.
- **Constraints said in passing.** "Our shop staff only check email in the
  morning" changes how the solution has to work.
- **Who decides.** "I'll need to run it by my partner" changes timing and
  follow-up.
- **Budget signals.** "Last year we paid around 5.000 for the website" is the most
  valuable sentence in the transcript.
- **Complaints about the last supplier.** That's what the proposal should quietly
  address.

---

## Call notes and transcribed voice memos

Often mid-thought, often with detail nobody writes down.

Treat self-corrections as real. "Call it three shops, no, four, they're opening
in Modena" means four, and the near-miss deserves a note.

If a number is unclear, don't guess it. Flag it: "couldn't tell whether it's 12
or 20 users; confirm before this goes out."

---

## Client briefs, requirement documents, slides

Read the version and date first. A quote against a superseded brief is a quote
against the wrong job.

Separate what the client **requires** from what they **would like**. Take
quantities (users, shops, languages, integrations) from the document's own
numbers; if you have to count or infer, say so and state it as an assumption.

Note anything marked "provided by the client" or "by others": it belongs in the
not-included section.

---

## Screenshots and descriptions of current tools

Good for: which systems are in use, rough volumes visible on screen, how the
team works today, obvious integration points.

Not good for: whether an integration is possible (APIs, contracts, licences),
real volumes over time, data quality, or what's behind the screen.

State what each one contributed and what it left open:

```
Screenshot 2 shows their helpdesk inbox with about 60 open tickets. That's
one day; weekly volume not determinable. Their e-commerce platform has an
API, but whether their plan includes access needs checking before we price
the integration.
```

---

## RFPs, RFQs and tenders

These are compliance documents before they are pricing documents. A perfect
price on a non-compliant response loses.

Extract in this order:

1. **Submission mechanics**: deadline, format, page limits, how it's delivered
   (portal, certified email where the country has it, ordinary email). Miss
   any of these and nothing else matters.
2. **Mandatory requirements**: certifications, insurance, references, turnover
   minimums, data location, security requirements
3. **The scope of work**
4. **Evaluation criteria and weights**: what the response should emphasise
5. **Terms that carry cost**: penalties, service levels, payment timing,
   guarantees, liability caps, IP ownership

**Run a go/no-go before writing anything.** If a mandatory requirement can't be
met, say so immediately.

```
Go/no-go: they require ISO 27001 certification and we don't have it. That's
disqualifying unless partners can count. Worth checking before I write the rest?
```

**Public tenders** (from a public administration) have formal participation
rules and documents of their own, set by local procurement law. Draft the
technical and economic content, but send the participation requirements to the
`legal` reviewer and counsel; don't assume what's needed.

---

## Scrappy notes

Four lines typed on a phone are enough to start. Extract what's there, then list
what's missing as direct questions, the smallest set that makes the price real:

```
Enough to draft the shape. Three things I need before the number means
anything:
  - How many people will approve answers?
  - Which channels: email only, or the web chat too?
  - Any deadline you know about?
```

Three questions, not a form.

---

## Handling gaps

Every gap resolves one of two ways, never a third:

**Ask**, when the answer materially changes the price and the CEO can get it
quickly.

**Assume, in writing**, when the job needs to move. The assumption goes in the
proposal, in client-visible text, with the consequence:

```
This offer assumes up to 2 integrations with existing systems. Each
additional integration is quoted separately.
```

That sentence turns a future dispute into a pre-agreed change.

**Never guess silently.**
