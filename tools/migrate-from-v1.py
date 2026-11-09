#!/usr/bin/env python3
"""Move a juvant-os v1 company's memory into a v2 company repo.

    python3 tools/migrate-from-v1.py <v1.db> <v2-company-dir> [--dry-run]
        [--skip-category CAT ...] [--keep-all-categories] [--include-proposed]
        [--with-contact-emails] [--project <slug>=<v1-project.db> ...]
        [--kb-by-category] [--components <components.json>] [--deadlines <deadlines.json>]

<v1.db> is a SQLite copy of the v1 company DB. For a Turso DB, make one with
    turso db shell <db-name> .dump | sqlite3 v1.db
(read-only on Turso). For db.provider=local, copy the .juvant/*.db file.

What moves, as v2 memory files (format: memory/README.md in the v2 repo):
- decisions approved or executed      -> memory/decisions/<date>-<slug>-v1-<id>.md
  (superseded ones keep status: superseded; proposed and rejected are skipped
  unless --include-proposed; governance categories are skipped by default,
  see DEFAULT_SKIP, unless --keep-all-categories)
- knowledge_base rows                 -> memory/knowledge/<slug>.md, one per row
  (with --kb-by-category: memory/knowledge/<category>/<slug>.md)
- counterparties with contacts and history -> memory/knowledge/<type>-<slug>.md
  (with --kb-by-category: memory/knowledge/<type>/<slug>.md)
  (contact names and roles; emails only with --with-contact-emails)
- every v1 project                    -> memory/projects/<slug>/README.md, a card
  from the projects table (name, status, maturity); with --project, that project
  DB's decisions and knowledge go to memory/projects/<slug>/decisions|knowledge/
- v1 components (config.json components[], e.g. MCP servers, libraries)
                                      -> projects like any other: a card in
  memory/projects/<slug>/README.md with the repo and its audience (a public repo
  is read by everyone). Their decisions and knowledge stay in their repo (ADRs,
  issues labelled juvant:decision, docs), linked from the card. Pass the
  components array saved to a file: --components /tmp/components.json
- v1 deadlines (scripts/deadlines.json) -> rows of memory/deadlines.md (date | what |
  who), appended to the table setup created; past dates are kept, marked done
- agent names                         -> listed in MIGRATION-REPORT.md, for the
  role cards, not written into them

What doesn't move: audit logs, messages, queues, manifests, sessions, tokens.
Secret-shaped text is replaced with "[redacted]" and counted in the report.
Never overwrites a file; refuses if the target isn't a v2 company repo.
Read-only on the v1 DB. Standard library only.
"""
import argparse
import datetime as dt
import json
import os
import re
import sqlite3
import sys
import unicodedata

DEFAULT_SKIP = {
    "manifesto", "manifesto-approval", "manifesto-signoff", "manifesto-tier1", "manifesto-tier2",
    "bootstrap", "bootstrap-action", "tool-matrix-change", "upstream-sync", "sync", "audit",
    "security-audit", "agent-hiring", "offboarding", "disclosure-policy", "spec", "pr-spec",
    "install-spec", "branch-protection-spec", "eng-platform-spec",
}
SECRET_PATTERNS = [
    r"\bgh[pousr]_[A-Za-z0-9]{36}\b", r"\bgithub_pat_[A-Za-z0-9_]{60,}", r"\bsk-ant-[A-Za-z0-9_-]{20,}",
    r"\bsk-(proj-)?[A-Za-z0-9_-]{40,}", r"\bxox[abprs]-[A-Za-z0-9-]{10,}", r"\bAKIA[0-9A-Z]{16}\b",
    r"\b[A-Za-z0-9_.-]{3}8Q~[A-Za-z0-9_.~-]{31,34}", r"-----BEGIN ([A-Z]+ )?PRIVATE KEY-----",
    r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}",  # JWT (e.g. libsql tokens)
    r"libsql://[^\s]+\?authToken=[^\s]+",
]
SECRET_RE = re.compile("|".join(SECRET_PATTERNS))


class Report:
    def __init__(self):
        self.lines, self.redactions, self.written, self.skipped = [], 0, [], {}

    def skip(self, why):
        self.skipped[why] = self.skipped.get(why, 0) + 1


def slug(text, n=6):
    t = unicodedata.normalize("NFKD", str(text)).encode("ascii", "ignore").decode().lower()
    words = re.findall(r"[a-z0-9]+", t)
    return "-".join(words[:n]) or "untitled"


