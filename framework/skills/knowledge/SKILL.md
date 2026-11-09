---
name: knowledge
description: "Add or update a durable fact in memory/knowledge/ (a client's preference, a supplier's terms, a product fact, a procedure, where a document lives). Use when the CEO says 'remember…', or when something learned in the session will matter later."
---

# Record knowledge

Format and rules: `memory/README.md`.

1. **Is it a decision?** If the CEO chose something (a price, a policy, a yes or no), use the `decision` skill instead.
2. **Is it a secret or unneeded personal data?** Then don't record it. Say so to the CEO.
3. **Company or project?** A fact about one project goes in `memory/projects/<slug>/knowledge/`; everything else in `memory/knowledge/`.
4. **Find its home.** Search first: `grep -ril "<key word>" memory/`. Add to the existing topic file if there is one; create `memory/knowledge/<topic>.md` only for a new topic (lowercase, hyphens: `client-ferrolino.md`, `supplier-cloud-hosting.md`, `procedure-month-end.md`).
5. **Write the fact** as one line with its source and date: `- Pays by bank transfer at 60 days end of month (CEO, 2026-11-09)`. If it replaces an older line, change that line rather than adding a contradicting one. Update `updated:` in the frontmatter.
6. **Where things live and who people are** go in `memory/map.md`, not in a topic file.
7. Tell the CEO in one line what you recorded and where. It is committed at wrap-up.
