# Morvento (fictional)

Morvento is an invented company, the reference instance of juvant-os v2. People, clients, figures and documents are made up. Any resemblance to a real company is unintended.

**Profile.** Italian B2B software and consulting company, six people, on Microsoft 365. It sells a product that uses AI and does custom projects for clients.

What it exercises:

- **Legal**: client contracts, NDAs, a foreign supplier that processes personal data (GDPR art. 28).
- **Finance**: e-invoices through SDI, F24 payments, a client who pays late.
- **Marketing**: a product launch and a brand with clear rules.
- **Ethics**: an AI product that touches client data.

## Layout

| Path | What |
|---|---|
| `CLAUDE.md` | The Chief of Staff, Nora (from `framework/templates/CLAUDE.md`) |
| `manifesto.md` | Morvento's culture, injected into every agent |
| `roles/` | Role cards: Ettore (legal), Greta (finance), Leone (ethics) |
| `memory/` | Map of where things live, product and brand facts |
| `samples/` | Test documents: a client contract draft with known issues, a receivables list with a late payer |
| `.claude/` | The framework, copied by `tests/sync-example.sh`; CI fails if it drifts |

To try it, copy this folder somewhere outside the repo, `git init` it, and start `claude` there.
