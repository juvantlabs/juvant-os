---
name: content-creation
description: "Draft marketing content across channels: blog posts, LinkedIn and other social posts, newsletters, landing pages, press releases and case studies. Use when writing any marketing content, when you need channel-specific formatting, search-friendly copy, headline options or calls to action. Produces drafts for the CEO to approve; never publishes or schedules."
---

> Adapted from anthropics/knowledge-work-plugins `marketing/skills/content-creation` at commit e050c2e (Apache-2.0). Modified for juvant-os: voice, claims and product facts come from the manifesto and `memory/knowledge/`; every piece is a draft in `drafts/` that the CEO publishes; EU/Italian notes for newsletters, press releases and testimonials; examples scaled to a small B2B company.

# Content Creation

Guidelines and templates for marketing content across channels. Every piece this
skill produces is a draft. It never publishes, posts, schedules or sends.

## Before writing

1. Read the voice: [voice](../kwp-shared/voice-profile.md) explains where it
   lives (the manifesto's "How we sound" and `memory/knowledge/brand.md`).
2. Read `memory/knowledge/product.md` for facts. Every product claim must be
   supported there or by a source the CEO gives. If a claim you need isn't
   supported, write `[needs proof: …]` instead of inventing a figure.
3. Check `brand.md` for approved claims, claims never used, name spellings and
   channels; check the manifesto's "What we never do".
4. Language: follow the manifesto (for example Italian for an Italian audience,
   English otherwise). Numbers and dates per
   [currency and locale](../kwp-shared/currency-and-locale.md).
5. If a campaign plan exists in `drafts/` for this piece, follow its messages and
   calendar.

## Where the draft goes

Write each piece to `drafts/<channel>-<short-title>-YYYY-MM-DD.md`, with any
headline options, meta description and notes for the CEO at the top, clearly
separated from the copy. Tell the CEO it's ready for review and that publishing
is theirs to do. If the piece names a customer, quotes someone or uses a
comparative claim, say it needs a check (consent, `legal` reviewer) before it goes
out; `brand-review` can run the full check.

## Content templates

### Blog post
1. **Headline**: clear, benefit-led, includes the main keyword (aim for 60
   characters or fewer)
2. **Introduction** (100 to 150 words): a hook (question, figure, scenario),
   then what the post covers. Main keyword included.
3. **Body** (3 to 5 sections): descriptive H2s, H3s for subsections. One idea per
   section, with evidence, an example or data.
4. **Conclusion** (75 to 100 words): key takeaways, the main message again, a
   call to action.
5. **Meta description**: under 160 characters, keyword included, makes people
   want to click.

### Social post
- **Hook**: the first line earns attention (question, clear statement, number)
- **Body**: 2 to 4 short points or a short story
- **Call to action**: what the reader should do next
- **Hashtags**: 3 to 5 where the platform uses them (on LinkedIn, fewer is fine)

### Newsletter
- **Subject line**: under 50 characters, curiosity or clear value
- **Preview text**: complements the subject, doesn't repeat it
- **Header**: one line of value
- **Body**: 2 to 3 blocks, each scannable with a bold first sentence
- **One primary call to action**
- **Footer**: unsubscribe link, company details (name, address, VAT number), links

Send only to people who have consented (GDPR); if the CEO asks about a list whose
origin is unclear, flag it for the `legal` reviewer rather than drafting around it.

### Landing page
- **Headline**: the main benefit in under 10 words
- **Subheadline**: supporting context
- **Hero**: headline, subheadline, primary call to action, an image or short video
- **Value**: 3 to 4 benefit-led sections
- **Social proof**: testimonials, logos, figures, case-study snippets (only with
  the customer's consent)
- **Objections**: FAQ, trust signals (for example where data is processed)
- **Final call to action**: repeat the primary one
- Remind the CEO that a form collecting personal data needs a privacy notice and
  the right consent wording; that text is for the `legal` reviewer, not invented
  here.

### Press release
- **Headline**: factual, newsworthy, under 80 characters
- **Subheadline**: optional context
- **Dateline**: city and date (`Bologna, 14 marzo 2026`)
- **Lead paragraph**: who, what, when, where, why, in 2 to 3 sentences
- **Body**: details, quotes, context
- **Boilerplate**: the standard company description (from `memory/knowledge/` if
  it exists; otherwise draft one and propose adding it there)
- **Press contact**: name, email, phone (from `memory/map.md` or the CEO; never
  invented)

Quotes attributed to the CEO or anyone else are drafts for that person to
approve; mark them `[quote to be approved by …]`.

### Case study
- **Title**: "[Customer] achieves [result] with [product]"
- **Snapshot**: customer, sector, size, product used, key result
- **Challenge**: the problem the customer had
- **Solution**: what was implemented and how
- **Results**: measured outcomes with specific figures
- **Quote**: from the customer
- **Call to action**

A case study needs the customer's written approval of the text and of any
figures. Never use client data from the product (messages, customers' customers)
without the written consent the manifesto and `roles/legal.md` require.

## Writing by channel

### Blog
- Plain language for broad audiences; more technical only when the audience is
- Short paragraphs (2 to 4 sentences); a subheading every 200 to 300 words
- Lists to break up text
- At least one figure, example or quote per section
- Active voice; key information first in each section

### Social
- **LinkedIn**: professional but human; paragraph breaks; stories and lessons
  work; about 1.300 characters is the sweet spot before "see more". Founder
  profiles often reach further than the company page.
- **X**: short and direct; threads for longer stories.
- **Instagram**: visual first; storytelling hooks; line breaks.
- **Facebook**: conversational; questions invite comments; short link posts.

### Newsletter
- Subject lines with urgency, curiosity or clear value (urgency only when real)
- Personalise where possible (name, company)
- One primary call to action, visually distinct
- Scannable: bold key phrases, short paragraphs
- Suggest tests (subject lines, send time) for the CEO to run
- Mobile first

### Web pages
- Benefits before features
- Speak to the reader ("you"; in Italian, tu or Lei per the brand file)
- Minimal jargon unless the audience expects it
- Every section answers "so what?"
- Less friction: fewer form fields, clear next steps, trust signals near the call
  to action

## Search basics

### Keywords
- One main keyword and 2 to 3 secondary ones per piece, in the language of the
  audience (Italian searches for an Italian audience)
- Main keyword in: headline, first paragraph, one subheading, meta description,
  URL slug
- Secondary keywords where natural
- No keyword stuffing; write for people first

### On-page checklist
- Title tag under 60 characters, main keyword included
- Meta description under 160 characters
- Short descriptive URL slug
- One H1, matching the title
- Descriptive H2/H3s
- Descriptive alt text on images
- 2 to 3 internal links; 1 to 2 links to authoritative sources

### Depth
- Cover the topic fully; answer related questions people actually ask
- Refresh pieces that perform well
- Structure for featured snippets: definitions, numbered lists, tables

## Headlines and hooks

### Headline formulas
- **How to [result] [without obstacle]**: "How to answer customers in minutes without hiring"
- **[Number] ways to [result]**: "5 ways to cut response time for a small support team"
- **Why [common belief] is wrong (and what to do instead)**
- **The [adjective] guide to [topic]**
- **[Do this], not [that]**: "Answer faster, not more"
- **What [result] taught us about [topic]**: "What 10.000 customer emails taught us about tone"
- **[Topic]: what [audience] needs to know in [year]**

### Hooks
- **A figure**: only real ones, with a source
- **A contrarian statement**: "Most small companies don't need a chatbot."
- **A question**: "When did a customer last wait two days for an answer?"
- **A scenario**: "It's Monday, and 40 emails arrived over the weekend."
- **A story**: "Last spring a client of ours was answering the same five questions all day."

Avoid hooks that break the brand's rules (superlatives, overclaiming what the
product does).

## Calls to action

### Principles
- Action verbs: "Book", "Try", "Download", "Read", "Join", "See"
- Say what happens next: "Book a 20-minute demo" beats "Submit"
- Urgency only when genuine (a real date, real limited places)
- Lower the risk where true: "No commitment", "Cancel any time" (only if the
  contract says so; check `product.md`)
- One primary call to action per page or email

### By context
- **Blog**: "Read our guide to [topic]", "Subscribe to the newsletter"
- **Landing page**: "Book a demo", "See pricing"
- **Newsletter**: "Read the full story", "Reply and tell us"
- **Social**: "Tell us in the comments", "Link in the first comment"
- **Case study**: "See how it could work for your team"

### Placement
- Above the fold on landing pages
- After establishing value in emails
- At the end of blog posts, and in-line where relevant
- Repeat the primary call to action at the bottom of long pages
