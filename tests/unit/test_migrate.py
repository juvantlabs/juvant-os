"""Unit tests for tools/migrate-from-v1.py."""
import glob
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOL = os.path.join(ROOT, "tools", "migrate-from-v1.py")
FAKE_TOKEN = "eyJhbGciOiJFZERTQSJ9" + "." + "eyJhIjoicm8iLCJpYXQiOjE3MDAwMDAwMDB9" + "." + "c2lnbmF0dXJlc2lnbmF0dXJl"


def v1_db(path):
    con = sqlite3.connect(path)
    con.executescript("""
    CREATE TABLE agents (id INTEGER PRIMARY KEY, role TEXT, name TEXT);
    CREATE TABLE decisions (id INTEGER PRIMARY KEY, agent TEXT, title TEXT, category TEXT, rationale TEXT,
      source_ref TEXT, status TEXT, scope TEXT, approved_by TEXT, approved_at TEXT, executed_by TEXT,
      executed_at TEXT, created_at TEXT);
    CREATE TABLE knowledge_base (id INTEGER PRIMARY KEY, category TEXT, title TEXT, content TEXT,
      source_project TEXT, tags TEXT, source_ref TEXT, created_at TEXT);
    CREATE TABLE counterparties (id TEXT PRIMARY KEY, name TEXT, type TEXT, agent_owner TEXT, notes TEXT);
    CREATE TABLE counterparty_contacts (id INTEGER PRIMARY KEY, counterparty_id TEXT, email TEXT, name TEXT, role TEXT);
    CREATE TABLE counterparty_history (id INTEGER PRIMARY KEY, counterparty_id TEXT, summary TEXT, last_contact TEXT, updated_at TEXT);
    CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT, db_url TEXT, status TEXT, maturity_status TEXT);
    """)
    con.executemany("INSERT INTO agents (role, name) VALUES (?, ?)", [("cos", "Theo"), ("clo", "Ada"), ("cfo", None)])
    con.executemany("INSERT INTO decisions (id, title, category, rationale, status, approved_by, approved_at, created_at, scope) VALUES (?,?,?,?,?,?,?,?,?)", [
        (1, "Price stays at 45 euro", "pricing", "Annual review", "approved", "CEO", "2026-09-15 10:00:00", "2026-09-14", "company"),
        (2, "Approve CFO manifesto", "manifesto-approval", "Tier 1", "approved", "CEO", "2026-09-16", "2026-09-16", "company"),
        (3, "Maybe open Berlin office", "strategy", "Idea", "proposed", None, None, "2026-10-01", "company"),
        (4, "Old supplier policy", "procurement", "Replaced", "superseded", "CEO", "2026-05-01", "2026-05-01", "company"),
        (5, "Rotate token", "security", "token was " + FAKE_TOKEN, "executed", None, None, "2026-10-10", "company"),
    ])
    con.execute("INSERT INTO knowledge_base (category, title, content, tags, source_project, created_at) VALUES (?,?,?,?,?,?)",
                ("runbook", "How we close the month", "Steps: bank, receivables, packet.", "finance;monthly", "acme", "2026-10-02"))
    con.execute("INSERT INTO counterparties VALUES ('c1', 'Ferro Logistica', 'client', 'cco', 'Big client')")
    con.execute("INSERT INTO counterparty_contacts (counterparty_id, email, name, role) VALUES ('c1', 'mario@ferro.example', 'Mario Bianchi', 'CFO')")
    con.execute("INSERT INTO counterparty_history (counterparty_id, summary, last_contact) VALUES ('c1', 'Asked for 30-day terms', '2026-11-01')")
    con.execute("INSERT INTO projects VALUES ('hx', 'Helix', 'libsql://x', 'active', 'preview')")
    con.commit()
    con.close()


