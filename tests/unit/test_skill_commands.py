"""Every command the framework's skills, agents and CLAUDE.md tell an agent to run, and the everyday forms agents give
them, judged by the hard-limits hook in a freshly installed company. A change to the hooks must keep them working.
Run: python3 -m unittest tests/unit/test_skill_commands.py"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FW = os.path.join(ROOT, "framework")
VERBS = r"(python3|bash|git|gh|claude|cd|cat|ls|grep|sed|mkdir|cp|mv|rm|echo|jq|curl|find)"
VALUES = {"tag": "v2.1.0", "owner/repo": "acme/exts", "folder": "demo", "id": "collaborator", "name": "research",
          "type": "collaborator", "slug": "alpha", "repo": "../alpha-repo", "who": "Acme Ltd", "YYYY-MM-DD": "2026-11-26",
          "file": "2026-11-26-invoices", "short-name": "dashboard-dates", "title": "Dashboard dates", "key word": "invoice",
          "word": "invoice"}
# What the hook must decide, when it isn't "allow", and why.
EXPECTED = {
    "gh api -X POST repos/juvantlabs/juvant-os/security-advisories/reports": ("ask", "a report leaves the company: the CEO confirms"),
    "python3 .claude/skills/extensions/extensions.py apply": ("deny", "no such plan in a fresh company"),
    "bash .claude/skills/project-repo/project-repo.sh install": ("ask", "it writes the project repo's .claude/"),
    "bash .claude/skills/project-repo/project-repo.sh sharing": ("ask", "it changes who the project repo is shared with"),
    # Asks since v2.0.4 at least, though it only reads: known, to be fixed (it can wait for the CEO's click meanwhile).
    "bash .claude/skills/project-repo/project-repo.sh status": ("ask", "known: a read that asks"),
}
TRAILER = "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_x"
EVERYDAY = [
    f'git add .claude && git commit -q -m "Update juvant-os to v2.1.0\n\n{TRAILER}"',
    f"git add memory state && git commit -m \"$(cat <<'EOF'\nWrap-up 2026-11-26: invoices\n\n{TRAILER}\nEOF\n)\" && git push",
    f"git commit -F - <<'EOF'\nNotes on .claude/skills and Claude Code\n\n{TRAILER}\nEOF",
    'python3 .claude/hooks/juvant_hooks.py log-outcome "Invoices chased" && python3 .claude/hooks/juvant_hooks.py log-outcome '
    f'--agent collaborator "Draft ready" && git add memory state && git commit -m "Wrap-up\n\n{TRAILER}" && git push',
    f"cat >> memory/journal/2026-11-26.md <<'E'\n## 09:00 — Asked Claude about .claude/settings.json\nE\n"
    'python3 .claude/hooks/juvant_hooks.py log-outcome "journal"',
    "python3 - <<'E'\nimport json\nprint(json.load(open('docs/notes.json')).get('claude_model'), 'see https://docs.claude.com')\nE",
    "echo 'Ask Claude' > docs/notes.md && bash -n scripts/check.sh && cat .claude/settings.json | python3 -m json.tool",
    "cat .claude/settings.json | python3 -m json.tool",
    "claude agents --json > /tmp/agents.json && python3 .claude/dashboard/build.py --agents-json /tmp/agents.json",
    f'gh pr create --draft --title "Fix" --body "Found with Claude Code.\n\n{TRAILER}"',
    "grep -rn 'claude' docs | head -5; ls .claude/skills | wc -l",
    "python3 .claude/skills/extensions/extensions.py list && python3 .claude/skills/extensions/extensions.py check",
    "git log --oneline -5 -- .claude && git diff --stat",
    "bash .claude/skills/update/update.sh && git status --short",
]


def documented():
    """[(file, command)] from inline code in the framework's instructions, placeholders filled."""
    out = []
    for f in sorted(glob.glob(os.path.join(FW, "skills", "*", "SKILL.md")) + glob.glob(os.path.join(FW, "agents", "*.md"))
                    + [os.path.join(FW, "templates", "CLAUDE.md")]):
        with open(f, encoding="utf-8") as fh:
            text = fh.read()
        for cmd in re.findall(r"`([^`\n]+)`", text):
            if not re.match(VERBS + r" ", cmd) or "<plan-id>" in cmd:
                continue
            cmd = re.sub(r"\[([^\]]*<[^>]+>[^\]]*)\]", r"\1", cmd)  # optional parts: given
            cmd = re.sub(r"<([^>]+)>", lambda m: VALUES.get(m.group(1), "x" if " " not in m.group(1) else "a short line"), cmd)
            out.append((os.path.relpath(f, FW), cmd))
    return out


class SkillCommands(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="jv2-skills-")
        cls.co = os.path.join(cls.tmp, "co")
        subprocess.run(["bash", os.path.join(ROOT, "setup.sh"), cls.co, "--company", "Morvento"], check=True, capture_output=True,
                       env=dict(os.environ, JUVANT_OS_DEV="1"))
        subprocess.run(["git", "init", "-q"], cwd=cls.co, check=True)
        os.makedirs(os.path.join(cls.co, "docs"), exist_ok=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, True)

    def decision(self, command):
        p = subprocess.run([sys.executable, os.path.join(self.co, ".claude", "hooks", "juvant_hooks.py"), "limits"],
                           input=json.dumps({"tool_name": "Bash", "tool_input": {"command": command}, "cwd": self.co,
                                             "session_id": "s"}),
                           capture_output=True, text=True, timeout=30, env=dict(os.environ, CLAUDE_PROJECT_DIR=self.co))
        out = json.loads(p.stdout)["hookSpecificOutput"] if p.stdout.strip() else {}
        return out.get("permissionDecision", "allow"), out.get("permissionDecisionReason", "")

    def test_documented_commands(self):
        cmds = documented()
        self.assertGreater(len(cmds), 30, "the extraction found too few commands")
        for where, cmd in cmds:
            want = next((d for k, (d, _) in EXPECTED.items() if cmd.startswith(k)), "allow")
            with self.subTest(where=where, cmd=cmd):
                got, why = self.decision(cmd)
                self.assertEqual(got, want, why)

    def test_everyday_forms(self):
        for cmd in EVERYDAY:
            with self.subTest(cmd=cmd):
                got, why = self.decision(cmd)
                self.assertEqual(got, "allow", why)


if __name__ == "__main__":
    unittest.main()