def clean(text, rep):
    text = "" if text is None else str(text)
    new, n = SECRET_RE.subn("[redacted]", text)
    rep.redactions += n
    return new.strip()


def day(*values):
    for v in values:
        if v:
            try:
                return dt.date.fromisoformat(str(v)[:10]).isoformat()
            except ValueError:
                continue
    return dt.date.today().isoformat()


def yaml_list(items):
    items = [re.sub(r"[\[\],]", " ", str(i)).strip() for i in items if i and str(i).strip()]
    return "[" + ", ".join(items) + "]"


def tables(con):
    return {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}


def columns(con, table):
    return {r[1] for r in con.execute(f"PRAGMA table_info({table})")}


def rows(con, table):
    con.row_factory = sqlite3.Row
    return [dict(r) for r in con.execute(f"SELECT * FROM {table}")]


class Writer:
    def __init__(self, target, dry, rep):
        self.target, self.dry, self.rep, self.planned = target, dry, rep, set()

    def path_for(self, rel):
        base, ext = os.path.splitext(rel)
        cand, i = rel, 2
        while os.path.exists(os.path.join(self.target, cand)) or cand in self.planned:
            cand, i = f"{base}-{i}{ext}", i + 1
        self.planned.add(cand)
        return cand

    def write(self, rel, text):
        rel = self.path_for(rel)
        self.rep.written.append(rel)
        if not self.dry:
            p = os.path.join(self.target, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "x", encoding="utf-8") as f:
                f.write(text)
        return rel


def migrate_decisions(con, w, rep, args, skip, base="memory"):
    if "decisions" not in tables(con):
        rep.lines.append("- No `decisions` table.")
        return
    keep = {"approved", "executed", "superseded"} | ({"proposed"} if args.include_proposed else set())
    by_cat = {}
    for d in rows(con, "decisions"):
        status = (d.get("status") or "").lower()
        cat = (d.get("category") or "").strip()
        by_cat[cat or "(none)"] = by_cat.get(cat or "(none)", 0) + 1
        if status not in keep:
            rep.skip(f"decision status {status or '(none)'}")
            continue
        if cat.lower() in skip:
            rep.skip(f"decision category {cat}")
            continue
        date = day(d.get("approved_at"), d.get("executed_at"), d.get("created_at"))
        title = clean(d.get("title"), rep) or f"Decision {d.get('id')}"
        rationale = clean(d.get("rationale"), rep)
        decided_by = clean(d.get("approved_by"), rep) or "CEO (from v1, approver not recorded)"
        v2_status = "superseded" if status == "superseded" else ("proposed" if status == "proposed" else "active")
        tags = [cat, d.get("scope") if d.get("scope") not in (None, "company") else ""]
        body = (f"---\ndate: {date}\ndecided_by: {decided_by}\nstatus: {v2_status}\ntags: {yaml_list(tags)}\n"
                f"source: juvant-os v1 decisions#{d.get('id')}\n---\n\n# {title}\n\n"
                f"## Context\n{rationale or '(no rationale recorded in v1)'}\n\n"
                f"## Decision\n{title}\n\n## Alternatives considered\n(not recorded in v1)\n\n"
                f"## Consequences\n{('Executed by ' + clean(d.get('executed_by'), rep) + ' on ' + day(d.get('executed_at'))) if d.get('executed_at') else '(see v1 history)'}\n"
                + (f"\nv1 reference: {clean(d.get('source_ref'), rep)}\n" if d.get("source_ref") else ""))
        w.write(f"{base}/decisions/{date}-{slug(title)}-v1-{d.get('id')}.md", body)
    rep.lines.append(f"- v1 decisions by category ({base}): " + ", ".join(f"{k} {v}" for k, v in sorted(by_cat.items())))


def migrate_knowledge(con, w, rep, base="memory", by_category=False):
    if "knowledge_base" not in tables(con):
        rep.lines.append("- No `knowledge_base` table.")
        return
    for k in rows(con, "knowledge_base"):
        title = clean(k.get("title"), rep) or f"Knowledge {k.get('id')}"
        tags = [k.get("category")] + [t.strip() for t in str(k.get("tags") or "").replace(";", ",").split(",")]
        if k.get("source_project"):
            tags.append(k["source_project"])
        sources = [f"juvant-os v1 knowledge_base#{k.get('id')}"] + ([clean(k["source_ref"], rep)] if k.get("source_ref") else [])
        body = (f"---\nupdated: {day(k.get('created_at'))}\ntags: {yaml_list(tags)}\nsources: {yaml_list(sources)}\n---\n\n"
                f"# {title}\n\n{clean(k.get('content'), rep)}\n")
        folder = f"{base}/knowledge/{slug(k.get('category') or 'general', 3)}" if by_category else f"{base}/knowledge"
        w.write(f"{folder}/{slug(title)}.md", body)


