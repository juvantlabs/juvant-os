---
name: campaign-plan
description: "Generate a full campaign brief with objectives, audience, messaging, channel strategy, content calendar and success metrics. Use when planning a product launch, a lead-generation push or an awareness campaign, when you need a week-by-week content calendar with dependencies, or when turning a marketing goal into a structured plan for the CEO to approve."
argument-hint: "<campaign objective or product>"
---

> Adapted from anthropics/knowledge-work-plugins `marketing/skills/campaign-plan` at commit e050c2e (Apache-2.0). Modified for juvant-os: context comes from the manifesto, `memory/knowledge/` and `roles/finance.md` instead of questions; the plan is a draft in `drafts/` for the CEO to approve; no spend, scheduling or publishing; connector placeholders removed; examples scaled to a small Italian B2B company.

# Campaign Plan

Produce a campaign brief: objectives, audience, messages, channels, content
calendar and success metrics. The brief is a plan for the CEO to approve. Nothing
in it is booked, bought, scheduled or published by this skill.

## Inputs

**Read first, ask only for what's missing:**

- `memory/knowledge/product.md`: what the product does and doesn't do, pricing,
  customers, upcoming releases
- `memory/knowledge/brand.md`: voice, approved claims, claims never used,
  channels the company uses, audience size (for example newsletter subscribers)
- `manifesto.md`: values and "What we never do" (these constrain messages)
- `roles/finance.md`: who approves spending and above what amount
- `memory/decisions/`: past decisions about marketing, budgets or positioning
- past campaign plans or results, if `memory/map.md` points to them

**Then ask the CEO, in one message, only what those files don't answer:**

1. **Goal**: the primary objective (signups, awareness, a launch, leads,
   re-engaging past customers)
2. **Audience**: who it is for (roles, company size, sector, region, buying stage)
3. **Timeline**: duration and fixed dates (launch date, event, seasonal moment)
4. **Budget**: approximate amount or "no paid budget" (optional; without it,
   produce a channel plan and mark where budget would matter)
5. **Anything else**: differentiators, lessons from past campaigns, regions

## Campaign brief structure

### 1. Overview
- Campaign name suggestion
- One-sentence summary
- Primary objective, specific and measurable
- Secondary objectives, if any

### 2. Target audience
- Primary segment, described
- Secondary segment, if any
- Pain points and motivations
- Where they spend time (channels, communities, publications, events)
- Buying stage (awareness, consideration, decision)

### 3. Key messages
- Core message, one sentence
- 3 to 4 supporting messages tied to pain points
- Variations by channel, if tone differs
- Proof points for each message, taken from `product.md` or real customer
  results the company is allowed to cite. A claim without a proof point is marked
  `[needs proof]`, never filled with an invented statistic.

Check every message against `brand.md` claims and the manifesto. A message that
breaks a "never" rule is dropped, not softened.

### 4. Channel strategy
For each recommended channel:
- why it fits the audience and objective
- content formats
- effort (low, medium, high), given a small team
- budget share, if a budget was given

Channels to consider:
- **Owned**: website, blog, newsletter, LinkedIn company page, the founders'
  own profiles
- **Earned**: trade press, partner and association newsletters, guest posts,
  local business events, communities, customer referrals
- **Paid**: search ads, LinkedIn ads, sponsored newsletters, event sponsorships

Start from the channels `brand.md` lists. Propose a new one only with a reason.

### 5. Content calendar
Week by week (day by day for short campaigns):
- what is produced each week
- which channel it targets
- milestones and deadlines
- dependencies ("landing page live before any paid ad starts")
- who prepares it and who approves it (the CEO approves anything public)

| Week | Content piece | Channel | Owner / notes | Status |
|---|---|---|---|---|

Status starts as "to draft". The calendar is a plan: this skill does not
schedule posts or emails.

### 6. Content pieces needed
For each asset:
- name and type (post, newsletter, landing page, case study, slide, ad)
- what it should contain
- priority (must-have or nice-to-have)
- when it must be ready

