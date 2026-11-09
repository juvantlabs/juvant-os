# Output style: how briefs and documents look

> Adapted from anthropics/knowledge-work-plugins `small-business/shared/artifact-style.md` at commit e050c2e (Apache-2.0). Modified for juvant-os: output goes to chat and files in `drafts/` (markdown by default, DOCX/PDF for documents that leave the company, HTML only on request); brand comes from `memory/knowledge/brand.md`; Notion/Canva delivery and onboarding capture removed; the house palette and components are kept, shortened; country-neutral; local rules from the country pack.

**Shared across skills.** One look, so every brief and page a skill produces
reads as the same company's work. These are operating tools for a small company:
legible beats flashy. A ledger, not a landing page.

**Amounts and dates follow `currency-and-locale.md`** (currency, separators and
date order from the country pack's locale file).

---

## Where output goes

**The short answer always lands in chat.** A file is additive, never a
replacement.

| Output | Default form |
|---|---|
| A brief, pulse or digest for the CEO | Chat, plus a markdown file in `drafts/` when the CEO will refer back to it (`drafts/<skill>-YYYY-MM-DD.md`) |
| A document that leaves the company (proposal, offer, letter) | Markdown in `drafts/` as the working copy, plus DOCX and/or PDF when the CEO asks or the skill says so |
| A message to someone | An Outlook draft through the Microsoft 365 connector, or `drafts/<name>.md` when the connector isn't available |
| A visual page (dashboard, one-page summary) | An HTML file in `drafts/` only when the CEO asks for one |

A one-off request ("give me this as a Word doc") always wins for that run. If
the CEO states a lasting preference, propose adding it to `memory/knowledge/`
rather than remembering it privately.

**One deliverable, one copy.** Do not hand over the same content twice in
different wrappers (an HTML page and an identical markdown file). The only file
that ships next to another is a genuinely different format the skill promises
(a DOCX for editing next to the PDF for sending).

Nothing in `drafts/` is published, uploaded or sent by the skill.

---

## Markdown conventions

- One `#` title with the page's job and the date, in the CEO's working language
  and the locale's date format: e.g. `# Business pulse, 9 November 2026`.
- Sections as `##`; no deeper than `###`.
- Tables for anything with three or more comparable rows; numbers right-aligned.
- Status words, not emoji, as the primary signal: **OK**, **Review**,
  **Critical**. Emoji may be added as a secondary cue only if the CEO likes them.
- A closing line naming sources used and sources unavailable.

---

## Brand tokens (HTML, DOCX, PDF)

When `memory/knowledge/brand.md` gives colors, fonts or a logo, use them. When it
doesn't, use the house default below. Components never change; only token values
do.

```css
:root {
  --ink: #17211F;  --paper: #F4F3EE;  --paper-raised: #FFFFFF;  --line: #DEDCD1;
  --accent: #0B6B5C;  --accent-soft: #E4EFEC;
  /* Semantic: never repurposed for branding */
  --good: #2E7D4F;  --good-soft: #E4F0E8;
  --warn: #B9781F;  --warn-soft: #F6EBDA;
  --critical: #B3392C;  --critical-soft: #FBEAE7;
  --font-display: Georgia, 'Times New Roman', serif;
  --font-body: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  --font-mono: 'SF Mono', Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --ink: #EDEAE2;  --paper: #14201C;  --paper-raised: #1B2A25;  --line: #2C3A34;
    --accent: #4FBFA5;  --accent-soft: #1E332C;
    --good: #6FCB94;  --good-soft: #1D3226;
    --warn: #E0A559;  --warn-soft: #362A16;
    --critical: #E37B6B;  --critical-soft: #3A211C;
  }
}
```

Use system or locally available fonts; an HTML file in `drafts/` must not load
anything from the internet.

---

## Components (HTML)

- **Header**: company name, the page's job in one line, generated date. No hero,
  no illustration.
- **Stat tile**: one large number (`--font-mono`, `tabular-nums`) with a
  plain-language context line under it ("About 4 months of fixed costs"). A number
  alone is not an answer.
- **Status tag**: small rectangular tag, uppercase, semantic colors only
  (`good`, `warn`, `critical`).
- **Table**: hairline row dividers, numbers right-aligned in `--font-mono`,
  wrapped in a horizontally scrollable container.
- **Copy block**: for text the CEO will paste elsewhere (a reply, a post). A
  `<pre>` with a Copy button that falls back to selecting the text if the
  clipboard is blocked.
- **Panels**: `--paper-raised` on `--paper`, `1px solid var(--line)`,
  `border-radius: 6px`, stacked with `gap`, max width about 840px.
- **Footer**: small, quiet: which skill produced it and from which sources.

Every component reads colors from tokens, never a literal hex, so light and dark
both work.

---

## DOCX and PDF

- Use the company's own template when `memory/map.md` points to one (for example
  a proposal template in SharePoint). Familiar beats better.
- Otherwise: company name and logo (if in `memory/knowledge/brand.md`) in the
  header, page numbers and document number in the footer, price tables
  right-aligned with the company currency's formatting.

---

## What not to do

- **Do not add marketing copy, heroes or illustrations** to an operating
  document.
- **Do not invent a palette per skill.**
- **Do not render untrusted text as live HTML** (`untrusted-content.md`): escape
  it.
- **Do not let this file grow SKILL.md files.** A skill's delivery step names
  the form and the components, and links here for the rest.
