# Reply drafting

> Adapted from anthropics/knowledge-work-plugins `small-business/skills/inbox-manager` at commit e050c2e (Apache-2.0). Modified for juvant-os: voice from the company's files, drafts created in Outlook (never sent), bilingual examples from Morvento, corrections proposed to `memory/knowledge/brand.md`; country-neutral; local rules from the country pack.

Read [voice](../../kwp-shared/voice-profile.md) first. Every draft here goes out
under the CEO's name, and voice drift between skills is what people notice
fastest. If the company's files say nothing about voice, write plainly in a
neutral register and say the drafts are un-voiced. Don't guess a personality.

Write in the language of the thread. The examples below mix the local language
and English the way a company like Morvento (an Italian example company) does.

**Local rules.** If `.claude/country/locale.md` or `country/locale.md` exists,
use its register, titles and greetings, and add its local filler phrases to the
lines never to write below. If neither exists, take register from the thread and
say the local conventions were not checked.

---

## Rules for every draft

**Answer the question first.** A reply that opens with pleasantries and reaches
the answer in paragraph three gets rewritten.

**Match the length of the incoming email.** A one-line question gets a one-line
answer.

**Never write a number the CEO hasn't already given.** Prices, dates, days of
work, discounts, delivery times. If it isn't in the thread, `roles/finance.md`,
`memory/knowledge/` or `memory/decisions/`, leave it for the CEO or write
direction instead of a figure. Published list prices (for example in
`memory/knowledge/product.md`) may be quoted as they are, never discounted.

**Never invent context.** No "great to hear from you again" without a prior
thread.

**Don't apologise for a delay unless there was one.**

**Respect register.** Formal or informal address (where the language has both)
as the CEO already used with that person in the thread.

---

## Patterns by email type

### Routine question

Answer, then close.

```
Ciao Marta,
sì, le risposte in tedesco arrivano con la versione 2.0, a gennaio.
Ti scrivo appena è disponibile.
Giulia
```

### Scheduling

Propose real times read from the Outlook calendar. If the calendar isn't
reachable, ask for their availability instead of inventing slots. The draft
proposes; nothing is booked or accepted.

```
Hi Dana,
Thursday morning or Friday after 14:00 both work for me. Which is easier?
Giulia
```

### A promise coming due

Name the promise. Don't pretend it's a fresh conversation. If the promised thing
isn't ready (the proposal isn't in `drafts/` yet), don't draft "here it is";
flag it in needs-you instead.

```
Buongiorno avvocato,
come promesso, le invio la proposta. La trova in allegato.
Giulia Ferrandi
```

(The attachment is added by the CEO; the draft says so in the digest.)

### An unhappy customer

Don't draft the fix or an offer. Draft the acknowledgement and get it to the CEO
fast. Compensation, credits and blame are CEO decisions. If the company made a
mistake, the manifesto says we tell the client first: the acknowledgement owns it
plainly.

```
Gentile signora Lenzi,
ha ragione: l'orario inviato ai suoi clienti era sbagliato, ed è un errore
nostro. Sto verificando cosa è successo e la chiamo oggi.
Giulia Ferrandi
```

Then flag it in needs-you so the call happens.

### Something you can't answer

Say so. An honest holding reply beats a confident wrong one.

```
Hi Ellen,
I need to check with the team before I answer that properly. Back to you
tomorrow.
Giulia
```

### Declining

Short, honest, and refer on when you can.

```
Ciao Pietro,
un'integrazione con il gestionale di magazzino non è qualcosa che facciamo.
Per questo ti consiglio di sentire Studio Ricci.
Giulia
```

---

## Lines never to write

Tells that someone other than the CEO wrote the message:

- "I hope this email finds you well"
- "Just circling back" / "Just following up" / "Touching base"
- "Per my last email"
- "I wanted to reach out"
- "Please don't hesitate to reach out" (unless the company's files show the CEO
  uses it)
- "At your earliest convenience"
- The local-language equivalents the locale file lists
- Any superlative or claim `memory/knowledge/brand.md` rules out

If the company's files list their own never-dos, those take priority.

---

## When the CEO edits a draft

Every edit is data. If the change is about voice, ask what it was about if it
isn't obvious, then propose the line for `memory/knowledge/brand.md`:

```
Proposed addition to memory/knowledge/brand.md, under Voice:
- No "Sorry for the delay" in routine replies unless we were actually late.
```

Don't write it yourself without a yes, and don't keep a private list.