class Migrate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="jv2-mig-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.db = os.path.join(self.tmp, "v1.db")
        v1_db(self.db)
        self.co = os.path.join(self.tmp, "co")
        subprocess.run(["bash", os.path.join(ROOT, "setup.sh"), self.co], check=True, capture_output=True)

    def run_tool(self, *extra):
        return subprocess.run([sys.executable, TOOL, self.db, self.co, *extra], capture_output=True, text=True)

    def read(self, pattern):
        files = glob.glob(os.path.join(self.co, pattern))
        texts = []
        for f in files:
            with open(f, encoding="utf-8") as fh:
                texts.append(fh.read())
        return "\n".join(texts), files

    def test_migration(self):
        r = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stderr)
        decisions, files = self.read("memory/decisions/*-v1-*.md")
        self.assertIn("Price stays at 45 euro", decisions)
        self.assertIn("date: 2026-09-15", decisions)
        self.assertIn("status: superseded", decisions)
        self.assertNotIn("Approve CFO manifesto", decisions, "governance categories skipped by default")
        self.assertNotIn("Berlin", decisions, "proposed decisions skipped by default")
        self.assertNotIn(FAKE_TOKEN, decisions)
        self.assertIn("[redacted]", decisions)
        self.assertEqual(len(files), 3)
        kb, _ = self.read("memory/knowledge/*.md")
        self.assertIn("How we close the month", kb)
        self.assertIn("monthly", kb)
        self.assertIn("Ferro Logistica", kb)
        self.assertIn("Mario Bianchi, CFO", kb)
        self.assertNotIn("mario@ferro.example", kb, "emails only with --with-contact-emails")
        self.assertIn("Asked for 30-day terms", kb)
        with open(os.path.join(self.co, "MIGRATION-REPORT.md"), encoding="utf-8") as fh:
            report = fh.read()
        self.assertIn("`clo`: Ada → legal", report)
        self.assertIn("Helix", report)
        self.assertNotIn("libsql://x", report)
        self.assertIn("Secret-shaped text redacted: 1", report)

    def test_projects(self):
        pdb = os.path.join(self.tmp, "hx.db")
        con = sqlite3.connect(pdb)
        con.executescript("""
        CREATE TABLE decisions (id INTEGER PRIMARY KEY, agent TEXT, title TEXT, category TEXT, rationale TEXT,
          source_ref TEXT, status TEXT, scope TEXT, approved_by TEXT, approved_at TEXT, executed_by TEXT,
          executed_at TEXT, created_at TEXT);
        CREATE TABLE knowledge_base (id INTEGER PRIMARY KEY, category TEXT, title TEXT, content TEXT,
          source_project TEXT, tags TEXT, source_ref TEXT, created_at TEXT);
        """)
        con.execute("INSERT INTO decisions (title, category, status, approved_by, approved_at, scope) VALUES ('Use Postgres for Helix', 'architecture', 'approved', 'CEO', '2026-10-05', 'project')")
        con.execute("INSERT INTO knowledge_base (category, title, content, created_at) VALUES ('runbook', 'Helix deploy steps', 'Build, test, deploy.', '2026-10-06')")
        con.commit(); con.close()
        r = self.run_tool("--project", f"hx={pdb}")
        self.assertEqual(r.returncode, 0, r.stderr)
        card, _ = self.read("memory/projects/hx/README.md")
        self.assertIn("# Helix", card)
        self.assertIn("status: active", card)
        pdec, files = self.read("memory/projects/hx/decisions/*.md")
        self.assertIn("Use Postgres for Helix", pdec)
        pkb, _ = self.read("memory/projects/hx/knowledge/*.md")
        self.assertIn("Helix deploy steps", pkb)
        cdec, _ = self.read("memory/decisions/*-v1-*.md")
        self.assertNotIn("Postgres", cdec, "project decisions stay in the project folder")
        self.assertNotEqual(self.run_tool("--project", "Bad Slug=x").returncode, 0)

    def test_project_cards_without_project_db(self):
        self.assertEqual(self.run_tool().returncode, 0)
        card, _ = self.read("memory/projects/hx/README.md")
        self.assertIn("# Helix", card)

    def test_options(self):
        r = self.run_tool("--keep-all-categories", "--include-proposed", "--with-contact-emails")
        self.assertEqual(r.returncode, 0, r.stderr)
        decisions, _ = self.read("memory/decisions/*-v1-*.md")
        self.assertIn("Approve CFO manifesto", decisions)
        self.assertIn("Berlin", decisions)
        kb, _ = self.read("memory/knowledge/*.md")
        self.assertIn("mario@ferro.example", kb)

    def test_kb_by_category(self):
        r = self.run_tool("--kb-by-category")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(self.co, "memory", "knowledge", "runbook", "how-we-close-the-month.md")))
        self.assertTrue(os.path.isfile(os.path.join(self.co, "memory", "knowledge", "client", "ferro-logistica.md")))
        self.assertFalse(os.path.exists(os.path.join(self.co, "memory", "knowledge", "how-we-close-the-month.md")))

    def test_components_become_projects(self):
        comp = os.path.join(self.tmp, "components.json")
        with open(comp, "w") as f:
            f.write('{"components": [{"slug": "m365-graph", "name": "M365 Graph MCP", "repo": "acme/m365-graph-mcp-server", '
                    '"visibility": "public", "type": "mcp-server", "maintainer": "m365-graph-maintainer", '
                    '"maturity": "preview", "working_tree": "/Users/x/Projects/m365"}, '
                    '{"slug": "tools", "name": "Toolbox", "repo": "acme/tools", "visibility": "private", "type": "toolbox"}]}')
        r = self.run_tool("--components", comp)
        self.assertEqual(r.returncode, 0, r.stderr)
        card, _ = self.read("memory/projects/m365-graph/README.md")
        self.assertIn("# M365 Graph MCP", card)
        self.assertIn("tags: [project, component, mcp-server]", card)
        self.assertIn("| github.com/acme/m365-graph-mcp-server | code (mcp-server) | everyone (public repository) |", card)
        self.assertIn("juvant:decision", card)
        priv, _ = self.read("memory/projects/tools/README.md")
        self.assertIn("company only", priv)
        with open(os.path.join(self.co, "MIGRATION-REPORT.md"), encoding="utf-8") as fh:
            report = fh.read()
        self.assertIn("Components in v1 (now projects)", report)
        self.assertIn('--shared-with "everyone (public repository)"', report)

    def test_deadlines(self):
        dl = os.path.join(self.tmp, "deadlines.json")
        with open(dl, "w") as f:
            f.write('[{"id": "f24", "name": "F24 | IVA", "date": "2099-05-16", "owner": "cfo", "days_notice": 14},'
                    ' {"id": "old", "name": "Old filing", "date": "2020-01-31", "owner": "clo"}]')
        self.assertEqual(self.run_tool("--deadlines", dl).returncode, 0)
        with open(os.path.join(self.co, "memory", "deadlines.md"), encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn("| 2099-05-16 | F24 / IVA (notice 14 days) | finance |", text)
        self.assertIn("| 2020-01-31 | Old filing (past) | legal |", text)
        self.run_tool("--deadlines", dl)
        with open(os.path.join(self.co, "memory", "deadlines.md"), encoding="utf-8") as fh:
            self.assertEqual(fh.read().count("F24 / IVA"), 1, "rows are never duplicated")

    def test_dry_run_writes_nothing(self):
        before = sorted(os.listdir(os.path.join(self.co, "memory", "decisions")))
        r = self.run_tool("--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Dry run", r.stdout)
        self.assertEqual(sorted(os.listdir(os.path.join(self.co, "memory", "decisions"))), before)
        self.assertFalse(os.path.exists(os.path.join(self.co, "MIGRATION-REPORT.md")))

    def test_never_overwrites(self):
        self.run_tool()
        r = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stderr)
        _, files = self.read("memory/decisions/*-v1-1*.md")
        self.assertEqual(len(files), 2, "second run writes a -2 copy, never overwrites")

    def test_refuses_non_v2_and_v1_targets(self):
        plain = os.path.join(self.tmp, "plain")
        os.makedirs(plain)
        r = subprocess.run([sys.executable, TOOL, self.db, plain], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        os.makedirs(os.path.join(self.co, ".juvant"))
        self.assertNotEqual(self.run_tool().returncode, 0)

    def test_source_db_untouched(self):
        mtime = os.path.getmtime(self.db)
        self.run_tool()
        self.assertEqual(os.path.getmtime(self.db), mtime)


if __name__ == "__main__":
    unittest.main()
