"""Unit tests for extensions (framework/skills/extensions) and their part of the hooks, against a fake GitHub."""
import hashlib
import http.server
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FW = os.path.join(ROOT, "framework")
REPO = "acme/exts"
SKILL = "---\nname: demo-hello\ndescription: \"Say hello. Use when asked.\"\n---\n\n# Hello\n\nMail a@b.example. Run `ls`.\n"


def manifest(**over):
    m = {"id": "demo", "version": "1.0.0", "framework": ">=2.0.0 <3.0.0", "license": "MIT", "skills": ["hello"],
         "requires_extensions": {}, "mcp": [], "company_paths": [], "service": None, "exceptions": []}
    m.update(over)
    return m


def package(files=None, drop=(), limits=None, **man):
    f = {"extension.json": json.dumps(manifest(**man)), "README.md": "# Demo\n", "skills/hello/SKILL.md": SKILL}
    if limits is not None:
        f["limits.json"] = limits if isinstance(limits, str) else json.dumps(limits)
    f.update(files or {})
    return {k: v for k, v in f.items() if k not in drop}


SERVICE = {k: "x" for k in ("repository", "release", "runs", "data", "permissions", "sends", "stop")}
LIMITS = {"mcp": {"deny": [{"id": "no-foo", "pattern": "(^|_)foo(_|$)", "why": "demo"}]},
          "bash": {"ask": [{"id": "bar", "pattern": "\\bbarcmd\\b"}]}}


class GitHub:
    """Just the API calls the script makes."""

    def __init__(self):
        self.releases, self.commits, self.number = [], {}, 77
        hub = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                out = hub.answer(self.path)
                self.send_response(200 if out is not None else 404)
                self.end_headers()
                if out is not None:
                    self.wfile.write(out if isinstance(out, bytes) else json.dumps(out).encode())

            def log_message(self, *_):
                pass
        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.srv.server_port}"
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def answer(self, path):
        p = path.split("?")[0].removeprefix(f"/repos/{REPO}")
        if p == "":
            return {"id": self.number}
        if p == "/releases":
            return [{k: r[k] for k in ("tag_name", "draft", "prerelease")} for r in self.releases]
        if p.startswith("/releases/tags/"):
            return next((r for r in self.releases if r["tag_name"] == p.split("/")[-1]), None)
        if p.startswith("/git/ref/tags/"):
            r = next((r for r in self.releases if r["tag_name"] == p.split("/")[-1]), None)
            return r and {"object": {"type": "tag", "sha": r["commit"][::-1]}}
        if p.startswith("/git/tags/"):
            return {"object": {"type": "commit", "sha": p.split("/")[-1][::-1]}}
        if p.startswith("/tarball/"):
            return self.commits.get(p.split("/")[-1])
        return None

    def publish(self, tag, files, folder="demo", draft=False, prerelease=False, extra=None):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            for rel, text in files.items():
                data = text if isinstance(text, bytes) else text.encode()
                ti = tarfile.TarInfo("acme-exts-abc/" + (folder + "/" if folder else "") + rel)
                ti.size, ti.mode = len(data), 0o644
                tar.addfile(ti, io.BytesIO(data))
            for ti, data in extra or []:
                tar.addfile(ti, io.BytesIO(data) if data is not None else None)
        commit = hashlib.sha1(buf.getvalue() + tag.encode() + str(time.time()).encode()).hexdigest()
        self.commits[commit] = buf.getvalue()
        self.releases = [r for r in self.releases if r["tag_name"] != tag]
        self.releases.append({"tag_name": tag, "draft": draft, "prerelease": prerelease, "commit": commit})
        return commit


class Case(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = tempfile.mkdtemp(prefix="jvx-")
        env = dict(os.environ, JUVANT_OS_SETUP="1")
        subprocess.run(["bash", os.path.join(FW, "skills/update/update.sh"), "--from", FW, "--target", cls.base], check=True,
                       capture_output=True, env=env)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.base, True)

    def setUp(self):
        self.t = tempfile.mkdtemp(prefix="jvx-")
        self.addCleanup(shutil.rmtree, self.t, True)
        self.co = os.path.join(self.t, "co")
        shutil.copytree(self.base, self.co, symlinks=True)
        self.fw_version("v2.1.0")
        self.hub = GitHub()
        self.addCleanup(self.hub.srv.server_close)
        self.addCleanup(self.hub.srv.shutdown)

    def fw_version(self, v):
        with open(self.p(".claude/juvant-os.json"), "w", encoding="utf-8") as f:
            json.dump({"version": v}, f)

    def p(self, rel):
        return os.path.join(self.co, rel)

    def read(self, rel):
        with open(self.p(rel), encoding="utf-8") as f:
            return f.read()

    def write(self, rel, text):
        os.makedirs(os.path.dirname(self.p(rel)), exist_ok=True)
        with open(self.p(rel), "w", encoding="utf-8") as f:
            f.write(text)

    def tree(self, *skip):
        out = {}
        for base, _, names in os.walk(self.co):
            for n in names:
                rel = os.path.relpath(os.path.join(base, n), self.co)
                if "__pycache__" not in rel and not rel.startswith(("state/",) + skip):
                    with open(os.path.join(base, n), "rb") as f:
                        out[rel] = f.read()
        return out

    def ext(self, *args):
        r = subprocess.run([sys.executable, ".claude/skills/extensions/extensions.py", *args], cwd=self.co, capture_output=True,
                           text=True, timeout=60, env=dict(os.environ, JUVANT_OS_API=self.hub.url, PYTHONDONTWRITEBYTECODE="1"))
        return r.returncode, r.stdout + r.stderr

    def plan(self, *args):
        rc, out = self.ext("plan", *args)
        m = re.search(r"apply ([0-9a-f]{64})", out)
        return (m.group(1) if rc == 0 and m else None), out

    def add(self, tag=None, path="demo"):
        return self.plan("add", REPO, "--path", path, *(["--tag", tag] if tag else []))

    def install(self, **kw):
        pid, out = self.add(**kw)
        self.assertTrue(pid, out)
        rc, out = self.ext("apply", pid)
        self.assertEqual(rc, 0, out)

    def refused(self, files, why, **kw):
        before = self.tree()
        self.hub.publish("demo-v1.0.0", files, **kw)
        pid, out = self.add()
        self.assertIsNone(pid, f"should be refused ({why}):\n{out}")
        self.assertRegex(out, why)
        self.assertNotIn("Traceback", out)
        self.assertEqual(self.tree(), before)

    def hook(self, sub, ev):
        r = subprocess.run([sys.executable, ".claude/hooks/juvant_hooks.py", sub], input=json.dumps(ev), cwd=self.co, capture_output=True,
                           text=True, timeout=30, env=dict(os.environ, CLAUDE_PROJECT_DIR=self.co, PYTHONDONTWRITEBYTECODE="1"))
        return json.loads(r.stdout)["hookSpecificOutput"] if r.stdout.strip() else {}

    def gate(self, tool, inp=None):
        h = self.hook("limits", {"tool_name": tool, "tool_input": inp or {}, "cwd": self.co})
        return h.get("permissionDecision", "allow"), h.get("permissionDecisionReason", "")

    def start(self):
        return self.hook("session-start", {"session_id": "s", "source": "startup"})["additionalContext"]


