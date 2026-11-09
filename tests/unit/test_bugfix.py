"""Tests for framework/skills/bugfix/bugfix.py. Run: python3 -m unittest discover -s tests/unit"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ENV = dict(os.environ, JUVANT_OS_DEV="1", GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
           GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")


def run(cmd, cwd=None, env=None, check=True):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env or ENV)
    if check and p.returncode != 0:
        raise AssertionError(f"{cmd}: {p.stdout}{p.stderr}")
    return p


class Bugfix(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.t = tempfile.mkdtemp(prefix="jv2-bugfix-")
        # Upstream: a bare repo with only a v2 branch carrying framework/FILES.
        src = os.path.join(cls.t, "src")
        os.makedirs(src)
        shutil.copytree(os.path.join(ROOT, "framework"), os.path.join(src, "framework"))
        run(["git", "init", "-q", "-b", "v2", src])
        run(["git", "add", "-A"], cwd=src)
        run(["git", "commit", "-qm", "v2"], cwd=src)
        cls.upstream = os.path.join(cls.t, "up.git")
        run(["git", "clone", "-q", "--bare", src, cls.upstream])
        # A company with names, a GitHub owner, and git identity.
        cls.co = os.path.join(cls.t, "co")
        run(["bash", os.path.join(ROOT, "setup.sh"), cls.co, "--company", "Zephyrine Labs", "--ceo", "Ottavia Brun",
             "--cos", "Melisande", "--legal", "Quillon"])
        run(["git", "init", "-q", cls.co])
        run(["git", "remote", "add", "origin", "https://github.com/zephyrine-co/company.git"], cwd=cls.co)
        cls.env = dict(ENV, JUVANT_OS_REPO=cls.upstream)
        out = run([sys.executable, os.path.join(cls.co, ".claude/skills/bugfix/bugfix.py"), "prepare"], env=cls.env).stdout
        cls.clone = out.split("clone: ")[1].split("\n")[0]
        cls.base = out.split("base: ")[1].strip()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.t, True)
        shutil.rmtree(os.path.dirname(cls.clone), True)

    def check(self, body=None, extra=()):
        cmd = [sys.executable, os.path.join(self.co, ".claude/skills/bugfix/bugfix.py"), "check", self.clone]
        if body is not None:
            b = os.path.join(self.t, "body.md")
            with open(b, "w", encoding="utf-8") as f:
                f.write(body)
            cmd += ["--body", b]
        for e in extra:
            cmd += ["--term", e]
        return run(cmd, env=self.env, check=False)

    def edit(self, text):
        p = os.path.join(self.clone, "framework", "README.md")
        run(["git", "checkout", "-q", "--", "framework/README.md"], cwd=self.clone)
        with open(p, "a", encoding="utf-8") as f:
            f.write(text)

    def test_prepare_picks_the_v2_branch_and_keeps_state_out_of_git(self):
        self.assertEqual(self.base, "v2")
        self.assertTrue(os.path.isfile(os.path.join(self.clone, ".bugfix.json")))
        self.assertNotIn(".bugfix.json", run(["git", "status", "--porcelain"], cwd=self.clone).stdout)

    def test_generic_change_is_clean(self):
        self.edit("\nThe dashboard skill now publishes under the default limits.\n")
        p = self.check(body="Fix: the outbound rule blocked the artifact publish tools.\n")
        self.assertEqual(p.returncode, 0, p.stdout)

    def test_company_names_are_caught(self):
        cases = (("\nAs seen at Zephyrine Labs.\n", None, "company name"),
                 ("\nok\n", "Reported by Ottavia Brun.", "CEO's name"),
                 ("\nmelisande hit this\n", None, "Chief of Staff's name"),
                 ("\nQuillon flagged it\n", None, "agent name (legal)"),
                 ("\nsee zephyrine-co/website\n", None, "GitHub owner"),
                 (f"\npath {os.path.expanduser('~')}/x\n", None, "home path"),
                 ("\nfor the Northwind deal\n", None, "extra term"))
        for text, body, why in cases:
            with self.subTest(why=why):
                self.edit(text)
                p = self.check(body=body, extra=["Northwind"])
                self.assertEqual(p.returncode, 1, p.stdout)
                self.assertIn(why, p.stdout)

    def test_secrets_are_caught(self):
        self.edit("\ntoken ghp_" + "a" * 36 + "\n")
        p = self.check()
        self.assertEqual(p.returncode, 1)
        self.assertIn("secret-shaped text (github-token)", p.stdout)

    def test_no_change_is_not_clean(self):
        run(["git", "checkout", "-q", "--", "framework/README.md"], cwd=self.clone)
        self.assertEqual(self.check().returncode, 1)


if __name__ == "__main__":
    unittest.main()