def migrate_counterparties(con, w, rep, with_emails, by_category=False):
    t = tables(con)
    if "counterparties" not in t:
        return
    contacts = rows(con, "counterparty_contacts") if "counterparty_contacts" in t else []
    history = rows(con, "counterparty_history") if "counterparty_history" in t else []
    for c in rows(con, "counterparties"):
        name = clean(c.get("name"), rep) or c.get("id")
        kind = slug(c.get("type") or "counterparty", 2)
        lines = [f"---\nupdated: {dt.date.today().isoformat()}\ntags: {yaml_list([c.get('type'), 'counterparty'])}\n"
                 f"sources: [juvant-os v1 counterparties#{c.get('id')}]\n---\n\n# {name}\n"]
        if c.get("notes"):
            lines.append(f"\n{clean(c['notes'], rep)}\n")
        people = [p for p in contacts if p.get("counterparty_id") == c.get("id")]
        if people:
            lines.append("\n## People\n")
            for p in people:
                bits = [clean(p.get("name"), rep) or "(name not recorded)"]
                if p.get("role"):
                    bits.append(clean(p["role"], rep))
                if with_emails and p.get("email"):
                    bits.append(clean(p["email"], rep))
                lines.append("- " + ", ".join(bits) + " (v1)\n")
        hist = [h for h in history if h.get("counterparty_id") == c.get("id")]
        if hist:
            lines.append("\n## History\n")
            for h in sorted(hist, key=lambda h: str(h.get("last_contact") or h.get("updated_at") or "")):
                lines.append(f"- {clean(h.get('summary'), rep)} ({day(h.get('last_contact'), h.get('updated_at'))}, v1)\n")
        rel = f"memory/knowledge/{kind}/{slug(name, 4)}.md" if by_category else f"memory/knowledge/{kind}-{slug(name, 4)}.md"
        w.write(rel, "".join(lines))


def project_cards(con, w, rep, project_slugs):
    """One card per v1 project (and per --project slug not in the table)."""
    t = tables(con)
    known = {}
    if "projects" in t:
        for p in rows(con, "projects"):
            known[slug(p.get("id") or p.get("name"), 8)] = p
    for s_ in project_slugs:
        known.setdefault(s_, {"id": s_, "name": s_})
    for s_, p in sorted(known.items()):
        status = {"active": "active"}.get(str(p.get("status") or "active").lower(), "paused")
        body = (f"---\nstatus: {status}\nstarted: {day(p.get('created_at'))}\ntags: [project]\n"
                f"source: juvant-os v1 projects/{p.get('id')}\n---\n\n# {clean(p.get('name'), rep) or s_}\n\n"
                f"## Goal\n\n<!-- to fill in -->\n\n## People\n\n<!-- to fill in -->\n\n## Where things live\n\n<!-- to fill in: code repositories, documents -->\n\n"
                f"## Status\n\n- Migrated from juvant-os v1 (maturity: {p.get('maturity_status') or 'n/a'}).\n")
        rel = f"memory/projects/{s_}/README.md"
        if os.path.exists(os.path.join(w.target, rel)):
            rep.skip("project card already present")
            continue
        w.write(rel, body)