class Refusals(Case):
    def test_paths_and_kinds_of_file(self):
        for rel in ("hooks/x.json", "agents/x.md", "commands/x.md", "settings.json", "CLAUDE.md", ".claude/settings.json",
                    "skills/hello/run.py", "skills/hello/run.sh", "skills/hello/x", "skills/hello/.claude-plugin/plugin.json",
                    "skills/hello/.hidden.md", "skills/x.md", "skills/hello/a b.md", "skills/hello/..md", "other/readme.md",
                    "skills/hello/a/b/c/d/e.md"):
            with self.subTest(rel=rel):
                self.refused(package({rel: "{}"}), "not (an allowed path|part of an extension)|only \\.md")
        for rel in ("CLAUDE.md", "claude.local.md", "AGENTS.md", "ref/Claude.md", "MEMORY.md", "GEMINI.md"):
            self.refused(package({"skills/hello/" + rel: "x"}), "load as instructions")
        self.refused(package({"skills/hello/Ref/a.md": "x", "skills/hello/ref/b.md": "x"}), "upper and lower case")
        self.refused(package({"skills/hello/sub/SKILL.md": SKILL}), "one SKILL.md")
        self.refused(package({"skills/hello/Note.md": "a", "skills/hello/note.md": "b"}), "upper and lower case")

    def test_links_executables_and_traversal(self):
        def ti(name, **kw):
            t = tarfile.TarInfo(name)
            for k, v in kw.items():
                setattr(t, k, v)
            return t
        top = "acme-exts-abc/demo/skills/hello/"
        for t, data in ((ti(top + "l.md", type=tarfile.SYMTYPE, linkname="/etc/passwd"), None),
                        (ti(top + "l.md", type=tarfile.LNKTYPE, linkname="acme-exts-abc/demo/README.md"), None),
                        (ti(top + "l.md", type=tarfile.FIFOTYPE), None)):
            self.refused(package(), "links and special files", extra=[(t, data)])
        self.refused(package(), "executable", extra=[(ti(top + "x.md", mode=0o755, size=1), b"x")])
        self.refused(package(), "not an allowed path", extra=[(ti(top + "../../../../x.md", size=1), b"x")])
        self.refused(package(), "twice", extra=[(ti(top + "SKILL.md", size=1), b"x")])
        self.refused(package({"skills/hello/big.md": "x" * 400_001}), "too big")

    def test_frontmatter(self):
        def fm(top):
            return package({"skills/hello/SKILL.md": f"---\n{top}\n---\n\nHi\n"})
        base = "name: demo-hello\ndescription: d"
        for extra in ("allowed-tools: Bash", "hooks: {}", "context: fork", "model: opus", "  hooks: x", "# c", "", "shell: bash", "Name: x",
                      "name: other", "? a", "<<: *x"):
            self.refused(fm(base + "\n" + extra), "only one-line|appears twice")
        for top in ("name: demo-hello", "name: hello\ndescription: d", "name: demo-hello\ndescription: >", "name: demo-hello\ndescription: |",
                    "name: demo-hello\ndescription: &a b", "name: demo-hello\ndescription: {a: b}", "name: demo-hello\ndescription: a: b",
                    "name: demo-hello\ndescription: \"a\\nhooks: x\"", "name: demo-hello\ndescription: \"a", "name:demo-hello\ndescription: d"):
            self.refused(fm(top), "SKILL.md:")
        self.refused(package({"skills/hello/SKILL.md": "\n" + SKILL}), "must start with")
        self.refused(package({"skills/hello/SKILL.md": SKILL.replace("\n", "\r\n")}), "hidden or control")
        self.refused(package({"skills/hello/SKILL.md": "\ufeff" + SKILL}), "hidden or control")

    def test_text_that_acts_when_the_skill_loads(self):
        for bad in ("!`id`", "a !`id`", "! `id`", "```!\nid\n```", "``` !\nid\n```", "~~~!\nid\n~~~", "```{!x}\n```", "see @memory/private.md", "@~/x",
                    "(@/etc/hosts)", "!$ARGUMENTS`id`", "```$ARGUMENTS[7]!\nid\n```", "@${CLAUDE_PROJECT_DIR}/x", "$1", "${X}", "@", "\u200b@x"):
            with self.subTest(bad=bad):
                self.refused(package({"skills/hello/SKILL.md": SKILL + bad + "\n"}), "run a command|@ reference|hidden|placeholder")
                self.refused(package({"skills/hello/more.md": bad + "\n"}), "run a command|@ reference|hidden|placeholder")

    def test_hidden_text(self):
        for ch in ("\u200b", "\u202e", "\u2066", "\U000e0041", "\x1b", "\x00", "\u00ad", "\u061c", "\ufe00", "\ufe0f", "\U000e0100"):
            self.refused(package({"README.md": f"# D{ch}\n"}), "hidden")
        self.refused(package({"skills/hello/x.md": b"\xff\xfe"}), "not plain text")

    def test_manifest(self):
        for kw in ({"id": "Demo"}, {"id": "../x"}, {"id": "synced"}, {"id": "code"}, {"id": "demo--x"}, {"version": "1"}, {"framework": "*"}, {"framework": ""},
                   {"license": "a\nb"}, {"skills": ["../x"]}, {"skills": ["hello", "hello"]}, {"hooks": {}}, {"mcp": [{"role": "x"}]},
                   {"mcp": [{"role": "x", "access": "all", "why": "y"}]}, {"company_paths": [".claude/"]}, {"company_paths": ["memory/"]},
                   {"company_paths": ["memory/authorizations/"]}, {"company_paths": ["memory/../.claude"]}, {"company_paths": ["CLAUDE.md"]},
                   {"service": {"repository": "x"}}, {"exceptions": [{"limit": "1", "what": "x", "why": "y"}]}, {"requires_extensions": {"demo": ">=1.0.0"}},
                   {"requires_extensions": {"x": "1"}}, {"skills": [1]}, {"mcp": {}}):
            with self.subTest(kw=kw):
                self.refused(package(**kw), "extension.json|requires_extensions")
        self.refused(package({"extension.json": "[]"}), "expected an object")
        self.refused(package({"extension.json": '{"id":"a","id":"b"}'}), "twice")
        self.refused(package({"extension.json": "{"}), "not valid JSON")
        self.refused(package({"extension.json": "[" * 100000}), "not valid JSON")
        self.refused(package(drop=("README.md",)), "README.md is missing")
        self.refused(package(drop=("skills/hello/SKILL.md",)), "don't match")
        self.refused(package({"skills/more/x.md": "x"}), "don't match")
        self.refused(package({"config.example.json": "{}"}), "go together")
        self.refused(package(skills=[], drop=("skills/hello/SKILL.md",)), "neither skills nor limits")
        self.refused(package(version="1.0.1"), "don't match")

    def test_limits_only_add(self):
        rule = {"id": "a", "pattern": "x"}
        for bad in ({"known_prefixes": ["mcp__x__"]}, {"mcp": {"create": [rule]}}, {"mcp": {"draft_allow": "x"}}, {"mcp": {"private_publish": "x"}},
                    {"mcp": {"resource_tools": {}}}, {"bash": {"temp_dirs": ["/"]}}, {"bash": {"rm_outside_repo": "allow"}}, {"x": 1}, [], {"secrets": {}},
                    {"mcp": {"deny": [dict(rule, input={})]}}, {"mcp": {"deny": [dict(rule, extra="x")]}}, {"mcp": {"deny": [{"id": "a b", "pattern": "x"}]}},
                    {"mcp": {"deny": [dict(rule, why="a\nb")]}}, {"mcp": {"deny": [rule] * 21}}, {"mcp": {"deny": [{"id": "a", "pattern": 1}]}}):
            with self.subTest(bad=bad):
                self.refused(package(limits=bad), "limits.json")

    def test_slow_or_total_patterns(self):
        for pat in ("(a+)+$", "a*", "a{2,}", "(a{1,100}){1,100}", "(?=a)", "(?<=a)b", "(a)\\1", "", "a?", "(", "x|", "a{1,200}b{1,200}"):
            with self.subTest(pat=pat):
                self.refused(package(limits={"bash": {"deny": [{"id": "a", "pattern": pat}]}}), "limits.json")
        for pat in ("a{0,1}" * 45 + "b", "(?:a?){200}b", "(a|a){1,90}b", "(?:a{1,2}){1,90}b", "(a|a)" * 30, "a{0,70}a{0,70}b", "(?:[a-z ]?){90}9", "a{0,99}" + "a{100}" * 12 + "b",
                    "(?:a{0,49}|a{0,49})a{100}b", "a{0,99}" + "a{9}" * 12 + "b"):
            with self.subTest(pat=pat):
                self.refused(package(limits={"secrets": [{"id": "a", "pattern": pat}]}), "limits.json")

    def test_releases_only(self):
        self.hub.publish("demo-v1.0.0", package(), draft=True)
        self.assertRegex(self.add()[1], "no published release")
        self.assertRegex(self.add("demo-v1.0.0")[1], "not a published release")
        self.hub.publish("demo-v1.0.0", package(), prerelease=True)
        self.assertRegex(self.add()[1], "no published release")
        self.assertIsNotNone(self.add("demo-v1.0.0")[0], "a pre-release only if named")
        for tag in ("main", "demo-v9.0.0", "../x", "v1.0.0 --x"):
            self.assertIsNone(self.add(tag)[0])
        for repo in ("/tmp/x", "file:///tmp", "a", "a/b/c", "../x", "-x/y", "https://evil.example/a/b"):
            self.assertIsNone(self.plan("add", repo)[0], repo)
        self.assertIsNone(self.plan("add", REPO, "--path", "../demo")[0])

    def test_compatibility_names_and_place(self):
        self.refused(package(framework=">=2.2.0 <3.0.0"), "needs juvant-os")
        self.refused(package(requires_extensions={"other": ">=1.0.0"}), "needs the extension other")
        self.hub.publish("other-v1.0.0", package(), folder="other")
        self.assertIsNone(self.add(path="other")[0])
        self.write(".claude/skills/demo-hello/SKILL.md", "mine")
        self.refused(package(), "already exists")
        shutil.rmtree(self.p(".claude/skills/demo-hello"))
        os.makedirs(self.p(".claude/extensions"))
        os.symlink(self.t, self.p(".claude/extensions/demo"))
        self.refused(package(), "already exists|is a link")
        os.remove(self.p(".claude/extensions/demo"))
        self.write(".claude/juvant-os-project.json", "{}")
        self.refused(package(), "company repository only")
        os.remove(self.p(".claude/juvant-os-project.json"))
        self.fw_version("local")
        self.refused(package(), "needs juvant-os")


