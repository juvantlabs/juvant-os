"""Unit tests for framework/dashboard/build.py."""
import datetime as dt
import importlib.util
import json
import os
import shutil
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location("build", os.path.join(ROOT, "framework", "dashboard", "build.py"))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
TODAY = dt.date(2026, 11, 9)


class Dashboard(unittest.TestCase):
    def setUp(self):
        self.repo = tempfile.mkdtemp(prefix="jv2-dash-")
        self.addCleanup(shutil.rmtree, self.repo, True)

    def write(self, rel, text):
        p = os.path.join(self.repo, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)

    def page(self, agents_json=None):
        return build.build(self.repo, TODAY, agents_json)

    def test_empty_repo_renders_every_section(self):
        p = self.page()
        self.assertTrue(p.startswith("<!DOCTYPE html>"))
        for s in ("Nothing is waiting for you.", "No collaborator sessions.", "No decisions recorded yet.",
                  "No deadlines", "Sessions per day"):
            self.assertIn(s, p)

    def test_full_repo(self):
        self.write("manifesto.md", "# Acme manifesto\n")
        self.write("roles/legal.md", "name: Ada\n")
        self.write("roles/finance.md", "name: {{FINANCE_NAME}}\n")
        self.write("memory/journal/2026-11-08.md", "- Waiting for the CEO: none\n- Waiting for the CEO: sign off the offer\n")
        self.write("memory/decisions/2026-11-01-a.md", "---\ndate: 2026-11-01\nstatus: active\ndecided_by: Bo\n---\n# Keep prices\n")
        self.write("memory/decisions/2026-10-01-b.md", "---\ndate: 2026-10-01\nstatus: superseded\n---\n# Old prices\n")
        self.write("memory/deadlines.md", "| Date | What | Who |\n|---|---|---|\n| 2026-11-16 | VAT payment | Acct |\n| 2027-03-01 | Far away | X |\n| 2026-11-01 | Past | X |\n")
        self.write("drafts/offer.md", "x")
        self.write("state/briefs/social-campaign.md", "Started 2026-11-09.\n")
        acts = [
            {"ts": "2026-11-09T08:00:00Z", "event": "session_start", "session": "s1"},
            {"ts": "2026-11-09T08:01:00Z", "event": "subagent_start", "agent_type": "legal"},
            {"ts": "2026-11-09T08:05:00Z", "event": "subagent_stop", "agent_type": "legal", "outcome": "**VERDICT: STOP** clause 6"},
            {"ts": "2026-11-09T08:06:00Z", "event": "subagent_start", "agent_type": "general-purpose"},
            {"ts": "2026-11-09T09:00:00Z", "event": "outcome", "agent_type": "social-campaign", "outcome": "Draft ready"},
            "not json",
        ]
        self.write("state/activity.jsonl", "\n".join(a if isinstance(a, str) else json.dumps(a) for a in acts))
        p = self.page()
        self.assertIn("<h1>Acme</h1>", p)
        self.assertIn("Waiting for you · 2", p)
        self.assertIn("sign off the offer", p)
        self.assertNotIn(">none<", p)
        self.assertIn("drafts/offer.md", p)
        self.assertIn("<strong>Ada</strong>", p)
        self.assertIn("<strong>finance</strong>", p, "an unfilled name falls back to the role id")
        self.assertIn("VERDICT: STOP clause 6", p, "outcome shown as plain text")
        self.assertIn("general-purpose (1)", p)
        self.assertIn("Keep prices", p)
        self.assertNotIn("Old prices", p)
        self.assertIn("VAT payment", p)
        self.assertNotIn("Far away", p)
        self.assertNotIn("Past", p)
        self.assertIn("social-campaign", p)
        self.assertIn("Draft ready", p)
        self.assertIn("see agent view", p)

    def test_waiting_shows_only_the_latest_list(self):
        self.write("memory/journal/2026-11-07.md", "- Waiting for the CEO: older day item\n")
        self.write("memory/journal/2026-11-08.md",
                   "## 10:00\n- Waiting for the CEO: stale morning list\n"
                   "## 18:00\n- Waiting for the CEO: current evening list\n")
        p = self.page()
        self.assertIn("current evening list", p)
        self.assertNotIn("stale morning list", p, "an earlier list of the same day is superseded")
        self.assertNotIn("older day item", p)
        self.assertIn("Waiting for you · 1", p)

    def test_waiting_cleared_by_a_later_none(self):
        self.write("memory/journal/2026-11-08.md",
                   "- Waiting for the CEO: sign the offer\n- Waiting for the CEO: none\n")
        p = self.page()
        self.assertNotIn("sign the offer", p)
        self.assertIn("Nothing is waiting for you.", p)

    def test_waiting_survives_a_newer_journal_without_the_line(self):
        self.write("memory/journal/2026-11-07.md", "- Waiting for the CEO: sign the offer\n")
        self.write("memory/journal/2026-11-08.md", "- a note written outside a wrap-up\n")
        p = self.page()
        self.assertIn("sign the offer", p)
        self.assertIn("Waiting for you · 1", p)

    def test_projects(self):
        self.write("memory/projects/launch/README.md", "---\nstatus: active\n---\n\n# Assist 2.0 launch\n\n## Status\n\n<!-- c -->\n- Posts drafted, waiting for the date\n")
        self.write("memory/projects/launch/decisions/2026-11-02-date.md", "---\ndate: 2026-11-02\nstatus: active\n---\n# Launch on 15 January\n")
        self.write("memory/projects/old/README.md", "---\nstatus: closed\n---\n\n# Old site\n")
        p = self.page()
        self.assertIn("Assist 2.0 launch", p)
        self.assertIn("Posts drafted, waiting for the date", p)
        self.assertIn("2026-11-02 Launch on 15 January", p)
        self.assertLess(p.index("Assist 2.0 launch"), p.index("Old site"), "active before closed")
        self.assertIn("No projects in memory/projects/.", build.build(tempfile.mkdtemp(), TODAY))

    def test_live_states(self):
        self.write("state/briefs/social-campaign.md", "2026-11-09")
        self.write("agents.json", json.dumps([{"name": "social-campaign", "state": "needs input"}]))
        self.assertIn("needs input", self.page(os.path.join(self.repo, "agents.json")))

    def test_escaping(self):
        self.write("memory/decisions/2026-11-01-x.md", "---\nstatus: active\n---\n# <script>alert(1)</script>\n")
        p = self.page()
        self.assertNotIn("<script>alert", p)
        self.assertIn("&lt;script&gt;", p)

    def test_menu_links_every_section(self):
        p = self.page()
        for anchor in ("waiting", "agents", "sessions", "projects", "decisions", "deadlines", "activity"):
            self.assertIn(f'href="#{anchor}"', p)
            self.assertIn(f'id="{anchor}"', p)

    def test_no_external_scripts(self):
        p = self.page()
        self.assertNotIn("<script", p)

    def test_decisions_capped(self):
        for i in range(1, 15):
            self.write(f"memory/decisions/2026-10-{i:02d}-d.md", f"---\nstatus: active\n---\n# D{i:02d}\n")
        p = self.page()
        self.assertIn("D14", p)
        self.assertNotIn("D06", p)


if __name__ == "__main__":
    unittest.main()
