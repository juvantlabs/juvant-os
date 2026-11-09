# Voice: writing in the company's and the CEO's name

> Adapted from anthropics/knowledge-work-plugins `small-business/shared/voice-profile.md` at commit e050c2e (Apache-2.0). Modified for juvant-os: the voice comes from the manifesto's "How we sound" and `memory/knowledge/brand.md` instead of a profile stored in this file; corrections become proposals to update memory/knowledge; country-neutral; local rules from the country pack.

**Shared across skills.** Every skill that writes something that goes out under
the CEO's or the company's name (an email reply, a reminder, a proposal, a post,
a newsletter) reads the voice from the company's own files first. Voice drift
between skills is the thing people notice fastest.

This file does **not** hold a profile. The company's files do.

---

## Where the voice lives

Read before writing anything in the CEO's or the company's name:

1. **`manifesto.md`, section "How we sound"**: the company's voice in a few
   lines (register, languages, sentence length, words it avoids).
2. **`memory/knowledge/brand.md`**: name spellings, claims the company uses and
   never uses, channels, audience.
3. **Any other voice notes in `memory/knowledge/`** (for example notes on how the
   CEO writes emails), if `memory/map.md` points to them.
4. **The thread itself**: when replying, the earlier messages from the CEO in
   the same thread show the greeting, sign-off and language already in use with
   that person. Match them. This is read for the current draft only; do not
   store it anywhere.

Language follows the manifesto: if it says, for example, "our language with
local clients, English otherwise", write to a local counterparty in that
language, even though the skill's own instructions are in English.

**Local rules.** If `.claude/country/locale.md` or `country/locale.md` exists,
use its business language and register: forms of address, titles, greetings and
the local filler phrases to avoid. If neither exists, take register from the
thread and the brand file, and say the local conventions were not checked.

---

## What to take from it

Be specific enough to imitate. "Friendly and professional" describes every
business email ever written. From the sources above, pin down:

| Trait | What to capture |
|---|---|
| Greeting | The exact form ("Hi Dana," vs "Dear Dr Rossi,") |
| Sign-off | Exact, including first name only or full name and title |
| Register | Formal or informal address where the language has both (e.g. tu/Lei, du/Sie, tu/vous); first names or titles |
| Sentence length | Short and clipped, or longer |
| Directness | Is the ask in line 2 or line 6 |
| Product language | What the company calls its own product and services |
| Claims | Which claims are approved, which are never made |
| Never-dos | Words and structures the manifesto or brand file rules out |

**The never-dos matter most.** If the brand file says the company never says
"revolutionary", one occurrence is enough for a reader to know someone else
wrote the text. Generic filler ("I hope this email finds you well", "just
following up", and the local equivalents the locale file lists) is out unless
the company's files say otherwise.

---

## When the files say nothing useful

If the manifesto has no "How we sound" section and `memory/knowledge/brand.md`
is missing or silent on voice, say so plainly. Write plainly in a neutral
register, say the draft is un-voiced, and suggest the CEO add a few lines on
voice to the manifesto or to `memory/knowledge/brand.md`. Never invent a
personality: a guessed voice produces exactly the generic copy the CEO is
trying to avoid.

---

## When the CEO corrects a draft

Every edit is a signal. When the CEO changes a draft and the reason is about
voice (not about facts), ask what the change was about if it isn't obvious, and
then **propose adding it to `memory/knowledge/brand.md`** (or to the manifesto,
if it's about the company's culture), quoting the line you'd add:

```
Proposed addition to memory/knowledge/brand.md, under Voice:
- No "Sorry for the slow reply" in routine answers unless we were actually late.
```

Do not write the change yourself unless the CEO says yes, and do not keep a
private list of corrections in session memory or in this file. A correction
made once should reach every skill, and the only way it does is through the
company's files.
