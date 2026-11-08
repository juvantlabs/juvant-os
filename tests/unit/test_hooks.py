"""Unit tests for framework/hooks/juvant_hooks.py. Run: python3 -m unittest discover -s tests/unit"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOOKS = os.path.join(ROOT, "framework", "hooks")
SCRIPT = os.path.join(HOOKS, "juvant_hooks.py")
P_LOCAL = "mcp__claude_ai_Microsoft_365__"
P_CLOUD = "mcp__Microsoft_365__"


class HookCase(unittest.TestCase):
    def setUp(self):
        self.repo = tempfile.mkdtemp(prefix="jv2-")
        self.addCleanup(shutil.rmtree, self.repo, True)

    def run_hook(self, sub, event, script=SCRIPT):
        env = dict(os.environ, CLAUDE_PROJECT_DIR=self.repo)
        p = subprocess.run([sys.executable, script, sub], input=json.dumps(event),
                           capture_output=True, text=True, env=env, timeout=20)
        out = json.loads(p.stdout) if p.stdout.strip() else {}
        return p.returncode, out, p.stderr

    def decision(self, tool, tool_input=None, script=SCRIPT):
        rc, out, _ = self.run_hook("limits", {"tool_name": tool, "tool_input": tool_input or {}}, script)
        d = out.get("hookSpecificOutput", {}).get("permissionDecision")
        if rc == 2:
            self.assertEqual(d, "deny", "exit 2 must come with a deny decision")
            return "deny"
        self.assertEqual(rc, 0)
        return d or "allow"

    def state(self, name):
        path = os.path.join(self.repo, "state", name)
        if not os.path.exists(path):
            return []
        with open(path, encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]


class McpLimits(HookCase):
    def test_outbound_denied_under_both_prefixes(self):
        for prefix in (P_LOCAL, P_CLOUD):
            for tool in ("outlook_send_mail", "outlook_send_draft", "outlook_forward_mail",
                         "outlook_set_vacation", "outlook_create_filter", "outlook_create_event",
                         "outlook_update_event", "outlook_respond_to_event", "teams_send_chat_message",
                         "teams_send_channel_message", "teams_reply_channel_message", "teams_create_chat"):
                with self.subTest(tool=prefix + tool):
                    self.assertEqual(self.decision(prefix + tool), "deny")

    def test_any_server_prefix(self):
        for tool in ("mcp__m365-graph__create_event", "mcp__m365-graph__cancel_event",
                     "mcp__m365-graph__decline_event", "mcp__social__publish_post", "mcp__x__send"):
            with self.subTest(tool=tool):
                self.assertEqual(self.decision(tool), "deny")

    def test_drafts_allowed(self):
        for tool in (P_CLOUD + "outlook_create_draft", P_LOCAL + "outlook_create_reply_draft",
                     P_LOCAL + "outlook_create_reply_all_draft", P_LOCAL + "outlook_update_draft",
                     "mcp__m365-mail__create_forward_draft", "mcp__m365-mail__create_reply_draft"):
            with self.subTest(tool=tool):
                self.assertEqual(self.decision(tool), "allow")

    def test_reads_allowed(self):
        for tool in ("outlook_email_search", "outlook_calendar_search", "sharepoint_search",
                     "sharepoint_folder_search", "get_me", "read_resource", "teams_list_chats",
                     "outlook_untrash_thread", "outlook_modify_labels"):
            with self.subTest(tool=tool):
                self.assertEqual(self.decision(P_CLOUD + tool), "allow")
        for tool in ("mcp__m365-graph__list_events", "mcp__m365-graph__search_events",
                     "mcp__m365-graph__get_event", "mcp__aruba__list_invoices", "mcp__bank__get_transactions"):
            with self.subTest(tool=tool):
                self.assertEqual(self.decision(tool), "allow")

    def test_money_denied(self):
        for tool in ("mcp__bank__create_payment", "mcp__bank__transfer", "mcp__bank__wire_funds",
                     "mcp__stripe__refund", "mcp__aruba__send_invoice", "mcp__aruba__create_invoice",
                     "mcp__x__create_sales_invoice", "mcp__x__invoice_issue", "mcp__x__pay"):
            with self.subTest(tool=tool):
                self.assertEqual(self.decision(tool), "deny")

    def test_destructive_asks(self):
        for tool in ("sharepoint_delete_item", "sharepoint_move_item", "sharepoint_rename_item",
                     "sharepoint_upload_file", "sharepoint_update_file", "sharepoint_copy_item",
                     "sharepoint_create_folder", "outlook_batch_delete_messages", "outlook_trash_thread",
                     "outlook_delete_draft", "outlook_delete_event"):
            with self.subTest(tool=tool):
                self.assertEqual(self.decision(P_CLOUD + tool), "ask")
        for tool in ("mcp__m365-graph__delete_file", "mcp__m365-graph__move_file",
                     "mcp__m365-mail__delete_message", "mcp__m365-mail__move_message"):
            with self.subTest(tool=tool):
                self.assertEqual(self.decision(tool), "ask")

    def test_unlisted_prefix_recorded(self):
        self.decision("mcp__Office365__outlook_send_mail")
        self.decision(P_CLOUD + "outlook_send_mail")
        rows = self.state("limits-findings.jsonl")
        self.assertEqual([r["prefix"] for r in rows], ["mcp__Office365__"])
        _, out, _ = self.run_hook("session-start", {"session_id": "s"})
        self.assertIn("mcp__Office365__", out["hookSpecificOutput"]["additionalContext"])


class BashAndSecrets(HookCase):
    def bash(self, command):
        return self.decision("Bash", {"command": command})

    def test_force_push_denied(self):
        for c in ("git push --force", "git push -f origin main", "git push origin +main",
                  "git push --force-with-lease", "cd x && git push -uf origin v2"):
            with self.subTest(c=c):
                self.assertEqual(self.bash(c), "deny")

    def test_plain_push_and_reads_allowed(self):
        for c in ("git push", "git push -u origin feat/x", "git status", "ls -la", "rm file.txt",
                  "rm -rf build", "rm -rf /tmp/scratch", "git log --format=%f"):
            with self.subTest(c=c):
                self.assertEqual(self.bash(c), "allow")

    def test_destructive_asks(self):
        for c in ("git reset --hard HEAD~1", "git clean -fdx", "rm -rf ~/Documents", "rm -r ../other",
                  "rm -rf /Users/someone", "rm -rf .", "rm -rf .git", "sudo rm -Rf $HOME/x"):
            with self.subTest(c=c):
                self.assertEqual(self.bash(c), "ask")

    def test_secret_text_denied(self):
        samples = {
            "github": "ghp_" + "a" * 36,
            "pat": "github_pat_" + "B" * 70,
            "anthropic": "sk-ant-" + "x" * 30,
            "aws": "AKIA" + "ABCDEFGHIJKLMNOP",
            "entra": "abc8Q~" + "x" * 34,
            "key": "-----BEGIN RSA PRIVATE KEY-----",
        }
        for name, secret in samples.items():
            with self.subTest(name=name):
                self.assertEqual(self.decision("Write", {"file_path": "a.md", "content": f"token: {secret}"}), "deny")
                self.assertEqual(self.decision("Edit", {"file_path": "a.md", "new_string": secret}), "deny")
                self.assertEqual(self.bash(f"echo {secret} > .env"), "deny")

    def test_ordinary_text_allowed(self):
        self.assertEqual(self.decision("Write", {"file_path": "a.md", "content": "Contract review for Morvento. sk- prefix only."}), "allow")


class FailClosed(HookCase):
    def test_missing_config_denies(self):
        d = tempfile.mkdtemp(prefix="jv2-noconf-")
        self.addCleanup(shutil.rmtree, d, True)
        script = os.path.join(d, "juvant_hooks.py")
        shutil.copy(SCRIPT, script)
        self.assertEqual(self.decision("Bash", {"command": "ls"}, script), "deny")
        self.assertEqual(self.decision(P_CLOUD + "get_me", {}, script), "deny")

    def test_invalid_pattern_denies(self):
        d = tempfile.mkdtemp(prefix="jv2-badconf-")
        self.addCleanup(shutil.rmtree, d, True)
        shutil.copy(SCRIPT, d)
        with open(os.path.join(HOOKS, "limits.json"), encoding="utf-8") as f:
            cfg = json.load(f)
        cfg["bash"]["deny"][0]["pattern"] = "([unclosed"
        with open(os.path.join(d, "limits.json"), "w", encoding="utf-8") as f:
            json.dump(cfg, f)
        self.assertEqual(self.decision("Bash", {"command": "ls"}, os.path.join(d, "juvant_hooks.py")), "deny")

    def test_missing_script_exits_2(self):
        p = subprocess.run([sys.executable, os.path.join(self.repo, "nope.py"), "limits"],
                           input="{}", capture_output=True, text=True)
        self.assertEqual(p.returncode, 2, "python must exit 2 (a block) when the hook script is missing")

    def test_unknown_subcommand(self):
        rc, _, _ = self.run_hook("bogus", {})
        self.assertEqual(rc, 2)


class ContextAndActivity(HookCase):
    def write(self, rel, text):
        path = os.path.join(self.repo, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    def test_manifesto_and_role_card_injected(self):
        self.write("manifesto.md", "We say no to vague contracts.")
        self.write("roles/legal.md", "name: Ada")
        rc, out, _ = self.run_hook("subagent-start", {"session_id": "s", "agent_type": "legal", "agent_id": "a1"})
        ctx = out["hookSpecificOutput"]["additionalContext"]
        self.assertEqual(rc, 0)
        self.assertIn("We say no to vague contracts.", ctx)
        self.assertIn("name: Ada", ctx)
        _, out, _ = self.run_hook("subagent-start", {"session_id": "s", "agent_type": "Explore"})
        ctx = out["hookSpecificOutput"]["additionalContext"]
        self.assertIn("We say no to vague contracts.", ctx)
        self.assertNotIn("name: Ada", ctx)

    def test_missing_manifesto_is_said(self):
        _, out, _ = self.run_hook("subagent-start", {"agent_type": "general-purpose"})
        self.assertIn("manifesto.md is missing", out["hookSpecificOutput"]["additionalContext"])

    def test_role_id_cannot_escape(self):
        self.write("secret.md", "do not read")
        _, out, _ = self.run_hook("subagent-start", {"agent_type": "../secret"})
        self.assertNotIn("do not read", out["hookSpecificOutput"]["additionalContext"])

    def test_context_capped(self):
        self.write("manifesto.md", "x" * 20000)
        _, out, _ = self.run_hook("subagent-start", {"agent_type": "general-purpose"})
        ctx = out["hookSpecificOutput"]["additionalContext"]
        self.assertLess(len(ctx), 10000)
        self.assertIn("[truncated", ctx)

    def test_activity_log(self):
        self.run_hook("session-start", {"session_id": "s1", "source": "startup"})
        self.run_hook("subagent-start", {"session_id": "s1", "agent_type": "finance", "agent_id": "f1"})
        self.run_hook("subagent-stop", {"session_id": "s1", "agent_type": "finance", "agent_id": "f1",
                                        "last_assistant_message": "Cash flow ok.\n" + "y" * 500})
        self.run_hook("stop", {"session_id": "s1", "last_assistant_message": "Done."})
        rows = self.state("activity.jsonl")
        self.assertEqual([r["event"] for r in rows], ["session_start", "subagent_start", "subagent_stop", "stop"])
        self.assertEqual(rows[2]["agent_type"], "finance")
        self.assertLessEqual(len(rows[2]["outcome"]), 160)
        self.assertNotIn("\n", rows[2]["outcome"])

    def test_session_start_status(self):
        rc, out, _ = self.run_hook("session-start", {"session_id": "s"})
        self.assertEqual(rc, 0)
        self.assertIn("hard limits active", out["hookSpecificOutput"]["additionalContext"])

    def test_logging_never_blocks(self):
        self.write("state", "a file where the state dir should be")
        rc, _, _ = self.run_hook("stop", {"session_id": "s"})
        self.assertEqual(rc, 0)
        self.assertEqual(self.decision("Bash", {"command": "ls"}), "allow")


class ClaudeDirProtection(HookCase):
    def test_write_and_edit_under_claude_ask(self):
        for tool, key in (("Write", "file_path"), ("Edit", "file_path"), ("MultiEdit", "file_path")):
            for path in (".claude/hooks/limits.json", ".claude/settings.json",
                         os.path.join(self.repo, ".claude", "agents", "legal.md"), ".claude/x/../hooks/a"):
                with self.subTest(tool=tool, path=path):
                    self.assertEqual(self.decision(tool, {key: path, "content": "x", "new_string": "x"}), "ask")

    def test_writes_elsewhere_allowed(self):
        for path in ("memory/decisions/a.md", "CLAUDE.md", os.path.expanduser("~/.claude/projects/x/memory/m.md"),
                     "notes/.claude-ideas.md"):
            with self.subTest(path=path):
                self.assertEqual(self.decision("Write", {"file_path": path, "content": "x"}), "allow")

    def test_bash_writes_ask(self):
        for c in ("echo '{}' > .claude/hooks/limits.json", "sed -i '' s/a/b/ .claude/hooks/limits.json",
                  "cp /tmp/x .claude/settings.json", "rm .claude/hooks/juvant_hooks.py",
                  "python3 -c 'open(\".claude/hooks/limits.json\",\"w\")'", "git checkout -- .claude",
                  "bash .claude/skills/update/update.sh --from /tmp/evil", "bash .claude/skills/update/update.sh v2 --repo /tmp/x.git",
                  "tee -a .claude/settings.json < /dev/null"):
            with self.subTest(c=c):
                self.assertEqual(self.decision("Bash", {"command": c}), "ask")

    def test_bash_reads_and_sanctioned_allowed(self):
        for c in ("cat .claude/juvant-os.json", "ls -la .claude", "git diff --stat .claude", "git add .claude",
                  "grep -r limits .claude/hooks", "find .claude -name '*.md'", "bash .claude/skills/update/update.sh v2.0.1",
                  "python3 .claude/hooks/juvant_hooks.py log-outcome 'done'", "echo hi && cat .claude/settings.json"):
            with self.subTest(c=c):
                self.assertEqual(self.decision("Bash", {"command": c}), "allow")


class LogOutcome(HookCase):
    def run_cli(self, *args):
        env = dict(os.environ, CLAUDE_PROJECT_DIR=self.repo)
        return subprocess.run([sys.executable, SCRIPT, "log-outcome", *args], capture_output=True, text=True, env=env)

    def test_outcome_lines(self):
        self.assertEqual(self.run_cli("Contract reviewed:", "STOP, 11 issues").returncode, 0)
        self.assertEqual(self.run_cli("--agent", "legal", "Found 11 issues").returncode, 0)
        rows = self.state("activity.jsonl")
        self.assertEqual(rows[0]["event"], "outcome")
        self.assertEqual(rows[0]["outcome"], "Contract reviewed: STOP, 11 issues")
        self.assertEqual(rows[1]["agent_type"], "legal")

    def test_empty_outcome_refused(self):
        self.assertEqual(self.run_cli().returncode, 2)


class Settings(unittest.TestCase):
    def test_registration(self):
        with open(os.path.join(ROOT, "framework", "templates", "settings.json"), encoding="utf-8") as f:
            s = json.load(f)
        pre = s["hooks"]["PreToolUse"][0]
        for name in ("Bash", "Write", "Edit", "MultiEdit", "NotebookEdit", "mcp__"):
            self.assertIn(name, pre["matcher"])
        self.assertIn("juvant_hooks.py\" limits", pre["hooks"][0]["command"])
        for event, sub in (("SessionStart", "session-start"), ("SubagentStart", "subagent-start"),
                           ("SubagentStop", "subagent-stop"), ("Stop", "stop")):
            self.assertIn(f"juvant_hooks.py\" {sub}", s["hooks"][event][0]["hooks"][0]["command"])
        deny = s["permissions"]["deny"]
        for prefix in (P_LOCAL, P_CLOUD):
            self.assertIn(prefix + "outlook_send_mail", deny)
        with open(os.path.join(HOOKS, "limits.json"), encoding="utf-8") as f:
            known = json.load(f)["known_prefixes"]
        self.assertEqual(sorted({d[: d.rindex("__") + 2] for d in deny}), sorted(known))


if __name__ == "__main__":
    unittest.main()