### 7. Success metrics
- Primary KPI with a target
- 3 to 5 secondary KPIs
- how each is tracked (website analytics, newsletter tool reports, LinkedIn
  page analytics, replies in Outlook, the CEO's pipeline notes), and who reads it
- reporting rhythm

Base targets on past results if the company has them in `memory/` or files the CEO
provides; otherwise say they are first-time estimates.

### 8. Budget allocation (if a budget was given)
- by channel or activity
- production versus distribution costs
- contingency (typically 10 to 15%)
- amounts in euro, per [currency and locale](../kwp-shared/currency-and-locale.md),
  stating whether VAT is included
- which items need CEO approval under `roles/finance.md` (for example anything
  over the approval threshold, or any recurring cost)

This is a proposal. The skill never commits, books or changes a budget.

### 9. Risks and mitigations
- 2 to 3 risks (timeline, audience mismatch, a channel that underperforms, a team
  too small for the calendar)
- a mitigation for each

### 10. Next steps
- immediate actions to start
- approvals needed from the CEO (budget, messages, anything public)
- reviews by the `legal` reviewer (comparative claims, testimonials, personal
  data in the campaign, contests or prize promotions, which have specific rules in
  Italy) or the `ethics` reviewer where the manifesto calls for it
- key decision points

## Planning reference

### Five parts: objective, audience, message, channel, measure

#### Objective
Define success before planning anything.

- **Awareness**: visibility (reach, impressions, share of voice)
- **Consideration**: engagement and education (content engagement, newsletter
  signups, webinar attendance)
- **Conversion**: leads or sales (demo requests, trials, signed contracts)
- **Retention**: existing customers (renewals, upsell, satisfaction)
- **Advocacy**: customers as promoters (referrals, reviews, case studies)

SMART: specific, measurable, achievable, relevant, time-bound.

Example: "30 demo requests from retail and services companies with 5 to 50
employees in Emilia-Romagna and Lombardy within 8 weeks of the launch."

#### Audience
- **Firmographics and role**: role, seniority, company size, sector, region
- **Motivations**: pain points, goals, objections
- **Behaviour**: where they read, how they buy, what they've engaged with before
- **Buying stage**

Short profile, not a full persona:
> "[Role] at [company type] who struggles with [pain point] and wants [outcome].
> They usually find solutions through [channels] and care most about
> [priorities]."

#### Message
- **Core message**: what the audience should think, feel or do
- **Supporting messages**: evidence, objections handled, benefits
- **Proof points**: data, case studies, testimonials (with consent)
- **Differentiation**: versus alternatives, including doing nothing

Hierarchy: why should I care, what is the solution, why you, what should I do.

#### Channel
Choose by where the audience is, not by habit.

#### Measure
Decide how you'll know it worked, before launch.

### Channel selection guide

#### Owned

| Channel | Best for | Typical metrics | Effort |
|---|---|---|---|
| Website / blog | Search, education, credibility | Traffic, time on page, conversions | Medium |
| Newsletter | Nurture, retention, announcements | Open rate, click rate, replies | Low-medium |
| LinkedIn (organic) | Awareness, B2B credibility | Engagement, reach, followers | Medium |
| Webinars | Education, leads, demos | Registrations, attendance, follow-ups | High |
| Podcast | Thought leadership | Downloads, subscribers | High |

#### Earned

| Channel | Best for | Typical metrics | Effort |
|---|---|---|---|
| Trade and local press | Awareness, credibility, launches | Coverage, referral traffic | High |
| Guest content | New audiences, credibility | Referral traffic, backlinks | Medium |
| Partners and associations | Trust, reach into a sector | Referrals, introductions | Medium-high |
| Communities and events | Trust, feedback | Conversations, meetings | Medium |
| Reviews and referrals | Credibility, consideration | Number of reviews, referred leads | Low-medium |

#### Paid

| Channel | Best for | Typical metrics | Effort |
|---|---|---|---|
| Search ads | High-intent leads | Cost per click, conversion rate, cost per lead | Medium |
| LinkedIn ads | B2B targeting by role and sector | Cost per lead, click rate | Medium |
| Sponsored newsletters | Reaching a niche | Clicks, leads | Low-medium |
| Events and sponsorships | Relationships, local presence | Meetings, leads, deals influenced | High |

#### Selection criteria
- Where does the audience spend time?
- Which buying stage are we targeting?
- Budget: paid channels need money; owned and earned need time, and a small team
  has little of it.
- What content do we already have?
- What worked before?

### Content calendar

#### Process
1. **Start with milestones**: launch, events, releases, seasonal moments (in Italy
  plan around August and the Christmas period, when B2B attention drops)
2. **Work backwards**: what must be live when, and the production lead time
3. **Map content to funnel stages**: awareness, consideration, conversion
4. **Group by theme**: weekly or fortnightly themes
5. **Balance channels**: don't over-rely on one
6. **Leave slack**: about 20% of slots open for reactive content

#### Cadence (adjust down for a small team)
- **Blog**: 2 to 4 posts a month
- **Newsletter**: monthly or fortnightly
- **LinkedIn**: 2 to 4 posts a week across company and founder profiles
- **Paid**: continuous during the campaign, creative refreshed every 2 to 4 weeks
- **Webinars**: quarterly

#### Production lead times
- Blog post: 3 to 5 working days (research, draft, review)
- Newsletter: 2 to 3 working days (copy, design, test)
- Social posts: 1 to 2 working days
- Landing page: 5 to 7 working days (copy, design, build, check)
- Video: 2 to 4 weeks
- White paper or guide: 2 to 4 weeks

Add time for CEO approval and, where needed, legal review.

### Budget approaches

#### Share of revenue
- Common benchmarks: 5 to 10% of revenue for B2B marketing, more for companies
  in a growth phase. Treat these as orientation, not targets: a small company's
  budget is whatever `roles/finance.md` and the CEO allow.
- Split between long-term brand work and short-term performance.

#### Allocation starting point (adjust to goals and history)

| Category | Share | Examples |
|---|---|---|
| Paid acquisition | 30-40% | Search, LinkedIn ads |
| Content production | 20-30% | Writing, design, video |
| Events and sponsorships | 10-20% | Trade fairs, meetups, webinars |
| Tools | 10-15% | Analytics, newsletter tool |
| Tests | 5-10% | New channels, A/B tests |

#### Principles
- Put most paid budget (60 to 70%) on the channel you trust most
- Keep 15 to 20% for tests
- Review monthly with real data
- Count production costs, not just media
- Keep a 10 to 15% contingency

### Success metrics by campaign type

#### Awareness
| Metric | Measures |
|---|---|
| Reach / impressions | How many saw it |
| Brand mentions | Conversation about the company |
| Share of voice | Mentions versus competitors |
| Direct traffic | Visits without a referral |
| Follower growth | Audience building |

#### Lead generation
| Metric | Measures |
|---|---|
| Leads | New contacts |
| Qualified leads | Contacts that fit the target |
| Cost per lead | Efficiency |
| Lead-to-qualified rate | Quality |
| Pipeline value | Opportunity created (in euro) |

#### Product launch
| Metric | Measures |
|---|---|
| Signups, trials, demo requests | Adoption interest |
| Activation | Users completing a key first action |
| Coverage | Press and partner mentions |
| Social engagement | Mentions, shares |
| Feature adoption | Use of the new features |

#### Retention
| Metric | Measures |
|---|---|
| Churn change | Retention |
| Engagement | Interaction with the content |
| Satisfaction change | Customer sentiment |
| Upsell revenue | Expansion |
| Feature adoption | Use of promoted features |

#### Event / webinar
| Metric | Measures |
|---|---|
| Registrations | Interest |
| Attendance rate | Registration to attendance |
| Engagement | Questions, polls |
| Follow-up conversations | Leads from attendees |
| Recording reach | Audience after the event |

## Output

Write the brief to `drafts/campaign-<short-name>-YYYY-MM-DD.md` and give the CEO
a short summary in chat: objective, the two or three main channels, the budget
total if any, and the approvals needed. Say plainly that it's a draft plan and
nothing has been booked or scheduled.

Then offer:
- going deeper on any section
- drafting specific pieces from the calendar (with the `content-creation` skill)
- a competitive brief to sharpen the messages (`competitive-brief`)
- a version for a different budget or timeline