def component_cards(path, w, rep):
    """v1 components become v2 projects: one card each."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        sys.exit(f"migrate: can't read {path}: {e}")
    items = data.get("components", data) if isinstance(data, dict) else data
    if not isinstance(items, list):
        sys.exit(f"migrate: {path} should hold a list of components (or {{\"components\": [...]}})")
    rep.lines.append("\n## Components in v1 (now projects)\n")
    for c in items:
        if not isinstance(c, dict):
            continue
        s_ = slug(c.get("slug") or c.get("name") or "component", 8)
        repo = clean(c.get("repo"), rep)
        public = str(c.get("visibility", "")).lower() == "public"
        audience = "everyone (public repository)" if public else "company only"
        kind = clean(c.get("type"), rep) or "component"
        rel = f"memory/projects/{s_}/README.md"
        rep.lines.append(f"- {c.get('name') or s_} (`{s_}`, {kind}, {repo or 'no repo'}, {'public' if public else 'private'})")
        if os.path.exists(os.path.join(w.target, rel)) or rel in w.planned:
            rep.skip("component card already present")
            continue
        body = (f"---\nstatus: active\nstarted: {dt.date.today().isoformat()}\ntags: {yaml_list(['project', 'component', kind])}\n"
                f"source: juvant-os v1 config components/{s_}\n---\n\n# {clean(c.get('name'), rep) or s_}\n\n"
                f"## Goal\n\n<!-- to fill in: what this {kind} is for, who uses it -->\n\n"
                f"## People\n\n- v1 maintainer agent: `{clean(c.get('maintainer'), rep) or s_ + '-maintainer'}` (in v2: a collaborator session when needed)\n\n"
                f"## Repositories and audience\n\n| Repository / library | What | Read by |\n|---|---|---|\n"
                f"| {('github.com/' + repo) if repo else '(none recorded)'} | code ({kind}) | {audience} |\n\n"
                f"## Documents: language and audience\n\nIn-repo documents (README, docs/adr/, issues) are read by {audience}.\n\n"
                f"## Where else things live\n\n- Decisions: in-repo ADRs (`docs/adr/`) and issues labelled `juvant:decision`.\n"
                f"- Local checkout (v1): {clean(c.get('working_tree'), rep) or '(not recorded)'}\n\n"
                f"## Status\n\n- Migrated from juvant-os v1 as a component (maturity: {c.get('maturity') or 'n/a'}).\n")
        w.write(rel, body)
        if public:
            rep.lines.append(f"  public repo: link it with the project-repo skill and --shared-with \"everyone (public repository)\"")


def migrate_deadlines(path, w, rep):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        sys.exit(f"migrate: can't read {path}: {e}")
    items = data.get("deadlines", data) if isinstance(data, dict) else data
    if not isinstance(items, list):
        sys.exit(f"migrate: {path} should hold a list of deadlines")
    owners = {"cfo": "finance", "clo": "legal", "cetho": "ethics", "cos": "Chief of Staff", "ceo": "CEO"}
    today = dt.date.today().isoformat()
    rows = []
    for d in items:
        if not isinstance(d, dict) or not d.get("date"):
            continue
        date = day(d.get("date"))
        what = clean(d.get("name") or d.get("id"), rep).replace("|", "/")
        who = owners.get(str(d.get("owner", "")).lower(), clean(d.get("owner"), rep))
        note = f" (notice {d['days_notice']} days)" if d.get("days_notice") else ""
        done = " (past)" if date < today else ""
        rows.append(f"| {date} | {what}{note}{done} | {who} |")
    rel = "memory/deadlines.md"
    full = os.path.join(w.target, rel)
    header = "# Deadlines\n\nOne row per deadline: date | what | who. The dashboard shows the next 30 days.\n\n| Date | What | Who |\n|---|---|---|\n"
    existing = ""
    if os.path.exists(full):
        with open(full, encoding="utf-8") as f:
            existing = f.read()
    new_rows = [r for r in sorted(rows) if r not in existing]
    rep.lines.append(f"- Deadlines from v1: {len(rows)} ({len(new_rows)} added to {rel})")
    if not new_rows:
        return
    rep.written.append(rel + " (rows appended)")
    if w.dry:
        return
    text = existing if "| Date | What | Who |" in existing else (existing.rstrip() + "\n\n" if existing.strip() else "") + header
    with open(full, "w", encoding="utf-8") as f:
        f.write(text.rstrip("\n") + "\n" + "\n".join(new_rows) + "\n")


def agents_and_projects(con, rep):
    t = tables(con)
    if "agents" in t:
        named = [(a.get("role"), a.get("name")) for a in rows(con, "agents") if a.get("name")]
        hint = {"cos": "Chief of Staff (CLAUDE.md)", "clo": "legal (roles/legal.md)",
                "cfo": "finance (roles/finance.md)", "cetho": "ethics (roles/ethics.md)"}
        rep.lines.append("\n## Agent names in v1\n")
        rep.lines.append("Use them in the v2 role cards if the CEO wants to keep them:\n")
        for role, name in sorted(named):
            rep.lines.append(f"- `{role}`: {name}" + (f" → {hint[role]}" if role in hint else ""))
    if "projects" in t:
        ps = rows(con, "projects")
        if ps:
            rep.lines.append("\n## Projects in v1\n")
            rep.lines.append("Each has a card in memory/projects/<slug>/README.md to complete (goal, people, repos). Project DBs are migrated only when passed with --project.\n")
            for p in ps:
                rep.lines.append(f"- {p.get('name')} (`{p.get('id')}`, {p.get('status')}, {p.get('maturity_status')})")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("v1_db")
    ap.add_argument("target")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--skip-category", action="append", default=[])
    ap.add_argument("--keep-all-categories", action="store_true")
    ap.add_argument("--include-proposed", action="store_true")
    ap.add_argument("--with-contact-emails", action="store_true")
    ap.add_argument("--deadlines", metavar="FILE", help="v1 scripts/deadlines.json, into memory/deadlines.md")
    ap.add_argument("--components", metavar="FILE",
                    help="v1 components array (from config.json) to turn into projects")
    ap.add_argument("--kb-by-category", action="store_true",
                    help="put knowledge in memory/knowledge/<category>/ (and counterparties in <type>/)")
    ap.add_argument("--project", action="append", default=[], metavar="SLUG=DB",
                    help="a v1 project DB to migrate into memory/projects/<slug>/")
    args = ap.parse_args()

    target = os.path.abspath(args.target)
    if not os.path.isfile(os.path.join(target, ".claude", "juvant-os.json")):
        sys.exit(f"migrate: {target} is not a juvant-os v2 company repo (no .claude/juvant-os.json). Run setup.sh first.")
    if os.path.isdir(os.path.join(target, ".juvant")):
        sys.exit(f"migrate: {target} has .juvant/: that's a v1 instance. Point this at a new v2 repo.")
    if not os.path.isfile(args.v1_db):
        sys.exit(f"migrate: {args.v1_db} not found")
    con = sqlite3.connect(f"file:{os.path.abspath(args.v1_db)}?mode=ro", uri=True)

    skip = set() if args.keep_all_categories else set(DEFAULT_SKIP)
    skip |= {c.lower() for c in args.skip_category}
    rep = Report()
    w = Writer(target, args.dry_run, rep)
    migrate_decisions(con, w, rep, args, skip)
    migrate_knowledge(con, w, rep, by_category=args.kb_by_category)
    migrate_counterparties(con, w, rep, args.with_contact_emails, by_category=args.kb_by_category)
    pairs = []
    for spec in args.project:
        if "=" not in spec:
            sys.exit(f"migrate: --project needs <slug>=<db>, got {spec}")
        ps, pdb = spec.split("=", 1)
        if not re.match(r"^[a-z0-9][a-z0-9-]{0,60}$", ps):
            sys.exit(f"migrate: bad project slug '{ps}'")
        if not os.path.isfile(pdb):
            sys.exit(f"migrate: {pdb} not found")
        pairs.append((ps, pdb))
    project_cards(con, w, rep, [p for p, _ in pairs])
    if args.components:
        component_cards(args.components, w, rep)
    if args.deadlines:
        migrate_deadlines(args.deadlines, w, rep)
    for ps, pdb in pairs:
        pcon = sqlite3.connect(f"file:{os.path.abspath(pdb)}?mode=ro", uri=True)
        migrate_decisions(pcon, w, rep, args, skip, base=f"memory/projects/{ps}")
        migrate_knowledge(pcon, w, rep, base=f"memory/projects/{ps}", by_category=args.kb_by_category)
    agents_and_projects(con, rep)

    summary = [f"# Migration from juvant-os v1 ({dt.date.today().isoformat()})\n",
               f"Source: `{os.path.basename(args.v1_db)}` (read-only). {'Dry run: nothing written.' if args.dry_run else ''}\n",
               f"- Files {'planned' if args.dry_run else 'written'}: {len(rep.written)}",
               f"- Secret-shaped text redacted: {rep.redactions}",
               "- Skipped: " + (", ".join(f"{k} {v}" for k, v in sorted(rep.skipped.items())) or "none"),
               f"- Governance categories skipped: {', '.join(sorted(skip)) or 'none'}"]
    report = "\n".join(summary + rep.lines + ["\n## Files\n"] + [f"- {f}" for f in rep.written]) + "\n"
    if args.dry_run:
        print(report)
    else:
        rel = w.write("MIGRATION-REPORT.md", report)
        print(f"migrate: {len(rep.written) - 1} memory files written, {rep.redactions} redactions; report in {rel}. Nothing committed.")


if __name__ == "__main__":
    main()