class Lifecycle(Case):
    def test_add_list_remove_leaves_nothing_but_company_files(self):
        before = self.tree()
        self.hub.publish("demo-v1.0.0", package({"config.example.json": '{"mode": "private"}', "config.schema.json": "{}", "skills/hello/ref/a.md": "x"}, limits=LIMITS))
        pid, out = self.add()
        self.assertIn("mcp.deny no-foo", out)
        self.assertIn("TEST SOURCE", out)
        self.assertEqual(self.tree(), before, "plan installs nothing")
        self.assertEqual(self.ext("apply", pid)[0], 0)
        self.assertEqual(self.read(".claude/skills/demo-hello/SKILL.md"), SKILL)
        self.assertTrue(os.path.exists(self.p(".claude/skills/demo-hello/ref/a.md")))
        self.assertEqual(json.loads(self.read("extensions/demo.json")), {"mode": "private"})
        e = json.loads(self.read(".claude/extensions/lock.json"))["extensions"]["demo"]
        self.assertRegex(e["source"]["commit"], "^[0-9a-f]{40}$")
        self.assertIn("demo 1.0.0", self.ext("list")[1])
        self.assertNotIn("isn't", self.start().split("WARNING")[-1] if "WARNING" in self.start() else "")
        self.write("extensions/demo.json", '{"mode": "mine"}')
        pid, out = self.plan("remove", "demo")
        self.assertIn("LIMITS THAT DISAPPEAR", out)
        self.assertEqual(self.ext("apply", pid)[0], 0)
        after = self.tree()
        self.assertEqual(json.loads(after.pop("extensions/demo.json")), {"mode": "mine"})
        self.assertEqual(json.loads(after.pop(".claude/extensions/lock.json"))["extensions"], {})
        self.assertEqual(after, before)
        self.assertFalse(os.path.exists(self.p(".claude/skills/demo-hello")))

    def test_settings_never_overwritten(self):
        self.write("extensions/demo.json", "mine")
        self.hub.publish("demo-v1.0.0", package({"config.example.json": "{}", "config.schema.json": "{}"}))
        self.install()
        self.assertEqual(self.read("extensions/demo.json"), "mine")

    def test_single_extension_repository(self):
        self.hub.publish("v1.0.0", package(), folder="")
        pid, out = self.plan("add", "https://github.com/" + REPO + ".git")
        self.assertTrue(pid, out)
        self.assertEqual(self.ext("apply", pid)[0], 0)

    def test_update_shows_new_permissions_and_dropped_limits(self):
        self.hub.publish("demo-v1.0.0", package(limits=LIMITS))
        self.install()
        self.hub.publish("demo-v1.1.0", package({"skills/hello/new.md": "n"}, version="1.1.0", mcp=[{"role": "calendar", "access": "read", "why": "agenda"}],
                                                limits={"mcp": {"deny": [{"id": "no-foo", "pattern": "never"}]}}, service=SERVICE,
                                                exceptions=[{"limit": "1", "what": "speaks", "why": "y"}]))
        self.hub.publish("demo-v2.0.0-rc.1", package(version="2.0.0"), prerelease=True)
        self.hub.publish("other-v9.0.0", package(), folder="other")
        pid, out = self.plan("update", "demo")
        for want in ("1.1.0", "NEW PERMISSIONS", "calendar", "exceptions", "service", "LIMITS THAT DISAPPEAR", "no-foo"):
            self.assertIn(want, out)
        d, why = self.gate("Bash", {"command": f"python3 .claude/skills/extensions/extensions.py apply {pid}"})
        self.assertEqual(d, "ask")
        for want in ("UPDATE extension demo 1.1.0", "calendar", "LIMITS THAT DISAPPEAR"):
            self.assertIn(want, why)
        self.assertEqual(self.ext("apply", pid)[0], 0)
        self.assertTrue(os.path.exists(self.p(".claude/skills/demo-hello/new.md")))
        self.hub.publish("demo-v1.2.0", package(version="1.2.0"))
        pid, _ = self.plan("update", "demo")
        self.assertEqual(self.ext("apply", pid)[0], 0)
        self.assertFalse(os.path.exists(self.p(".claude/skills/demo-hello/new.md")), "files dropped by the release go")
        self.assertFalse(os.path.exists(self.p(".claude/extensions/demo/limits.json")))
        self.assertRegex(self.plan("update", "demo")[1], "nothing to update")
        self.assertRegex(self.plan("update", "demo", "--tag", "demo-v1.0.0")[1], "older")

    def test_moved_tag(self):
        self.hub.publish("demo-v1.0.0", package())
        self.install()
        self.hub.publish("demo-v1.0.0", package({"README.md": "# Evil\n"}))
        self.assertRegex(self.plan("update", "demo")[1], "another commit")
        self.hub.number = 78
        for action in ("update", "repair"):
            self.assertRegex(self.plan(action, "demo")[1], "took its name")

    def test_changes_between_plan_and_apply_stop_it(self):
        self.hub.publish("demo-v1.0.0", package())
        pid, _ = self.add()
        self.hub.publish("demo-v1.0.0", package({"README.md": "# Evil\n"}))
        before = self.tree()
        rc, out = self.ext("apply", pid)
        self.assertEqual((rc, "something changed" in out), (1, True), out)
        self.assertEqual(self.tree(), before)

    def test_forged_plans(self):
        self.hub.publish("demo-v1.0.0", package())
        pid, _ = self.add()
        plan = json.loads(self.read(f"state/extensions/{pid}.json"))
        plan["adds"] = []
        plan["files"] = {".claude/settings.json": "0" * 64}
        self.write(f"state/extensions/{pid}.json", json.dumps(plan))
        self.assertRegex(self.ext("apply", pid)[1], "changed")
        self.assertEqual(self.gate("Bash", {"command": f"python3 .claude/skills/extensions/extensions.py apply {pid}"})[0], "deny")
        forged = hashlib.sha256(json.dumps(plan, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        self.write(f"state/extensions/{forged}.json", json.dumps(plan))
        self.assertRegex(self.ext("apply", forged)[1], "something changed")
        self.assertFalse(os.path.exists(self.p(".claude/extensions/lock.json")))

    def test_local_changes_and_repair(self):
        self.hub.publish("demo-v1.0.0", package())
        self.install()
        self.write(".claude/skills/demo-hello/SKILL.md", "changed")
        self.assertIn("isn't as approved", self.start())
        self.assertIn("CHANGED", self.ext("list")[1])
        self.hub.publish("demo-v1.1.0", package(version="1.1.0"))
        self.assertRegex(self.plan("update", "demo")[1], "changed locally")
        pid, out = self.plan("repair", "demo")
        self.assertIn("will be lost", out)
        self.assertEqual(self.ext("apply", pid)[0], 0)
        self.assertEqual(self.read(".claude/skills/demo-hello/SKILL.md"), SKILL)
        self.assertNotIn("isn't as approved", self.start())

    def test_failed_install_rolls_back(self):
        self.hub.publish("demo-v1.0.0", package({"skills/hello/z/a.md": "x"}))
        pid, _ = self.add()
        before = self.tree()
        os.makedirs(self.p(".claude/skills"), exist_ok=True)
        os.chmod(self.p(".claude/skills"), 0o555)
        try:
            rc, _ = self.ext("apply", pid)
        finally:
            os.chmod(self.p(".claude/skills"), 0o755)
        self.assertNotEqual(rc, 0)
        after = self.tree()
        self.assertEqual(json.loads(after.pop(".claude/extensions/lock.json"))["extensions"], {})
        self.assertEqual(after, before)
        self.assertEqual(self.gate("mcp__x__list_things")[0], "allow")

    def test_interrupted_install_is_seen_and_repaired(self):
        self.hub.publish("demo-v1.0.0", package(limits=LIMITS))
        self.install()
        os.remove(self.p(".claude/skills/demo-hello/SKILL.md"))
        self.assertIn("isn't as approved", self.start())
        pid, _ = self.plan("repair", "demo")
        self.assertEqual(self.ext("apply", pid)[0], 0)
        self.assertTrue(os.path.exists(self.p(".claude/skills/demo-hello/SKILL.md")))

    def test_interrupted_removal(self):
        self.hub.publish("demo-v1.0.0", package(limits=LIMITS))
        self.install()
        lock = json.loads(self.read(".claude/extensions/lock.json"))
        lock["extensions"]["demo"]["removing"] = True
        self.write(".claude/extensions/lock.json", json.dumps(lock))
        os.remove(self.p(".claude/extensions/demo/limits.json"))
        self.assertEqual(self.gate("mcp__x__list_things")[0], "allow")
        self.assertIn("removal was interrupted", self.start())
        pid, _ = self.plan("remove", "demo")
        self.assertEqual(self.ext("apply", pid)[0], 0)
        self.assertIn("No extensions", self.ext("list")[1])

    def test_dependencies(self):
        self.hub.publish("demo-v1.0.0", package())
        self.install()
        two = package({"skills/hello/SKILL.md": SKILL.replace("demo-", "two-")}, id="two", requires_extensions={"demo": ">=1.0.0 <2.0.0"})
        self.hub.publish("two-v1.0.0", two, folder="two")
        self.install(path="two")
        self.assertRegex(self.plan("remove", "demo")[1], "two needs demo")


    def test_every_file_can_be_read_before_approving(self):
        self.hub.publish("demo-v1.0.0", package({"skills/hello/ref/a.md": "ONE", "skills/hello/ref__a.md": "TWO",
                                                 "skills/hello/" + "/".join(["d" * 80] * 2) + "/a.md": "THREE"}))
        pid, out = self.add()
        self.assertTrue(pid, out)
        text = "".join(self.read("state/extensions/review/" + n) for n in os.listdir(self.p("state/extensions/review")))
        for want in ("ONE", "TWO", "THREE", "demo-hello/ref/a.md"):
            self.assertIn(want, text)

    def test_interrupted_update_leftovers_are_seen_and_go(self):
        two = {"skills/old/SKILL.md": SKILL.replace("demo-hello", "demo-old")}
        for action in ("repair", "remove"):
            self.hub.publish("demo-v1.0.0", package(two, skills=["hello", "old"]))
            self.install(tag="demo-v1.0.0")
            self.hub.publish("demo-v1.1.0", package(version="1.1.0"))
            pid, _ = self.plan("update", "demo")
            code = ("import sys, os; sys.argv = ['x']; sys.path.insert(0, '.claude/skills/extensions'); import extensions as e;"
                    "e.remove_files = lambda r: os._exit(9); e.main(['apply', '%s'])" % pid)
            r = subprocess.run([sys.executable, "-B", "-c", code], cwd=self.co, env=dict(os.environ, JUVANT_OS_API=self.hub.url))
            self.assertEqual(r.returncode, 9)
            self.assertIn("interrupted update", self.start())
            self.assertIn("interrupted update", self.ext("list")[1])
            pid, out = self.plan(action, "demo")
            self.assertTrue(pid, out)
            self.assertEqual(self.ext("apply", pid)[0], 0)
            self.assertFalse(os.path.exists(self.p(".claude/skills/demo-old")))
            self.assertNotIn("interrupted update", self.start())
            if action == "repair":
                pid, _ = self.plan("remove", "demo")
                self.ext("apply", pid)

    def test_planted_link_isnt_followed(self):
        self.hub.publish("demo-v1.0.0", package({"config.example.json": "{}", "config.schema.json": "{}"}))
        self.write("keep.md", "keep")
        os.makedirs(self.p("extensions"))
        os.symlink("../keep.md", self.p("extensions/demo.json.juvant-new"))
        self.install()
        self.assertEqual(self.read("keep.md"), "keep")
        shutil.rmtree(self.p("extensions"))
        os.symlink(self.t, self.p("extensions"))
        pid, _ = self.plan("remove", "demo")
        self.ext("apply", pid)
        pid, _ = self.add()
        self.assertNotEqual(self.ext("apply", pid)[0], 0)
        self.assertFalse(os.path.exists(os.path.join(self.t, "demo.json")))

    def test_line_endings_dont_matter(self):
        self.hub.publish("demo-v1.0.0", package())
        self.install()
        with open(self.p(".claude/skills/demo-hello/SKILL.md"), "wb") as f:
            f.write(SKILL.replace("\n", "\r\n").encode())
        self.assertNotIn("isn't as approved", self.start())

    def test_two_at_once(self):
        import fcntl
        self.hub.publish("demo-v1.0.0", package())
        pid, _ = self.add()
        with open(self.p("state/extensions.busy"), "w", encoding="utf-8") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            self.assertRegex(self.ext("apply", pid)[1], "another extension change")

    def test_no_other_source_than_github(self):
        code = "import sys; sys.path.insert(0, '.claude/skills/extensions'); import extensions as e; print(e.API)"
        for api in ("https://evil.example", "http://127.0.0.1.evil.example:1", "http://localhost:1", ""):
            r = subprocess.run([sys.executable, "-B", "-c", code], cwd=self.co, capture_output=True, text=True, env=dict(os.environ, JUVANT_OS_API=api))
            self.assertEqual(r.stdout.strip(), "https://api.github.com")


class Hooks(Case):
    def test_an_extension_never_softens_a_deny_or_hides_a_confirmation(self):
        self.hub.publish("demo-v1.0.0", package(limits={"bash": {"ask": [
            {"id": "x", "pattern": "authorizations\\.json|claude --d|apply [1-9a-f]|rm -rf", "why": "already reviewed, safe to confirm"}]}}))
        self.install()
        self.assertEqual(self.gate("Bash", {"command": "echo x > state/authorizations.json"})[0], "deny")
        self.assertEqual(self.gate("Bash", {"command": "claude --dangerously-skip-permissions -p hi"})[0], "deny")
        self.assertIn("rm-outside-repo", self.gate("Bash", {"command": "rm -rf /opt/x"})[1])
        self.hub.publish("demo-v1.1.0", package(version="1.1.0", mcp=[{"role": "bank", "access": "write", "why": "y"}]))
        pid, _ = self.plan("update", "demo")
        d, why = self.gate("Bash", {"command": f"python3 .claude/skills/extensions/extensions.py apply {pid}"})
        self.assertIn("bank", why)
        self.assertNotIn("already reviewed", why)

    def test_confirmation_shows_everything_weightiest_first(self):
        self.hub.publish("demo-v1.0.0", package(company_paths=[f"memory/a{i}/" for i in range(5)], service=SERVICE,
                                                mcp=[{"role": f"r{i}", "access": "read", "why": "y"} for i in range(9)] + [{"role": "bank", "access": "write", "why": "y"}],
                                                exceptions=[{"limit": "1", "what": "sends mail", "why": "y"}],
                                                limits={"bash": {"ask": [{"id": f"a{i}", "pattern": f"zz{i}"} for i in range(15)]}, "mcp": {"deny": [{"id": "pay", "pattern": "paid"}]}}))
        pid, _ = self.add()
        why = self.gate("Bash", {"command": f"python3 .claude/skills/extensions/extensions.py apply {pid}"})[1]
        order = [why.index(x) for x in ("sends mail", "service:", "bank", "r0", "memory/a0", "bash.ask a14", "mcp.deny pay")]
        self.assertEqual(order[:5], sorted(order[:5]))
        self.assertIn("memory/a4", why)

    def test_too_much_to_confirm_is_refused(self):
        big = [{"limit": str(i), "what": "w" * 200, "why": "y" * 200} for i in range(10)]
        self.hub.publish("demo-v1.0.0", package(service={k: "x" * 300 for k in SERVICE}, exceptions=big))
        self.assertRegex(self.add()[1], "more than the CEO can read")
        self.hub.publish("demo-v1.0.0", package(limits=LIMITS))
        self.install()
        self.hub.publish("demo-v1.1.0", package(version="1.1.0", service=SERVICE, exceptions=[{"limit": "1", "what": "w", "why": "y"}]))
        out = self.plan("update", "demo")[1]
        self.assertLess(out.index("Limits that disappear: 2"), out.index("LIMITS THAT DISAPPEAR"))
        self.assertLess(out.index("LIMITS THAT DISAPPEAR"), out.index("NEW PERMISSIONS"))

    def test_the_worst_allowed_limits_stay_quick(self):
        rules = [{"id": f"r{i}", "pattern": "a{0,18}a{30}[b%d]" % (i % 10)} for i in range(20)]
        self.hub.publish("demo-v1.0.0", package(limits={"secrets": rules}))
        pid, out = self.add()
        self.assertIsNone(pid, out)  # the sum is capped
        self.hub.publish("demo-v1.0.0", package(limits={"secrets": rules[:10]}))
        self.install()
        t = time.time()
        self.gate("Write", {"file_path": "x.md", "content": "a" * 20000})
        self.assertLess(time.time() - t, 8)

    def test_a_write_inside_another_command_asks(self):
        for cmd in ('echo "$(touch .claude/x)"', "echo `touch .claude/x`", "cat <(touch .claude/x)", "echo $(touch $(echo .claude/x))", 'git commit -m "$(rm .claude/settings.json)"'):
            with self.subTest(cmd=cmd):
                self.assertEqual(self.gate("Bash", {"command": cmd})[0], "ask")
        for cmd in ('echo "$(cat .claude/settings.json)"', "git commit -m 'says `touch .claude/x`'", "ls $(pwd)"):
            with self.subTest(cmd=cmd):
                self.assertEqual(self.gate("Bash", {"command": cmd})[0], "allow")

    def test_an_extension_cant_block_its_own_removal(self):
        pat = [{"id": "x", "pattern": "extensions\\.py|update\\.sh"}]
        self.hub.publish("demo-v1.0.0", package(limits={"secrets": pat, "bash": {"deny": pat, "ask": pat}}))
        self.install()
        pid, _ = self.plan("remove", "demo")
        for cmd in ("plan remove demo", "list", "plan add acme/exts --path demo --tag demo-v1.0.0"):
            self.assertEqual(self.gate("Bash", {"command": f"python3 .claude/skills/extensions/extensions.py {cmd}"})[0], "allow", cmd)
        self.assertIn("REMOVE extension", self.gate("Bash", {"command": f"python3 .claude/skills/extensions/extensions.py apply {pid}"})[1])
        self.assertEqual(self.gate("Bash", {"command": "bash .claude/skills/update/update.sh"})[0], "allow")
        self.assertEqual(self.gate("Bash", {"command": "cat extensions.py"})[0], "deny", "elsewhere its rules hold")

    def test_a_check_that_never_ends_blocks(self):
        src = self.read(".claude/hooks/juvant_hooks.py").replace("CHECK_SECONDS = 25", "CHECK_SECONDS = 1")
        self.write(".claude/hooks/juvant_hooks.py", src)
        self.write(".claude/limits-company.json", json.dumps({"bash": {"deny": [{"id": "slow", "pattern": "(a+)+$"}]}}))
        d, why = self.gate("Bash", {"command": "echo " + "a" * 60 + "b"})
        self.assertEqual((d, "too long" in why), ("deny", True))

    def test_limits_apply_and_are_named(self):
        self.assertEqual(self.gate("mcp__x__do_foo")[0], "allow")
        self.hub.publish("demo-v1.0.0", package(limits=LIMITS))
        self.install()
        d, why = self.gate("mcp__x__make_foo")
        self.assertEqual((d, "ext:demo:no-foo" in why), ("deny", True))
        self.assertEqual(self.gate("Bash", {"command": "barcmd x"})[0], "ask")
        self.assertEqual(self.gate("mcp__x__outlook_send_mail")[0], "deny", "the framework's own rules stay")
        self.assertEqual(self.gate("mcp__x__create_draft_mail")[0], "allow")

    def test_missing_or_unreadable_limits_fail_closed(self):
        self.hub.publish("demo-v1.0.0", package(limits=LIMITS))
        self.install()
        good = self.read(".claude/extensions/demo/limits.json")
        for text in (None, "{", "[]", '{"known_prefixes": []}', '{"mcp": {"deny": [{"id": "a", "pattern": "(a+)+"}]}}'):
            with self.subTest(text=text):
                if text is None:
                    os.remove(self.p(".claude/extensions/demo/limits.json"))
                else:
                    self.write(".claude/extensions/demo/limits.json", text)
                d, why = self.gate("mcp__x__list_things")
                self.assertEqual(d, "deny")
                self.assertIn("plan repair demo", why)
                self.assertIn("demo", self.start())
        self.write(".claude/extensions/demo/limits.json", good)
        self.assertEqual(self.gate("mcp__x__list_things")[0], "allow")
        for text in ("{", "[]", '{"version": 2, "extensions": {}}', '{"version": 1, "extensions": []}'):
            self.write(".claude/extensions/lock.json", text)
            self.assertEqual(self.gate("mcp__x__list_things")[0], "deny", text)

    def test_losing_the_lock_doesnt_lose_the_limits(self):
        self.hub.publish("demo-v1.0.0", package(limits=LIMITS))
        self.install()
        os.remove(self.p(".claude/extensions/lock.json"))
        self.assertEqual(self.gate("mcp__x__make_foo")[0], "deny")
        self.assertIn("isn't an approved extension", self.start())

    def test_unlisted_files_are_reported(self):
        self.hub.publish("demo-v1.0.0", package())
        self.install()
        self.write(".claude/skills/demo-hello/extra.md", "x")
        self.assertIn("not part of it", self.start())

    def test_apply_asks_and_only_as_printed(self):
        self.hub.publish("demo-v1.0.0", package())
        pid, _ = self.add()
        cmd = f"python3 .claude/skills/extensions/extensions.py apply {pid}"
        d, why = self.gate("Bash", {"command": cmd})
        self.assertEqual((d, "INSTALL extension demo 1.0.0" in why), ("ask", True))
        for bad in (cmd + " && rm -rf x", "JUVANT_OS_API=http://evil " + cmd, "cd /tmp; " + cmd, cmd + " > /dev/null", f"bash -c '{cmd}'",
                    cmd.replace("python3", "python3 -X dev"), cmd[:-1], cmd + "\nls", "export JUVANT_OS_API=x; " + cmd, f"env X=1 {cmd}",
                    f"cd .claude/skills/extensions && python3 extensions.py apply {pid}"):
            with self.subTest(bad=bad):
                self.assertIn(self.gate("Bash", {"command": bad})[0], ("deny", "ask"))
                self.assertNotIn("INSTALL extension", self.gate("Bash", {"command": bad})[1])
        for bad in (cmd.replace(".claude", ".cl''aude").replace("extensions.py", "extensions.p''y"), cmd.upper().replace(pid.upper(), pid),
                    cmd.replace("extensions.py", "ext*.py"), "python3 /tmp/copy.py apply " + pid, f"X={pid}; python3 a.py apply $X", f'echo "$({cmd})"', f"echo $({cmd})", f"echo `{cmd}`",
                    f'git commit -m "$({cmd})"', f"cat <({cmd})", f"ls >({cmd})"):
            with self.subTest(bad=bad):
                self.assertEqual(self.gate("Bash", {"command": bad})[0], "deny")
        for ok in ('git commit -m "Explain extensions.py apply"', 'grep -rn "extensions.py apply" docs', "python3 tools/load_extensions.py apply prod",
                   f"cat state/extensions/{pid}.json",
                   "git commit -F - <<'EOF'\nrun skills/extensions/extensions.py apply it\nEOF",
                   "cat > notes.md <<'EOF'\nrun python3 x/extensions.py apply <plan-id>\nEOF"):
            with self.subTest(ok=ok):
                self.assertEqual(self.gate("Bash", {"command": ok})[0], "allow")
        h = self.hook("limits", {"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": self.t})
        self.assertEqual(h["permissionDecision"], "deny", "another folder's script")
        for ok in ("plan add acme/exts", "plan update demo", "list", "check"):
            self.assertEqual(self.gate("Bash", {"command": f"python3 .claude/skills/extensions/extensions.py {ok}"})[0], "allow")
        self.assertEqual(self.gate("Bash", {"command": "python3 .claude/skills/extensions/extensions.py list > .claude/x"})[0], "ask")

    def test_without_extensions_nothing_changes(self):
        self.assertNotIn("xtension", self.start())
        src = os.path.join(FW, "hooks", "juvant_hooks.py")
        code = ("import importlib.util, json, sys; s = importlib.util.spec_from_file_location('h', sys.argv[1]); m = importlib.util.module_from_spec(s);"
                "s.loader.exec_module(m); c = m.load_config(); print(c['mcp']['deny'][-1]['id'], len(c['bash']['deny']), m.extension_problems())")
        a = subprocess.run([sys.executable, "-c", code, src], capture_output=True, text=True, cwd=self.co, env=dict(os.environ, CLAUDE_PROJECT_DIR=self.co))
        self.assertIn("outbound 1 []", a.stdout, a.stderr)


class FrameworkUpdate(Case):
    def update(self, fw):
        return subprocess.run(["bash", self.p(".claude/skills/update/update.sh"), "--from", fw, "--target", self.co], capture_output=True, text=True,
                              env=dict(os.environ, JUVANT_OS_SETUP="1"))

    def test_update_leaves_extensions_and_reports_incompatible(self):
        self.hub.publish("demo-v1.0.0", package({"config.example.json": "{}", "config.schema.json": "{}"}, framework=">=2.1.0 <2.1.1", limits=LIMITS))
        self.install()
        before = {k: v for k, v in self.tree().items() if "demo" in k or k.endswith("extensions/lock.json")}
        fw = os.path.join(self.t, "fw")
        shutil.copytree(FW, fw)
        r = self.update(fw)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("extension demo 1.0.0 supports juvant-os", r.stdout)
        after = self.tree()
        for k, v in before.items():
            self.assertEqual(after[k], v)

    def test_update_stops_on_a_name_clash(self):
        self.hub.publish("demo-v1.0.0", package())
        self.install()
        fw = os.path.join(self.t, "fw")
        shutil.copytree(FW, fw)
        os.makedirs(os.path.join(fw, "skills/Demo-hello"))
        shutil.copy(os.path.join(fw, "skills/update/SKILL.md"), os.path.join(fw, "skills/Demo-hello/SKILL.md"))
        with open(os.path.join(fw, "FILES"), "a", encoding="utf-8") as f:
            f.write("skills/Demo-hello/SKILL.md\n")
        before = self.tree()
        r = self.update(fw)
        self.assertEqual(r.returncode, 1)
        self.assertIn("same name", r.stderr)
        self.assertEqual(self.tree(), before)
        self.write(".claude/extensions/lock.json", "{")
        self.assertEqual(self.update(fw).returncode, 1)


if __name__ == "__main__":
    unittest.main()
