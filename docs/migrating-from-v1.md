# Moving a company from juvant-os v1 to v2

v1 kept the company in a database, compiled roles and many repositories. v2 keeps it in one private company repo of plain files, plus the repositories each project already has. This guide moves a v1 company without losing anything that matters, and without touching the v1 instance until you decide to archive it.

Work in this order. Nothing here writes to the v1 instance or its databases.

## 1. Create the v2 company repo

From a clone of juvant-os at a v2 tag:

```
bash setup.sh ~/Projects/<company>-v2 --company "<Company>" --country <code> --language <language>
```

A new folder, separate from the v1 instance. `--country` installs the country pack if the framework has one (see `framework/countries/`).

## 2. Move the memory from the v1 databases

Make read-only SQLite copies of the v1 databases, company and projects:

```
turso db shell <company-db> .dump | sqlite3 /tmp/v1-company.db
turso db shell <project-db> .dump | sqlite3 /tmp/v1-<slug>.db     # one per project you keep
```

(With `db.provider=local`, copy the database files instead.) Then:

```
python3 tools/migrate-from-v1.py /tmp/v1-company.db ~/Projects/<company>-v2 \
    --project <slug>=/tmp/v1-<slug>.db --dry-run
```

Read the summary with the CEO: decisions by category, what is skipped (v1 governance records are skipped by default), redactions, agent names, project cards. Run again without `--dry-run`, with the options you chose. Delete the `/tmp/v1-*.db` copies afterwards: they hold whole databases.

**Components** (v1 single-maintainer repos such as MCP servers, libraries, toolboxes) become projects like any other: they were listed only in the instance's config, not in the database. Save the `components` array of that config to a file and add `--components /tmp/components.json`: each gets a project card with its repository and audience (a public repository is read by everyone, so link it later with `--shared-with "everyone (public repository)"`). Their decisions and knowledge stay in their own repositories (ADRs, issues labelled `juvant:decision`), linked from the card. The v1 master/child company types have no equivalent in v2 and are dropped.

What moves: approved and executed decisions, the knowledge base, counterparties with their contacts and history, a card per project. What stays in v1, archived: audit logs, messages, queues, manifesto records, sessions.

## 3. Move the internal documents

If the company kept internal documents in a separate repository (notes, ADRs, policies, evaluations, brand), they belong in the v2 company repo, which has the same audience:

| v1 location | v2 location |
|---|---|
| Company-wide documents (ADRs, standards, policies, evaluations, methods) | `docs/` |
| Brand guidelines, naming | `memory/knowledge/brand.md` (facts) and `docs/` (the full guidelines) |
| Internal notes about one project | `memory/projects/<slug>/knowledge/` |
| A project's internal legal documents (assessments, records of processing) | `docs/projects/<slug>/` with a line in the project card |

Copy them with their history if you want it (`git subtree` or `git filter-repo`), or as plain files with a note of where they came from. Archive the old repository once the move is checked.

## 4. Keep each project's own repositories

A project's documents and code stay where they are. For each repository a project owns, tell the Chief of Staff in the company repo: "link `<repo>` to project `<slug>`; it's read by `<who>`" (the `project-repo` skill; you confirm the write). Later changes the same way: "`<repo>` is now shared with …", "`<repo>` is internal again". In scripts, `bash setup.sh --project-repo <repo> --company-dir <company-repo> --project <slug> [--shared-with "<who>"]` does the same.

- Use `--shared-with` for any repository read by partners, clients or co-founders outside the company. In it, pushing to the default branch and merging pull requests are blocked: work goes on a branch with a draft pull request, and the CEO merges. Internal memory never goes there.
- List every repository and who reads it in the project card (`memory/projects/<slug>/README.md`, "Repositories and audience"), and the language rules of its documents.
- If a repository already has `.claude/settings.json` or `.claude/CLAUDE.md`, setup stops: merge by hand.

**Authorship conventions.** v1 project repositories often name v1 agents as authors or reviewers (product lead, architect, engineering lead, design lead, research). In v2 those roles are collaborator sessions started with a brief, and the CEO validates. Update the conventions file of each project repository: the documents already written stay valid.

## 5. Bring over the company's own methods

A method the company built for itself (how it runs a project from discovery to plans, a document canon, review checklists) is not part of the framework. Make it a **company skill**: `.claude/skills/<name>/SKILL.md` in the company repo. `update` never touches it.

## 6. First session

In the new repo: `claude --name cos --remote-control`. The Chief of Staff fills what setup left open with the CEO (names, from the migration report if you keep the v1 ones), drafts the manifesto from the v1 culture, and completes the project cards.

## 7. Run both for a while, then archive v1

Use v2 for daily work and keep v1 available for a week or two. Set up the dashboard as a scheduled task. When nothing sends you back to v1: uninstall the v1 scheduled jobs on the machine that runs them, and archive the v1 instance repository (don't delete it: it holds the audit history).
