"""Unit tests for framework/hooks/juvant_hooks.py. Run: python3 -m unittest discover -s tests/unit"""
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
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

    def test_private_artifact_publish_allowed(self):
        # The dashboard skill publishes a private claude.ai page (artifacts start private).
        for tool in ("mcp__claude-artifacts__publish_files", "mcp__claude-artifacts__publish_version",
                     "mcp__claude-artifacts__edit_version", "mcp__claude_ai_Artifacts__publish_files"):
            with self.subTest(tool=tool):
                self.assertEqual(self.decision(tool), "allow")
        # Comments reach other people; other servers' publish stays outbound.
        for tool in ("mcp__claude-artifacts__reply_comment", "mcp__claude-artifacts__reply_shared_comment",
                     "mcp__social__publish_files", "mcp__x-artifacts__publish_post"):
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
                     "mcp__m365-graph__get_event", "mcp__einvoice__list_invoices", "mcp__bank__get_transactions"):
            with self.subTest(tool=tool):
                self.assertEqual(self.decision(tool), "allow")

    def test_money_denied(self):
        for tool in ("mcp__bank__create_payment", "mcp__bank__transfer", "mcp__bank__wire_funds",
                     "mcp__stripe__refund", "mcp__einvoice__send_invoice", "mcp__einvoice__create_invoice",
                     "mcp__x__create_sales_invoice", "mcp__x__invoice_issue", "mcp__x__pay"):
            with self.subTest(tool=tool):
                self.assertEqual(self.decision(tool), "deny")

    def test_money_reads_allowed(self):
        for tool in ("mcp__bank__get_payments", "mcp__bank__list_transfers", "mcp__bank__get_payment_details",
                     "mcp__bank__list_invoices", "mcp__bank__get_transactions", "mcp__bank__list_payouts",
                     "mcp__Bank__search_transactions", "mcp__bank__get_balance"):
            with self.subTest(tool=tool):
                self.assertEqual(self.decision(tool), "allow")

    def test_money_actions_denied(self):
        for tool in ("mcp__bank__create_payment", "mcp__bank__initiate_transfer", "mcp__bank__payment_create",
                     "mcp__bank__approve_payout", "mcp__bank__pay", "mcp__bank__refund", "mcp__bank__schedule_transfer",
                     "mcp__bank__send_invoice", "mcp__bank__issue_invoice", "mcp__bank__transfer_execute"):
            with self.subTest(tool=tool):
                self.assertEqual(self.decision(tool), "deny")

    def test_destructive_asks(self):
        for tool in ("sharepoint_delete_item", "sharepoint_move_item", "sharepoint_rename_item",
                     "sharepoint_upload_file", "sharepoint_update_file",
                     "outlook_batch_delete_messages", "outlook_trash_thread",
                     "outlook_delete_draft", "outlook_delete_event"):
            with self.subTest(tool=tool):
                self.assertEqual(self.decision(P_CLOUD + tool), "ask")
        for tool in ("mcp__m365-graph__delete_file", "mcp__m365-graph__move_file",
                     "mcp__m365-graph__m365-graph_delete_file", "mcp__m365-graph__m365-graph_upload_file",
                     "mcp__m365-mail__delete_message", "mcp__m365-mail__move_message"):
            with self.subTest(tool=tool):
                self.assertEqual(self.decision(tool), "ask")

    def test_three_classes_create_overwrite_delete(self):
        up_local, up_graph = P_LOCAL + "sharepoint_upload_file", "mcp__m365-graph__m365-graph_upload_file"
        cases = [
            # create: allowed
            (up_local, {"conflictBehavior": "fail"}, "allow"),
            (up_local, {"conflictBehavior": "rename"}, "allow"),
            (up_graph, {"conflict_behavior": "fail"}, "allow"),
            (up_graph, {"conflict_behavior": " Rename "}, "allow"),
            (P_CLOUD + "sharepoint_create_folder", {}, "allow"),
            (P_CLOUD + "sharepoint_create_folder", {"conflictBehavior": "rename"}, "allow"),
            ("mcp__m365-graph__m365-graph_create_folder", {"conflict_behavior": "fail"}, "allow"),
            (P_CLOUD + "sharepoint_copy_item", {"newName": "x.pdf"}, "allow"),
            ("mcp__m365-graph__m365-graph_copy_file", {}, "allow"),
            # overwrite: asks
            (up_local, {}, "ask"),
            (up_local, {"conflictBehavior": "replace"}, "ask"),
            (up_graph, {"conflict_behavior": "replace"}, "ask"),
            (up_graph, {"conflict_behavior": ["fail"]}, "ask"),
            (up_graph, {"conflict_behavior": "fail", "conflictBehavior": "replace"}, "ask"),
            (P_CLOUD + "sharepoint_create_folder", {"conflictBehavior": "replace"}, "ask"),
            (P_CLOUD + "sharepoint_copy_item", {"conflictBehavior": "replace"}, "ask"),
            (P_CLOUD + "sharepoint_update_file", {"content": "x"}, "ask"),
            ("mcp__x__overwrite_document", {}, "ask"),
            # delete or move: asks, whatever the arguments
            (P_CLOUD + "sharepoint_delete_item", {"conflictBehavior": "fail"}, "ask"),
            (P_CLOUD + "sharepoint_move_item", {}, "ask"),
            ("mcp__m365-graph__m365-graph_move_file", {"new_name": "y"}, "ask"),
            # deny wins over create
            ("mcp__x__upload_and_send", {"conflictBehavior": "fail"}, "deny"),
        ]
        for tool, inp, want in cases:
            with self.subTest(tool=tool, inp=inp):
                self.assertEqual(self.decision(tool, inp), want)

    def test_create_rule_without_input_condition(self):
        cfg_dir = tempfile.mkdtemp(prefix="jv2-cfg-")
        self.addCleanup(shutil.rmtree, cfg_dir, True)
        shutil.copy(SCRIPT, cfg_dir)
        with open(os.path.join(HOOKS, "limits.json"), encoding="utf-8") as f:
            cfg = json.load(f)
        cfg["mcp"]["create"] = [{"id": "c", "pattern": "^make_thing$", "why": "x"}]
        with open(os.path.join(cfg_dir, "limits.json"), "w", encoding="utf-8") as f:
            json.dump(cfg, f)
        script = os.path.join(cfg_dir, "juvant_hooks.py")
        self.assertEqual(self.decision("mcp__x__make_thing", {}, script), "allow")
        cfg["mcp"]["create"][0]["input"] = {"key": "@@", "allow": "x"}
        with open(os.path.join(cfg_dir, "limits.json"), "w", encoding="utf-8") as f:
            json.dump(cfg, f)
        self.assertEqual(self.decision("mcp__x__make_thing", {}, script), "deny", "a bad rule fails closed")

    def test_unlisted_prefix_recorded(self):
        self.decision("mcp__Office365__outlook_send_mail")
        self.decision(P_CLOUD + "outlook_send_mail")
        rows = self.state("limits-findings.jsonl")
        self.assertEqual([r["prefix"] for r in rows], ["mcp__Office365__"])
        _, out, _ = self.run_hook("session-start", {"session_id": "s"})
        self.assertIn("mcp__Office365__", out["hookSpecificOutput"]["additionalContext"])

    def test_known_prefix_no_longer_warned(self):
        # Logged before the prefix was added to known_prefixes: no warning forever after.
        os.makedirs(os.path.join(self.repo, "state"), exist_ok=True)
        with open(os.path.join(self.repo, "state", "limits-findings.jsonl"), "w", encoding="utf-8") as f:
            f.write(json.dumps({"prefix": "mcp__claude-artifacts__", "tool": "mcp__claude-artifacts__publish_files"}) + "\n")
        _, out, _ = self.run_hook("session-start", {"session_id": "s"})
        self.assertNotIn("mcp__claude-artifacts__", out["hookSpecificOutput"]["additionalContext"])


    def test_every_deny_and_ask_is_logged(self):
        self.decision(P_LOCAL + "outlook_send_mail")
        self.decision(P_LOCAL + "sharepoint_delete_item", {"driveId": "D"})
        self.decision(P_LOCAL + "outlook_create_draft")
        rows = [r for r in self.state("activity.jsonl") if r["event"].startswith("limits_")]
        self.assertEqual([(r["event"], r["tool"]) for r in rows],
                         [("limits_deny", P_LOCAL + "outlook_send_mail"), ("limits_ask", P_LOCAL + "sharepoint_delete_item")])
        self.assertIn("delete-move", rows[1]["reason"])


class CompanyLimits(HookCase):
    def company(self, data):
        os.makedirs(os.path.join(self.repo, ".claude"), exist_ok=True)
        with open(os.path.join(self.repo, ".claude", "limits-company.json"), "w", encoding="utf-8") as f:
            f.write(data if isinstance(data, str) else json.dumps(data))

    def test_own_prefix_silences_the_warning(self):
        self.decision("mcp__acme-erp__delete_order")
        _, out, _ = self.run_hook("session-start", {"session_id": "s"})
        self.assertIn("mcp__acme-erp__", out["hookSpecificOutput"]["additionalContext"])
        self.assertIn("limits-company.json", out["hookSpecificOutput"]["additionalContext"])
        self.company({"known_prefixes": ["mcp__acme-erp__"]})
        _, out, _ = self.run_hook("session-start", {"session_id": "s"})
        self.assertNotIn("mcp__acme-erp__", out["hookSpecificOutput"]["additionalContext"])
        before = len(self.state("limits-findings.jsonl"))
        self.assertEqual(self.decision("mcp__acme-erp__delete_order"), "ask", "the hard limits still apply")
        self.assertEqual(len(self.state("limits-findings.jsonl")), before, "no new finding")

    def test_company_rules_add(self):
        self.company({"mcp": {"deny": [{"id": "no-orders", "pattern": "(^|_)close_order$", "why": "orders are closed in the ERP"}],
                              "ask": [{"id": "export", "pattern": "export"}]},
                      "bash": {"deny": [{"id": "no-prod", "pattern": "\\bpsql\\b.*prod"}]},
                      "secrets": [{"id": "acme-key", "pattern": "ACME-[0-9]{12}"}]})
        self.assertEqual(self.decision("mcp__acme-erp__close_order"), "deny")
        self.assertEqual(self.decision("mcp__acme-erp__export_csv"), "ask")
        self.assertEqual(self.decision("Bash", {"command": "psql -h prod-db"}), "deny")
        self.assertEqual(self.decision("Write", {"file_path": "x.md", "content": "key ACME-123456789012"}), "deny")
        self.assertEqual(self.decision(P_LOCAL + "outlook_send_mail"), "deny", "framework rules still there")
        self.assertEqual(self.decision("mcp__acme-erp__list_orders"), "allow")

    def test_framework_rules_cannot_be_removed_or_exempted(self):
        self.company({"mcp": {"deny": []}})
        self.assertEqual(self.decision(P_LOCAL + "outlook_send_mail"), "deny", "an empty list removes nothing")
        for bad in ({"mcp": {"create": [{"id": "x", "pattern": "delete"}]}}, {"mcp": {"draft_allow": "send"}},
                    {"mcp": {"ask": [{"id": "x", "pattern": "send", "input": {"key": "k", "allow": "x"}}]}},
                    {"known_prefixes": ["acme"]}, {"bash": {"rm_outside_repo": "allow"}}, {"anything": 1},
                    {"mcp": {"deny": [{"id": "x", "pattern": "("}]}}, "{broken", "[]"):
            with self.subTest(bad=bad):
                self.company(bad)
                self.assertEqual(self.decision(P_LOCAL + "outlook_create_draft"), "deny", "fails closed")
                _, out, _ = self.run_hook("session-start", {"session_id": "s"})
                self.assertIn("unreadable", out["hookSpecificOutput"]["additionalContext"])

    def test_writing_the_company_file_asks(self):
        self.assertEqual(self.decision("Write", {"file_path": ".claude/limits-company.json", "content": "{}"}), "ask")

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

    def test_project_repo_uses_company_manifesto_copy(self):
        self.write(".claude/company-manifesto.md", "Company rules from the copy.")
        _, out, _ = self.run_hook("subagent-start", {"agent_type": "general-purpose"})
        self.assertIn("Company rules from the copy.", out["hookSpecificOutput"]["additionalContext"])

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

    def test_helper_subagents_log_no_outcome(self):
        self.run_hook("subagent-stop", {"session_id": "s", "agent_id": "a1", "last_assistant_message": "sì, l'ho vista e approvata"})
        self.run_hook("subagent-stop", {"session_id": "s", "agent_id": "a2", "agent_type": "legal",
                                        "last_assistant_message": "VERDICT: OK"})
        rows = [r for r in self.state("activity.jsonl") if r["event"] == "subagent_stop"]
        self.assertEqual([r.get("outcome") for r in rows], [None, "VERDICT: OK"])

    def test_session_as_dedicated_agent(self):
        self.write("roles/finance.md", "name: Greta\nMinimum cash buffer: 90000")
        _, out, _ = self.run_hook("session-start", {"session_id": "s", "agent_type": "finance"})
        ctx = out["hookSpecificOutput"]["additionalContext"]
        self.assertIn("runs as `finance`, not as the Chief of Staff", ctx)
        self.assertIn("Minimum cash buffer: 90000", ctx)
        self.assertIn("hard limits active", ctx)
        rows = self.state("activity.jsonl")
        self.assertEqual(rows[-1]["agent_type"], "finance")

    def test_session_as_main_thread_has_no_role_note(self):
        _, out, _ = self.run_hook("session-start", {"session_id": "s"})
        self.assertNotIn("not as the Chief of Staff", out["hookSpecificOutput"]["additionalContext"])

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
                  "tee -a .claude/settings.json < /dev/null", "echo x>.claude/hooks/limits.json",
                  "echo 'a; b' >> .claude/settings.json", "printf x | tee .claude/x", "echo \"unbalanced > .claude/x",
                  "python3 .claude/dashboard/build.py --out .claude/settings.json", "python3 .claude/dashboard/build.py > .claude/x"):
            with self.subTest(c=c):
                self.assertEqual(self.decision("Bash", {"command": c}), "ask")

    def test_bash_reads_and_sanctioned_allowed(self):
        for c in ("cat .claude/juvant-os.json", "ls -la .claude", "git diff --stat .claude", "git add .claude",
                  "grep -r limits .claude/hooks", "find .claude -name '*.md'", "bash .claude/skills/update/update.sh v2.0.1",
                  "python3 .claude/hooks/juvant_hooks.py log-outcome 'done'", "echo hi && cat .claude/settings.json",
                  'python3 .claude/hooks/juvant_hooks.py log-outcome "pack (legal, locale); setup done; verify"; git add memory && git commit -m "x; y"',
                  'cd /tmp/x && python3 .claude/hooks/juvant_hooks.py log-outcome "a & b | c"',
                  "python3 .claude/dashboard/build.py", "python3 .claude/dashboard/build.py --agents-json /tmp/agents.json",
                  "claude agents --json > /tmp/agents.json && python3 .claude/dashboard/build.py --agents-json /tmp/agents.json",
                  "python3 .claude/skills/bugfix/bugfix.py prepare",
                  "python3 .claude/skills/bugfix/bugfix.py check /tmp/juvant-os-fix-x/juvant-os --body /tmp/pr.md"):
            with self.subTest(c=c):
                self.assertEqual(self.decision("Bash", {"command": c}), "allow")


    def test_claude_code_scratch_and_cd_are_not_writes(self):
        jobs = os.path.expanduser("~/.claude/jobs/78ffa8cc/tmp/it")
        real = (f"cd {jobs}; sed 's/<[^>]*>//g' dl2.html | tr -s ' \\n' ' ' > /tmp/dl2.txt; "
                'LC_ALL=C grep -o "1[0-9]\\. [^.]\\{0,80\\}221" /tmp/dl2.txt | head -5')
        for c in (real, f"cd {jobs} && curl -s -o dl.html https://example.org/x", f"mkdir -p {jobs}/out",
                  "cd .claude && ls", "cd .claude; cat settings.json", "cd /tmp && echo x > .claude-notes.txt",
                  "cd /tmp/other-repo && echo x > .claude/settings.json"):
            with self.subTest(c=c):
                self.assertEqual(self.decision("Bash", {"command": c}), "allow")

    def test_common_reads_of_claude_files_pass(self):
        for c in ('cat .claude/skills/new-project/project-README.md; ls memory/decisions | tail -3; '
                  'sed -n 1,40p .claude/skills/decision/SKILL.md; grep -n "Projects\\|projects/" memory/map.md | head',
                  "sed -n '/^## /p' .claude/skills/wrap-up/SKILL.md", "awk '{print $1}' .claude/hooks/limits.json",
                  "sort .claude/juvant-os/FILES | uniq -c", "cut -d: -f1 .claude/juvant-os/FILES | tr a-z A-Z",
                  "jq .known_prefixes .claude/hooks/limits.json", "nl .claude/skills/update/SKILL.md | head -20",
                  "du -sh .claude", "tree .claude/skills | head", "echo .claude/settings.json"):
            with self.subTest(c=c):
                self.assertEqual(self.decision("Bash", {"command": c}), "allow")

    def test_writing_forms_of_read_tools_still_ask(self):
        for c in ("sed -i '' s/a/b/ .claude/settings.json", "sed -ni 's/a/b/p' .claude/settings.json",
                  "sed --in-place s/a/b/ .claude/settings.json", "sed -n 'w .claude/x' memory/a.md",
                  "sed 's/a/b/w .claude/x' memory/a.md", "awk '{print > \".claude/x\"}' memory/a.md",
                  "awk 'BEGIN{system(\"rm .claude/x\")}'", "sort -o .claude/juvant-os/FILES memory/a.md",
                  "echo x > .claude/settings.json", "printf x >> .claude/settings.json"):
            with self.subTest(c=c):
                self.assertEqual(self.decision("Bash", {"command": c}), "ask")

    def test_writes_after_cd_into_claude_still_ask(self):
        for c in ("cd .claude && echo x > settings.json", "cd .claude/hooks; rm limits.json",
                  "pushd .claude >/dev/null && sed -i '' s/a/b/ settings.json", f"cd {self.repo} && echo x > .claude/x",
                  "cd $HOME/.claude && echo x > settings.json", "echo x > ~/.claude/settings.json",
                  "cp /tmp/s.json ~/.claude/settings.json", "cd ~/.claude && echo x > settings.json"):
            with self.subTest(c=c):
                self.assertEqual(self.decision("Bash", {"command": c}), "ask")

    def test_relative_paths_follow_the_event_cwd(self):
        ev = {"tool_name": "Bash", "tool_input": {"command": "echo x > settings.json"},
              "cwd": os.path.join(self.repo, ".claude")}
        rc, out, _ = self.run_hook("limits", ev)
        self.assertEqual(out.get("hookSpecificOutput", {}).get("permissionDecision"), "ask")
        ev["cwd"] = os.path.expanduser("~/.claude/jobs/x/tmp")
        rc, out, _ = self.run_hook("limits", ev)
        self.assertEqual((rc, out), (0, {}))

class SharedRepo(HookCase):
    def setUp(self):
        super().setUp()
        os.makedirs(os.path.join(self.repo, ".claude"))
        with open(os.path.join(self.repo, ".claude", "juvant-os-project.json"), "w") as f:
            json.dump({"project": "dog", "company_repo": "/x", "shared_with": "the co-founders"}, f)
        subprocess.run(["git", "init", "-q", "-b", "main", self.repo], check=True)

    def branch(self, name):
        subprocess.run(["git", "-C", self.repo, "checkout", "-q", "-b", name], check=True)

    def bash(self, c):
        return self.decision("Bash", {"command": c})

    def test_default_branch_push_denied(self):
        for c in ("git push", "git push origin main", "git push origin HEAD:main", "git push -u origin master",
                  "git push origin refs/heads/main", "gh pr merge 12 --squash", "gh pr create --title x --body y"):
            with self.subTest(c=c):
                self.assertEqual(self.bash(c), "deny")

    def test_branch_work_allowed(self):
        self.branch("feat/prd-update")
        for c in ("git push", "git push -u origin feat/prd-update", "git push origin HEAD",
                  "gh pr create --draft --title x --body y", "gh pr view 3", "git commit -m x"):
            with self.subTest(c=c):
                self.assertEqual(self.bash(c), "allow")
        self.assertEqual(self.bash("git push origin HEAD:main"), "deny")

    def test_not_shared_no_rule(self):
        os.remove(os.path.join(self.repo, ".claude", "juvant-os-project.json"))
        self.assertEqual(self.bash("git push origin main"), "allow")
        self.assertEqual(self.bash("gh pr merge 1"), "allow")


class SharedRepoFromElsewhere(HookCase):
    """The session runs in the company repo; the shared project repo is elsewhere (advisory fix)."""
    def setUp(self):
        super().setUp()
        subprocess.run(["git", "init", "-q", "-b", "main", self.repo], check=True)  # company repo, internal
        self.shared = tempfile.mkdtemp(prefix="jv2-shared-")
        self.addCleanup(shutil.rmtree, self.shared, True)
        subprocess.run(["git", "init", "-q", "-b", "main", self.shared], check=True)
        subprocess.run(["git", "-C", self.shared, "remote", "add", "origin", "https://github.com/acme/dog-docs.git"], check=True)
        os.makedirs(os.path.join(self.shared, ".claude"))
        with open(os.path.join(self.shared, ".claude", "juvant-os-project.json"), "w") as f:
            json.dump({"project": "dog", "shared_with": "the partners"}, f)
        os.makedirs(os.path.join(self.shared, "docs"))

    def bash(self, c, cwd=None):
        rc, out, _ = self.run_hook("limits", {"tool_name": "Bash", "tool_input": {"command": c}, "cwd": cwd or self.repo})
        return out.get("hookSpecificOutput", {}).get("permissionDecision") or ("deny" if rc == 2 else "allow")

    def test_bypasses_closed(self):
        sh = self.shared
        for c, cwd in ((f"git -C {sh} push origin main", None), (f"cd {sh} && gh pr merge 1", None),
                       (f"cd {sh} && git push", None), (f"git --git-dir={sh}/.git push origin main", None),
                       (f"git -C {sh}/docs push origin HEAD:main", None), (f"git -C {sh} -c core.x=y push origin main", None),
                       (f"git -C {sh} push --all origin", None),
                       ("git push origin main", sh), ("git -C . push origin main", sh), ("gh pr merge 3", sh),
                       ("gh pr create --title x --body y", sh), ("gh pr merge 3 -R acme/dog-docs", sh)):
            with self.subTest(c=c, cwd=cwd):
                self.assertEqual(self.bash(c, cwd), "deny")

    def test_branch_work_and_internal_repos_allowed(self):
        sh = self.shared
        subprocess.run(["git", "-C", sh, "checkout", "-q", "-b", "fix/x"], check=True)
        for c, cwd in ((f"git -C {sh} push -u origin fix/x", None), (f"cd {sh} && gh pr create --draft -t x -b y", None),
                       ("git push origin main", None), (f"git -C {sh} log --oneline", None),
                       ("gh pr create --draft -R acme/elsewhere -t x -b y", None)):
            with self.subTest(c=c, cwd=cwd):
                self.assertEqual(self.bash(c, cwd), "allow")

    def test_unresolved_remote_merge_asks(self):
        for c in ("gh pr merge 3 -R acme/elsewhere", "gh pr merge 3 --repo=acme/elsewhere",
                  "gh pr create -R acme/elsewhere -t x -b y"):
            with self.subTest(c=c):
                self.assertEqual(self.bash(c), "ask")


class FrameworkUpstream(HookCase):
    """Publishing to the public juvant-os repository asks the CEO (bugfix skill)."""
    def clone(self, url):
        d = tempfile.mkdtemp(prefix="jv2-clone-")
        self.addCleanup(shutil.rmtree, d, True)
        subprocess.run(["git", "init", "-q", d], check=True)
        subprocess.run(["git", "-C", d, "remote", "add", "origin", url], check=True)
        return d

    def bash(self, command, cwd):
        rc, out, _ = self.run_hook("limits", {"tool_name": "Bash", "tool_input": {"command": command}, "cwd": cwd})
        return out.get("hookSpecificOutput", {}).get("permissionDecision") or ("deny" if rc == 2 else "allow")

    def test_publishing_to_juvant_os_asks(self):
        up = self.clone("https://github.com/juvantlabs/juvant-os.git")
        fork = self.clone("git@github.com:someone/juvant-os.git")
        for cmd, cwd in (("gh pr create --draft --label adopter-fix --title x --body-file b.md", up),
                         ("git push -u origin fix/x", up), ("git push origin fix/x", fork),
                         ("gh repo fork --remote", up), ("gh issue create -R juvantlabs/juvant-os -t x -b y", self.repo),
                         (f"cd {up} && gh pr create --draft -t x -b y", self.repo),
                         (f"git -C {up} push origin fix/x", self.repo),
                         ("gh api -X POST repos/juvantlabs/juvant-os/security-advisories/reports -f summary=x", self.repo)):
            with self.subTest(cmd=cmd):
                self.assertEqual(self.bash(cmd, cwd), "ask")

    def test_other_repos_and_reads_untouched(self):
        other = self.clone("https://github.com/acme/website.git")
        pm = self.clone("https://github.com/juvantlabs/juvant-os-pm.git")
        up = self.clone("https://github.com/juvantlabs/juvant-os.git")
        for cmd, cwd in (("gh pr create --draft -t x -b y", other), ("git push origin fix/x", other),
                         ("gh issue create -t x -b y", pm), ("gh pr list --label adopter-fix", up),
                         ("git log --oneline -3", up), ("gh pr view 12 -R juvantlabs/juvant-os", self.repo)):
            with self.subTest(cmd=cmd):
                self.assertEqual(self.bash(cmd, cwd), "allow")


class OtherRepoProtection(HookCase):
    def test_project_repo_framework_files_ask(self):
        other = tempfile.mkdtemp(prefix="jv2-other-")
        self.addCleanup(shutil.rmtree, other, True)
        os.makedirs(os.path.join(other, ".claude"))
        open(os.path.join(other, ".claude", "juvant-os-project.json"), "w").write("{}")
        for f in ("juvant-os-project.json", "CLAUDE.md", "hooks/limits.json"):
            with self.subTest(f=f):
                self.assertEqual(self.decision("Write", {"file_path": os.path.join(other, ".claude", f), "content": "x"}), "ask")
        plain = tempfile.mkdtemp(prefix="jv2-plain-")
        self.addCleanup(shutil.rmtree, plain, True)
        os.makedirs(os.path.join(plain, ".claude"))
        self.assertEqual(self.decision("Write", {"file_path": os.path.join(plain, ".claude", "x.md"), "content": "x"}), "allow",
                         "a .claude/ without juvant-os is not ours to guard")


class GithubSharingCheck(HookCase):
    def fake_gh(self, count):
        p = os.path.join(self.repo, "fake-gh.sh")
        with open(p, "w") as f:
            f.write(f"#!/bin/sh\necho {count}\n")
        os.chmod(p, 0o755)
        return p

    def ctx(self, gh):
        env = dict(os.environ, CLAUDE_PROJECT_DIR=self.repo, JUVANT_GH=gh)
        p = subprocess.run([sys.executable, SCRIPT, "session-start"], input=json.dumps({"session_id": "s"}),
                           capture_output=True, text=True, env=env, timeout=20)
        return json.loads(p.stdout)["hookSpecificOutput"]["additionalContext"]

    def setUp(self):
        super().setUp()
        subprocess.run(["git", "init", "-q", self.repo], check=True)
        subprocess.run(["git", "-C", self.repo, "remote", "add", "origin", "git@github.com:acme/dog-pm.git"], check=True)

    def test_unmarked_project_repo_with_outside_collaborators_warns(self):
        os.makedirs(os.path.join(self.repo, ".claude"), exist_ok=True)
        with open(os.path.join(self.repo, ".claude", "juvant-os-project.json"), "w") as f:
            json.dump({"project": "dog", "shared_with": ""}, f)
        self.assertIn("2 outside collaborator(s) on acme/dog-pm", self.ctx(self.fake_gh(2)))

    def test_marked_shared_is_quiet(self):
        os.makedirs(os.path.join(self.repo, ".claude"), exist_ok=True)
        with open(os.path.join(self.repo, ".claude", "juvant-os-project.json"), "w") as f:
            json.dump({"project": "dog", "shared_with": "the co-founders"}, f)
        self.assertNotIn("outside collaborator", self.ctx(self.fake_gh(2)))

    def test_company_repo_with_outside_collaborators_warns(self):
        self.assertIn("on the company repo acme/dog-pm", self.ctx(self.fake_gh(1)))

    def test_cached_for_a_day_and_silent_without_gh(self):
        self.assertNotIn("outside collaborator", self.ctx("/nonexistent/gh"))
        self.assertNotIn("outside collaborator", self.ctx(self.fake_gh(3)), "cached result reused")


class PrivateFiles(HookCase):
    def setUp(self):
        super().setUp()
        os.makedirs(os.path.join(self.repo, "memory"), exist_ok=True)
        os.makedirs(os.path.join(self.repo, "docs", "legal"), exist_ok=True)
        open(os.path.join(self.repo, "docs", "legal", "settlement.md"), "w").write("terms")
        with open(os.path.join(self.repo, "memory", "private.md"), "w") as f:
            f.write("# Private files\n\n| File | Readers | Why | Added |\n|---|---|---|---|\n"
                    "| docs/legal/settlement.md | legal, cos | settlement | 2026-11-09 |\n"
                    "| https://x.sharepoint.com/sites/legal/nda.docx | legal | NDA | 2026-11-09 |\n"
                    "| 01ITEMIDABC123 | finance | salary review | 2026-11-09 |\n")

    def as_agent(self, agent, tool, inp, session="s1"):
        ev = {"tool_name": tool, "tool_input": inp, "session_id": session}
        if agent:
            ev["agent_type"] = agent
        rc, out, _ = self.run_hook("limits", ev)
        d = out.get("hookSpecificOutput", {}).get("permissionDecision")
        return "deny" if rc == 2 else (d or "allow")

    def test_readers_allowed_others_denied(self):
        f = os.path.join(self.repo, "docs", "legal", "settlement.md")
        self.assertEqual(self.as_agent("legal", "Read", {"file_path": f}), "allow")
        self.assertEqual(self.as_agent(None, "Read", {"file_path": "docs/legal/settlement.md"}), "allow", "main session is cos")
        self.assertEqual(self.as_agent("finance", "Read", {"file_path": f}), "deny")
        self.assertEqual(self.as_agent("general-purpose", "Edit", {"file_path": f, "new_string": "x"}), "deny")
        self.assertEqual(self.as_agent("general-purpose", "Bash", {"command": "cat docs/legal/settlement.md"}), "deny")
        self.assertEqual(self.as_agent("general-purpose", "Grep", {"pattern": "x", "path": f}), "deny")
        self.assertEqual(self.as_agent("general-purpose", "Read", {"file_path": os.path.join(self.repo, "docs", "other.md")}), "allow")

    def test_connector_urls_and_ids(self):
        url = {"uri": "https://x.sharepoint.com/sites/legal/nda.docx"}
        self.assertEqual(self.as_agent("legal", "mcp__Microsoft_365__read_resource", url), "allow")
        self.assertEqual(self.as_agent(None, "mcp__Microsoft_365__read_resource", url), "deny", "cos not listed for the NDA")
        self.assertEqual(self.as_agent("legal", "mcp__m365-graph__download_file", {"item_id": "01ITEMIDABC123"}), "deny")
        self.assertEqual(self.as_agent("finance", "mcp__m365-graph__download_file", {"item_id": "01ITEMIDABC123"}), "allow")

    def test_session_started_as_agent(self):
        self.run_hook("session-start", {"session_id": "bg1", "agent_type": "finance"})
        self.assertEqual(self.as_agent(None, "mcp__m365-graph__download_file", {"item_id": "01ITEMIDABC123"}, session="bg1"), "allow")
        self.assertEqual(self.as_agent(None, "mcp__m365-graph__download_file", {"item_id": "01ITEMIDABC123"}, session="other"), "deny")

    def test_registry_changes_ask(self):
        self.assertEqual(self.as_agent(None, "Edit", {"file_path": "memory/private.md", "new_string": "x"}), "ask")
        self.assertEqual(self.as_agent(None, "Bash", {"command": "sed -i '' 3d memory/private.md"}), "ask")
        self.assertEqual(self.as_agent(None, "Read", {"file_path": "memory/private.md"}), "allow", "the list itself is readable")

    def test_no_registry_no_rule(self):
        os.remove(os.path.join(self.repo, "memory", "private.md"))
        self.assertEqual(self.as_agent("finance", "Read", {"file_path": "docs/legal/settlement.md"}), "allow")


UP = "mcp__m365-graph__m365-graph_upload_file"
DEL = P_LOCAL + "sharepoint_delete_item"
SEND = P_LOCAL + "outlook_send_mail"
AUTH = "memory/authorizations/2026-11-11-invoices.md"


class LongTask(HookCase):
    def auth_text(self, **over):
        fm = {"status": "active", "actions": "overwrite", "scope_driveId": "DRIVE1",
              "scope_parentItemId": "FOLDER1, FOLDER2", "max": "3",
              "expires": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 3600)), "agents": "finance"}
        fm.update(over)
        body = "".join(f"{k}: {v}\n" for k, v in fm.items() if v is not None)
        return f"---\n{body}---\n# invoices\n\nGoal: file invoices.\n"

    def call(self, tool, inp, session="s1", agent=None):
        ev = {"tool_name": tool, "tool_input": inp, "session_id": session}
        if agent:
            ev["agent_type"] = agent
        rc, out, _ = self.run_hook("limits", ev)
        d = out.get("hookSpecificOutput", {}).get("permissionDecision")
        return "deny" if rc == 2 else (d or "allow")

    def approve(self, text=None, session="s1", path=AUTH):
        """The agent writes the authorization (the hook asks); the CEO confirms, so the file gets written."""
        text = text or self.auth_text()
        self.assertEqual(self.call("Write", {"file_path": path, "content": text}, session), "ask")
        full = os.path.join(self.repo, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write(text)
        return full

    def up(self, **inp):
        base = {"drive_id": "DRIVE1", "parent_item_id": "FOLDER1", "conflict_behavior": "replace"}
        base.update(inp)
        return {k: v for k, v in base.items() if v is not None}

    def test_inside_the_authorization_allowed_counted_and_logged(self):
        self.approve()
        self.assertEqual(self.call(UP, self.up()), "allow")
        self.assertEqual(self.call(UP, self.up(parent_item_id="FOLDER2")), "allow")
        rows = [r for r in self.state("activity.jsonl") if r["event"] == "authorized"]
        self.assertEqual([(r["rule"], r["count"], r["authorization"]) for r in rows],
                         [("overwrite", 1, AUTH), ("overwrite", 2, AUTH)])
        self.assertEqual(self.call(UP, self.up()), "allow")
        self.assertEqual(self.call(UP, self.up()), "deny", "past max: denied, set aside for the CEO")

    def test_only_the_session_that_approved_it(self):
        self.approve()
        self.assertEqual(self.call(UP, self.up(), session="other"), "ask")
        self.assertEqual(self.call(UP, self.up(), session=""), "ask")

    def test_scope_action_and_tools(self):
        self.approve(self.auth_text(tools="upload"))
        self.assertEqual(self.call(UP, self.up(drive_id="DRIVE2")), "ask", "other drive")
        self.assertEqual(self.call(UP, self.up(parent_item_id=None)), "ask", "scope argument missing")
        self.assertEqual(self.call(UP, self.up(parent_item_id="FOLDER1X")), "ask", "exact values only")
        self.assertEqual(self.call(DEL, {"driveId": "DRIVE1", "parentItemId": "FOLDER1"}), "ask", "delete-move not authorized")
        self.assertEqual(self.call(P_LOCAL + "sharepoint_update_file", {"driveId": "DRIVE1", "parentItemId": "FOLDER1"}), "ask",
                         "tools narrows to uploads")
        self.assertEqual(self.call(UP, self.up()), "allow")

    def test_delete_move_when_listed(self):
        self.approve(self.auth_text(actions="overwrite, delete-move"))
        self.assertEqual(self.call(DEL, {"driveId": "DRIVE1", "parentItemId": "FOLDER2"}), "allow")

    def test_denies_are_never_authorized(self):
        self.approve(self.auth_text(actions="overwrite, delete-move, outbound, money"))
        self.assertEqual(self.call(SEND, {"driveId": "DRIVE1", "parentItemId": "FOLDER1"}), "deny")
        self.assertEqual(self.call("mcp__bank__create_payment", {"driveId": "DRIVE1", "parentItemId": "FOLDER1"}), "deny")

    def test_subagents_only_if_named(self):
        self.approve()
        self.assertEqual(self.call(UP, self.up(), agent="finance"), "allow")
        self.assertEqual(self.call(UP, self.up(), agent="legal"), "ask")
        self.run_hook("session-start", {"session_id": "bg", "agent_type": "legal"})
        self.approve(session="bg", path="memory/authorizations/2026-11-11-bg.md")
        self.assertEqual(self.call(UP, self.up(), session="bg", agent="legal"), "allow", "the session's own main agent")

    def test_not_active_unless_the_ceo_confirmed_and_nothing_changed(self):
        text = self.auth_text()  # once: its expiry is computed from the clock
        self.assertEqual(self.call("Write", {"file_path": AUTH, "content": text}), "ask")
        self.assertEqual(self.call(UP, self.up()), "ask", "declined: the file was never written")
        full = self.approve(text)
        with open(full, "a", encoding="utf-8") as f:
            f.write("max: 999\n")
        self.assertEqual(self.call(UP, self.up()), "ask", "changed after approval")
        with open(full, "w", encoding="utf-8") as f:
            f.write(text)
        self.assertEqual(self.call(UP, self.up()), "allow", "same content as approved")

    def test_expiry_status_scope_and_max_must_be_valid(self):
        past = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 60))
        self.approve(self.auth_text(expires=past))
        self.assertEqual(self.call(UP, self.up()), "deny", "expired but still open: denied")
        for over in ({"expires": "soon"}, {"status": "closed"}, {"scope_driveId": None,
                     "scope_parentItemId": None}, {"max": "lots"}, {"max": None}, {"tools": "("}):
            with self.subTest(over=over):
                self.approve(self.auth_text(**over))
                self.assertEqual(self.call(UP, self.up()), "ask")

    def test_never_more_than_24_hours_after_approval(self):
        far = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 7 * 86400))
        self.approve(self.auth_text(expires=far))
        self.assertEqual(self.call(UP, self.up()), "allow")
        path = os.path.join(self.repo, "state", "authorizations.json")
        st = json.load(open(path))
        st[AUTH]["recorded"] -= 25 * 3600
        json.dump(st, open(path, "w"))
        self.assertEqual(self.call(UP, self.up()), "deny", "past 24 hours: expired")

    def test_default_expiry_is_12_hours(self):
        self.approve(self.auth_text(expires=None))
        self.assertEqual(self.call(UP, self.up()), "allow")
        path = os.path.join(self.repo, "state", "authorizations.json")
        st = json.load(open(path))
        st[AUTH]["recorded"] -= 13 * 3600
        json.dump(st, open(path, "w"))
        self.assertEqual(self.call(UP, self.up()), "deny", "expired while still open")

    def test_writing_and_protecting_authorizations(self):
        self.approve()
        self.assertEqual(self.call("Edit", {"file_path": AUTH, "old_string": "max: 3", "new_string": "max: 9"}), "ask")
        self.assertEqual(self.call("Write", {"file_path": "state/authorizations.json", "content": "{}"}), "deny")
        self.assertEqual(self.call("Bash", {"command": "echo x >> state/authorizations.json"}), "deny")
        for cmd in (f"echo 'max: 9' >> {AUTH}", f"cp /tmp/x.md {AUTH}", f"git checkout other -- {AUTH}",
                    f"python3 -c 'open(\"{AUTH}\",\"w\")'"):
            with self.subTest(cmd=cmd):
                self.assertEqual(self.call("Bash", {"command": cmd}), "ask")
        self.assertEqual(self.call("Bash", {"command": f"cat {AUTH}"}), "allow")

    def test_folder_scope_across_upload_move_and_delete(self):
        g_del, g_move = "mcp__m365-graph__m365-graph_delete_file", "mcp__m365-graph__m365-graph_move_file"
        self.approve(self.auth_text(**{"actions": "overwrite, delete-move", "scope_parentItemId": None, "max": "9",
                                       "scope_parent_item_id|expected_parent_id": "FOLDER1"}))
        self.assertEqual(self.call(UP, self.up()), "allow", "upload: parent_item_id")
        self.assertEqual(self.call(g_del, {"drive_id": "DRIVE1", "item_id": "x", "expected_parent_id": "FOLDER1"}), "allow")
        self.assertEqual(self.call(g_move, {"drive_id": "DRIVE1", "item_id": "x", "target_parent_id": "SUB",
                                            "expected_parent_id": "FOLDER1"}), "allow")
        self.assertEqual(self.call(g_del, {"drive_id": "DRIVE1", "item_id": "x"}), "ask", "no folder guard")
        self.assertEqual(self.call(g_del, {"drive_id": "DRIVE1", "item_id": "x", "expected_parent_id": "OTHER"}), "ask")
        self.assertEqual(self.call(g_move, {"drive_id": "DRIVE1", "item_id": "x", "target_parent_id": "FOLDER1"}), "ask",
                         "the destination is not where the item is")

    def test_scope_keys_match_exactly(self):
        self.approve(self.auth_text(**{"actions": "delete-move", "scope_parentItemId": None, "scope_parent_id": "FOLDER1"}))
        g_move = "mcp__m365-graph__m365-graph_move_file"
        self.assertEqual(self.call(g_move, {"drive_id": "DRIVE1", "item_id": "x", "target_parent_id": "FOLDER1"}), "ask",
                         "parent_id is not target_parent_id")
        self.assertEqual(self.call(g_move, {"drive_id": "DRIVE1", "item_id": "x", "parent_id": "FOLDER1"}), "allow",
                         "the same rule with the exact key goes through")

    def test_past_the_limit_denies_only_what_the_authorization_would_cover(self):
        self.approve(self.auth_text(max="1"))
        self.assertEqual(self.call(UP, self.up()), "allow")
        rc_deny = self.call(UP, self.up())
        self.assertEqual(rc_deny, "deny")
        rows = [r for r in self.state("activity.jsonl") if r["event"] == "limits_deny"]
        self.assertIn("past the authorization", rows[-1]["reason"])
        self.assertEqual(self.call(UP, self.up(drive_id="DRIVE2")), "ask", "out of scope: asks as usual")
        self.assertEqual(self.call(DEL, {"driveId": "DRIVE1", "parentItemId": "FOLDER1"}), "ask", "action not listed")
        self.assertEqual(self.call(UP, self.up(), session="other"), "ask", "another session")
        self.assertEqual(self.call(UP, self.up(), agent="legal"), "ask", "a subagent it doesn't name")
        self.assertEqual(self.call(SEND, {"driveId": "DRIVE1"}), "deny", "deny-level unchanged")
        env = dict(os.environ, CLAUDE_PROJECT_DIR=self.repo)
        subprocess.run([sys.executable, SCRIPT, "close-authorization", AUTH, "done"], env=env, capture_output=True, timeout=20)
        self.assertEqual(self.call(UP, self.up()), "ask", "closed: back to asking")
        closed = [r for r in self.state("activity.jsonl") if r["event"] == "authorization_closed"]
        self.assertEqual(closed[-1]["session"], "s1", "the close is logged with its session")

    def test_close_command_variants(self):
        self.approve()
        base = f"python3 .claude/hooks/juvant_hooks.py close-authorization {AUTH}"
        for c in (base + ' "done (3 files; 1 set aside)"', f"cd {self.repo} && {base} 'ok'", f"cd /tmp; {base} done"):
            with self.subTest(c=c):
                self.assertEqual(self.call("Bash", {"command": c}), "allow")
        for c in (base + " done && rm -rf memory", base + ' "$(rm -rf memory)"', base + " done > memory/x",
                  f"echo x >> {AUTH}; {base} done", base + " `id`"):
            with self.subTest(c=c):
                self.assertEqual(self.call("Bash", {"command": c}), "ask")

    def test_reads_of_protected_files_are_not_writes(self):
        self.approve()
        for c in ("cat state/authorizations.json", "cat state/authorizations.json | python3 -m json.tool",
                  "jq . state/authorizations.json", f"grep -n max {AUTH} | head -3", f"cat {AUTH} | python3 -c 'import sys'",
                  "git diff memory/authorizations/", "cat memory/private.md | python3 -c 'import sys'"):
            with self.subTest(c=c):
                self.assertEqual(self.call("Bash", {"command": c}), "allow")
        for c, want in (("cat state/authorizations.json > /tmp/x; python3 -c \"open('state/authorizations.json','w')\"", "deny"),
                        ("cat /tmp/x > state/authorizations.json", "deny"), (f"cat /tmp/x | tee {AUTH}", "ask"),
                        ("cat memory/private.md | tee memory/private.md", "ask")):
            with self.subTest(c=c):
                self.assertEqual(self.call("Bash", {"command": c}), want)

    def test_an_approved_edit_counts(self):
        full = self.approve()
        self.assertEqual(self.call("Edit", {"file_path": AUTH, "old_string": "max: 3", "new_string": "max: 5"}), "ask")
        text = open(full, encoding="utf-8").read().replace("max: 3", "max: 5")
        open(full, "w", encoding="utf-8").write(text)
        for _ in range(5):
            self.assertEqual(self.call(UP, self.up()), "allow")
        self.assertEqual(self.call(UP, self.up()), "deny")

    def test_close(self):
        self.approve()
        cmd = f'python3 .claude/hooks/juvant_hooks.py close-authorization {AUTH} "filed 42 invoices"'
        self.assertEqual(self.call("Bash", {"command": cmd}), "allow", "closing never asks")
        self.assertEqual(self.call("Bash", {"command": cmd + " ; rm -rf memory"}), "ask")
        env = dict(os.environ, CLAUDE_PROJECT_DIR=self.repo)
        p = subprocess.run([sys.executable, SCRIPT, "close-authorization", AUTH, "filed 42 invoices"],
                           capture_output=True, text=True, env=env, timeout=20)
        self.assertEqual(p.returncode, 0, p.stderr)
        text = open(os.path.join(self.repo, AUTH), encoding="utf-8").read()
        self.assertIn("status: closed", text)
        self.assertIn("filed 42 invoices", text)
        self.assertEqual(self.call(UP, self.up()), "ask")
        p = subprocess.run([sys.executable, SCRIPT, "close-authorization", "memory/decisions/x.md"],
                           capture_output=True, text=True, env=env, timeout=20)
        self.assertEqual(p.returncode, 2, "only authorization files")


FINOM_LIST = "mcp__claude_ai_Finom__transactions__listTransactions"


class ReviewerNudges(HookCase):
    def call(self, tool, inp=None, session="s1", agent=None):
        ev = {"tool_name": tool, "tool_input": inp or {}, "session_id": session}
        if agent:
            ev["agent_type"] = agent
        rc, out, _ = self.run_hook("limits", ev)
        hs = out.get("hookSpecificOutput", {})
        return rc, hs.get("permissionDecision"), hs.get("additionalContext", "")

    def test_first_domain_call_then_once_more(self):
        notes = [self.call(FINOM_LIST)[2] for _ in range(9)]
        self.assertIn("juvant-os hook note:", notes[0])
        self.assertIn("roles/finance.md", notes[0])
        self.assertIn("finance reviewer (the `finance` agent", notes[0])
        self.assertEqual(notes[1:7], [""] * 6)
        self.assertIn("turned from looking things up into analysis", notes[7], "the 8th call nudges again")
        self.assertEqual(notes[8], "")
        self.assertEqual(len([r for r in self.state("activity.jsonl") if r["event"] == "nudge"]), 2)

    def test_other_finance_connectors_and_skills(self):
        for tool in ("mcp__claude_ai_Finom__bank__searchCards", "mcp__acme-bank__get_balance",
                     "mcp__x__invoicing__search_invoices", "mcp__aruba__list_invoices"):
            with self.subTest(tool=tool):
                self.assertIn("finance", self.call(tool, session=tool)[2])
        self.assertIn("roles/finance.md", self.call("Skill", {"skill": "reconciliation"}, session="k1")[2])
        self.assertIn("roles/legal.md", self.call("Skill", {"skill": "review-contract"}, session="k2")[2])

    def test_one_count_per_domain(self):
        self.assertIn("finance", self.call(FINOM_LIST)[2])
        self.assertIn("legal", self.call("Skill", {"skill": "triage-nda"})[2])
        self.assertEqual(self.call("Skill", {"skill": "invoice-chase"})[2], "", "finance already nudged in this session")
        self.assertIn("finance", self.call(FINOM_LIST, session="s2")[2], "each session starts afresh")

    def test_no_nudge_for_subagents_or_the_role_itself(self):
        self.assertEqual(self.call(FINOM_LIST, agent="finance")[2], "")
        self.assertEqual(self.call(FINOM_LIST, agent="general-purpose")[2], "")
        self.run_hook("session-start", {"session_id": "fin", "agent_type": "finance"})
        self.assertEqual(self.call(FINOM_LIST, session="fin")[2], "")
        self.run_hook("session-start", {"session_id": "leg", "agent_type": "legal"})
        self.assertIn("finance", self.call(FINOM_LIST, session="leg")[2], "a legal session working on finance data")

    def test_unrelated_tools_and_no_session(self):
        for tool, inp in ((P_LOCAL + "outlook_email_search", {}), ("Read", {"file_path": "x.md"}),
                          ("Skill", {"skill": "wrap-up"}), (P_LOCAL + "sharepoint_search", {})):
            with self.subTest(tool=tool):
                self.assertEqual(self.call(tool, inp)[2], "")
        self.assertEqual(self.call(FINOM_LIST, session="")[2], "")

    def test_never_changes_a_limits_decision(self):
        rc, d, note = self.call("mcp__claude_ai_Finom__transactions__create_payment", {})
        self.assertEqual((rc, d), (2, "deny"))
        rc, d, note = self.call(FINOM_LIST)
        self.assertEqual((rc, d), (0, None), "still allowed, only context added")

    def test_broken_config_means_no_nudge(self):
        cfg_dir = tempfile.mkdtemp(prefix="jv2-cfg-")
        self.addCleanup(shutil.rmtree, cfg_dir, True)
        for f in ("juvant_hooks.py", "limits.json"):
            shutil.copy(os.path.join(HOOKS, f), cfg_dir)
        open(os.path.join(cfg_dir, "nudges.json"), "w").write("{broken")
        ev = {"tool_name": FINOM_LIST, "tool_input": {}, "session_id": "s"}
        rc, out, _ = self.run_hook("limits", ev, os.path.join(cfg_dir, "juvant_hooks.py"))
        self.assertEqual((rc, out), (0, {}))

    def test_session_start_explains_hook_notes(self):
        _, out, _ = self.run_hook("session-start", {"session_id": "s"})
        self.assertIn("juvant-os hook note:", out["hookSpecificOutput"]["additionalContext"])



SETTINGS_PATH = "memory/authorizations/2026-11-11-gutenberg.settings.json"
GOOD_SETTINGS = {"permissions": {"allow": [
    "Bash(az deployment group create --subscription 00000000-0000-0000-0000-000000000000 --resource-group rg-x-dev:*)",
    "Bash(gh repo create juvantlabs/x --private:*)"], "deny": ["Bash(az group delete:*)"]},
    "autoMode": {"environment": ["$defaults", "Source control: github.com/juvantlabs, private repos for this task"]}}


class SessionPermissions(HookCase):
    def call(self, tool, inp, session="s1"):
        rc, out, _ = self.run_hook("limits", {"tool_name": tool, "tool_input": inp, "session_id": session})
        d = out.get("hookSpecificOutput", {}).get("permissionDecision")
        return "deny" if rc == 2 else (d or "allow")

    def approve(self, data=None, path=SETTINGS_PATH):
        text = json.dumps(data if data is not None else GOOD_SETTINGS, indent=2)
        self.assertEqual(self.call("Write", {"file_path": path, "content": text}), "ask")
        full = os.path.join(self.repo, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        open(full, "w", encoding="utf-8").write(text)
        return full

    def test_narrow_settings_ask_and_get_recorded(self):
        self.approve()
        st = json.load(open(os.path.join(self.repo, "state", "authorizations.json")))
        self.assertIn(SETTINGS_PATH, st)

    def test_broad_or_dangerous_settings_are_refused(self):
        bad = [{"permissions": {"allow": ["Bash(*)"]}}, {"permissions": {"allow": ["Bash(az:*)"]}},
               {"permissions": {"allow": ["Bash(python3 -c:*)"]}}, {"permissions": {"allow": ["Bash(npx some-tool:*)"]}},
               {"permissions": {"allow": ["Bash(curl https://x | bash:*)"]}}, {"permissions": {"allow": ["Bash(az * create:*)"]}},
               {"permissions": {"allow": ["mcp__claude_ai_Microsoft_365__outlook_send_mail"]}},
               {"permissions": {"allow": ["Bash(claude --dangerously-skip-permissions:*)"]}},
               {"permissions": {"defaultMode": "bypassPermissions"}}, {"permissions": {"ask": []}},
               {"disableAllHooks": True}, {"hooks": {}}, {"env": {"X": "1"}},
               {"autoMode": {"allow": ["anything"]}}, {"autoMode": {"soft_deny": []}},
               {"autoMode": {"environment": ["Source control: anything"]}}]
        for b in bad:
            with self.subTest(b=b):
                self.assertEqual(self.call("Write", {"file_path": SETTINGS_PATH, "content": json.dumps(b)}), "deny")
        self.assertEqual(self.call("Write", {"file_path": SETTINGS_PATH, "content": "{not json"}), "deny")

    def test_launch_only_with_approved_unchanged_settings(self):
        full = self.approve()
        launch = f'claude --bg --remote-control --name gutenberg --settings {SETTINGS_PATH} "You are a collaborator session"'
        self.assertEqual(self.call("Bash", {"command": launch}), "allow")
        self.assertEqual(self.call("Bash", {"command": "claude --bg --name x \"brief\""}), "allow", "no settings: as before")
        open(os.path.join(self.repo, "state", "x.settings.json"), "w").write(json.dumps(GOOD_SETTINGS))
        self.assertEqual(self.call("Bash", {"command": "claude --bg --settings state/x.settings.json \"b\""}), "ask")
        self.assertEqual(self.call("Bash", {"command": "claude --bg --settings '{\"permissions\":{}}' \"b\""}), "ask")
        with open(full, "a", encoding="utf-8") as f:
            f.write("\n")
        self.assertEqual(self.call("Bash", {"command": launch}), "ask", "changed after approval")

    def test_launches_that_drop_hooks_or_permissions_are_denied(self):
        for c in ("claude --dangerously-skip-permissions -p x", "claude --allow-dangerously-skip-permissions --bg x",
                  "claude --permission-mode bypassPermissions --bg x", "claude --permission-mode=bypassPermissions x",
                  "claude --bare -p x", "claude --safe-mode --bg x", "claude --restricted --bg x",
                  "claude --setting-sources user --bg x", "cd /tmp && claude --bare x"):
            with self.subTest(c=c):
                self.assertEqual(self.call("Bash", {"command": c}), "deny")
        self.assertEqual(self.call("Bash", {"command": "claude --permission-mode auto --bg --name x \"b\""}), "allow")


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


class MemoryDigest(HookCase):
    def write(self, rel, text):
        path = os.path.join(self.repo, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    def decision(self, name, date, status, title):
        self.write(f"memory/decisions/{name}.md", f"---\ndate: {date}\nstatus: {status}\n---\n\n# {title}\n")

    def ctx(self, event=None):
        _, out, _ = self.run_hook("session-start", event or {"session_id": "s"})
        return out["hookSpecificOutput"]["additionalContext"]

    def test_digest_contents(self):
        self.write("memory/map.md", "| Contracts | SharePoint |")
        self.decision("2026-09-15-old-price", "2026-09-15", "superseded", "Old price")
        self.decision("2026-10-20-new-price", "2026-10-20", "active", "New price 49")
        self.write("memory/journal/2026-11-05.md", "- Waiting for the CEO: older\n")
        self.write("memory/journal/2026-11-06.md", "## x\n- Done: a\n- Waiting for the CEO: approve the packet\n")
        c = self.ctx()
        self.assertIn("| Contracts | SharePoint |", c)
        self.assertIn("New price 49 (memory/decisions/2026-10-20-new-price.md)", c)
        self.assertNotIn("Old price", c)
        self.assertIn("approve the packet", c)
        self.assertNotIn("older", c)

    def test_projects_listed(self):
        self.write("memory/projects/launch/README.md", "---\nstatus: active\n---\n\n# Assist 2.0 launch\n")
        self.write("memory/projects/launch/decisions/2026-11-01-x.md", "---\nstatus: active\n---\n\n# Launch in January\n")
        self.write("memory/projects/old/README.md", "---\nstatus: closed\n---\n\n# Old site\n")
        self.write("memory/projects/paused/README.md", "---\nstatus: paused\n---\n\n# Paused thing\n")
        c = self.ctx()
        self.assertIn("Assist 2.0 launch (active) — memory/projects/launch/; latest decision: Launch in January", c)
        self.assertIn("Paused thing (paused)", c)
        self.assertNotIn("Old site", c)

    def test_recent_decisions_capped_newest_first(self):
        for i in range(1, 13):
            self.decision(f"2026-10-{i:02d}-d{i}", f"2026-10-{i:02d}", "active", f"Decision {i}")
        c = self.ctx()
        self.assertIn("Decision 12", c)
        self.assertIn("Decision 5", c)
        self.assertNotIn("Decision 4 ", c)
        self.assertLess(c.index("Decision 12"), c.index("Decision 11"))

    def test_waiting_items_shown_to_the_ceo(self):
        # The agent can't speak first: the CEO sees the list on screen (systemMessage).
        self.write("memory/journal/2026-11-06.md",
                   "## 09:00\n- Waiting for the CEO: old item, done since\n## 18:00\n- Waiting for the CEO: approve the packet; merge PR 12\n")
        _, out, _ = self.run_hook("session-start", {"session_id": "s", "source": "startup"})
        msg = out.get("systemMessage", "")
        self.assertIn("Waiting for you (memory/journal/2026-11-06.md)", msg)
        self.assertIn("• approve the packet; merge PR 12", msg)
        self.assertNotIn("old item", msg)
        self.assertIn("already sees", out["hookSpecificOutput"]["additionalContext"])
        _, out, _ = self.run_hook("session-start", {"session_id": "s", "source": "compact"})
        self.assertNotIn("systemMessage", out)
        _, out, _ = self.run_hook("session-start", {"session_id": "t", "source": "startup", "agent_type": "finance"})
        self.assertNotIn("systemMessage", out)

    def test_nothing_waiting_no_banner(self):
        self.write("memory/journal/2026-11-06.md", "- Done: a\n")
        _, out, _ = self.run_hook("session-start", {"session_id": "s", "source": "startup"})
        self.assertNotIn("systemMessage", out)

    def test_a_newer_journal_without_the_line_does_not_hide_the_list(self):
        self.write("memory/journal/2026-11-11.md", "## 18:00\n- Waiting for the CEO: approve the offer; sign the NDA\n")
        self.write("memory/journal/2026-11-13.md", "- juvant-os updated to rc.12\n")
        _, out, _ = self.run_hook("session-start", {"session_id": "s", "source": "startup"})
        msg = out.get("systemMessage", "")
        self.assertIn("approve the offer", msg)
        self.assertIn("memory/journal/2026-11-11.md", msg)

    def test_a_newer_none_still_clears_the_list(self):
        self.write("memory/journal/2026-11-11.md", "- Waiting for the CEO: approve the offer\n")
        self.write("memory/journal/2026-11-12.md", "- Waiting for the CEO: none\n")
        self.write("memory/journal/2026-11-13.md", "- a note\n")
        _, out, _ = self.run_hook("session-start", {"session_id": "s", "source": "startup"})
        self.assertNotIn("systemMessage", out)

    def test_digest_capped(self):
        self.write("memory/map.md", "m" * 20000)
        c = self.ctx()
        self.assertIn("truncated: read memory/map.md", c)
        self.assertLess(len(c), 6500)

    def test_no_memory_no_digest(self):
        self.assertNotIn("Company memory digest", self.ctx())

    def test_no_digest_for_dedicated_agent_sessions(self):
        self.write("memory/map.md", "MAPLINE")
        self.assertNotIn("MAPLINE", self.ctx({"session_id": "s", "agent_type": "legal"}))


class Settings(unittest.TestCase):
    def test_registration(self):
        with open(os.path.join(ROOT, "framework", "templates", "settings.json"), encoding="utf-8") as f:
            s = json.load(f)
        pre = s["hooks"]["PreToolUse"][0]
        for name in ("Bash", "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "Grep", "Glob", "Skill", "mcp__"):
            self.assertIn(name, pre["matcher"])
        self.assertIn("juvant_hooks.py\" limits", pre["hooks"][0]["command"])
        for event, sub in (("SessionStart", "session-start"), ("SubagentStart", "subagent-start"),
                           ("SubagentStop", "subagent-stop"), ("Stop", "stop")):
            self.assertIn(f"juvant_hooks.py\" {sub}", s["hooks"][event][0]["hooks"][0]["command"])
        self.assertEqual(s["worktree"]["bgIsolation"], "none", "collaborator sessions must write where the CoS reads")
        deny = s["permissions"]["deny"]
        for prefix in (P_LOCAL, P_CLOUD):
            self.assertIn(prefix + "outlook_send_mail", deny)
        with open(os.path.join(HOOKS, "limits.json"), encoding="utf-8") as f:
            known = json.load(f)["known_prefixes"]
        denied = {d[: d.rindex("__") + 2] for d in deny}
        self.assertEqual(denied - set(known), set(), "a prefix with permission denies must be in known_prefixes")
        self.assertEqual(set(known) - denied, {"mcp__m365-mail__"},
                         "a known prefix without permission denies must be a server with no outbound tools")

    def test_matcher_covers_every_checked_tool(self):
        # Claude Code calls the hook only for tools the matcher names: the unit tests
        # above call it directly, so they can't notice a tool the matcher misses.
        hooks = load_hooks_module()
        with open(os.path.join(ROOT, "framework", "templates", "settings.json"), encoding="utf-8") as f:
            self.assertEqual(hooks.registration_gaps(json.load(f)), [])
        with open(SCRIPT, encoding="utf-8") as f:
            src = f.read()
        named = set()
        for group in re.findall(r"\btool (?:==|in) (\([^)]*\)|\"[A-Za-z]+\")", src):
            named.update(re.findall(r"\"([A-Z][A-Za-z]+)\"", group))
        self.assertTrue({"Read", "Grep", "Glob", "Bash", "Write"} <= named, named)
        self.assertEqual(named - set(hooks.LIMITS_TOOLS), set(), "a tool the code checks is missing from LIMITS_TOOLS")


    def test_no_unreachable_code(self):
        # A statement right after return/raise/continue/break in the same block never runs.
        import ast
        for path in (SCRIPT, os.path.join(ROOT, "framework", "dashboard", "build.py")):
            tree = ast.parse(open(path, encoding="utf-8").read())
            for node in ast.walk(tree):
                for field in ("body", "orelse", "finalbody"):
                    block = getattr(node, field, None)
                    if not isinstance(block, list):
                        continue
                    for i, stmt in enumerate(block[:-1]):
                        if isinstance(stmt, (ast.Return, ast.Raise, ast.Continue, ast.Break)):
                            self.fail(f"{os.path.basename(path)}:{block[i + 1].lineno}: unreachable after line {stmt.lineno}")

def load_hooks_module():
    spec = importlib.util.spec_from_file_location("juvant_hooks", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


OLD_MATCHER = "Bash|Write|Edit|MultiEdit|NotebookEdit|mcp__.*"


class Registration(HookCase):
    def write_settings(self, matcher=OLD_MATCHER, extra=None):
        with open(os.path.join(ROOT, "framework", "templates", "settings.json"), encoding="utf-8") as f:
            s = json.load(f)
        if matcher is None:
            s["hooks"]["PreToolUse"] = []
        else:
            s["hooks"]["PreToolUse"][0]["matcher"] = matcher
        if extra:
            s["hooks"]["PreToolUse"].append(extra)
        os.makedirs(os.path.join(self.repo, ".claude"), exist_ok=True)
        with open(os.path.join(self.repo, ".claude", "settings.json"), "w", encoding="utf-8") as f:
            json.dump(s, f, indent=2)
        return s

    def settings(self):
        with open(os.path.join(self.repo, ".claude", "settings.json"), encoding="utf-8") as f:
            return json.load(f)

    def fix(self):
        env = dict(os.environ, CLAUDE_PROJECT_DIR=self.repo)
        return subprocess.run([sys.executable, SCRIPT, "fix-registration"], capture_output=True, text=True, env=env, timeout=20)

    def test_session_start_warns_when_tools_are_not_registered(self):
        self.write_settings()
        _, out, _ = self.run_hook("session-start", {"session_id": "s", "source": "startup"})
        self.assertIn("Read, Grep, Glob", out.get("systemMessage", ""), "the CEO sees it on screen")
        self.assertIn("aren't checked", out["hookSpecificOutput"]["additionalContext"])

    def test_no_warning_with_the_template(self):
        self.write_settings(matcher="Bash|Read|Write|Edit|MultiEdit|NotebookEdit|Grep|Glob|mcp__.*")
        _, out, _ = self.run_hook("session-start", {"session_id": "s", "source": "startup"})
        self.assertNotIn("aren't checked", json.dumps(out))

    def test_fix_adds_missing_tools_and_keeps_the_rest(self):
        other = {"matcher": "WebFetch", "hooks": [{"type": "command", "command": "echo mine"}]}
        self.write_settings(matcher=OLD_MATCHER + "|WebSearch", extra=other)
        p = self.fix()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("Read, Grep, Glob", p.stdout)
        s = self.settings()
        hooks = load_hooks_module()
        self.assertEqual(hooks.registration_gaps(s), [])
        self.assertIn("WebSearch", s["hooks"]["PreToolUse"][0]["matcher"], "the company's own additions stay")
        self.assertIn(other, s["hooks"]["PreToolUse"], "other hooks untouched")
        self.assertIn(P_LOCAL + "outlook_send_mail", s["permissions"]["deny"])
        before = open(os.path.join(self.repo, ".claude", "settings.json"), encoding="utf-8").read()
        p = self.fix()
        self.assertEqual((p.returncode, p.stdout), (0, ""), "a second run changes nothing")
        self.assertEqual(open(os.path.join(self.repo, ".claude", "settings.json"), encoding="utf-8").read(), before)

    def test_fix_warns_but_does_not_rewrite_a_removed_registration(self):
        s = self.write_settings(matcher=None)
        p = self.fix()
        self.assertEqual(p.returncode, 0, "update goes on")
        self.assertIn("doesn't register the hard-limits hook", p.stderr)
        self.assertEqual(self.settings(), s, "the company's settings stay as they are")
        _, out, _ = self.run_hook("session-start", {"session_id": "s", "source": "startup"})
        self.assertIn("aren't checked", out.get("systemMessage", ""), "the CEO still sees it every session")

    def test_fix_without_or_with_broken_settings(self):
        self.assertEqual(self.fix().returncode, 0, "no settings: nothing to do")
        os.makedirs(os.path.join(self.repo, ".claude"), exist_ok=True)
        open(os.path.join(self.repo, ".claude", "settings.json"), "w").write("{not json")
        p = self.fix()
        self.assertEqual(p.returncode, 1)
        self.assertIn("unreadable", p.stderr)

    def test_matcher_rules(self):
        hooks = load_hooks_module()
        for m, tool, want in (("", "Read", True), ("*", "Read", True), ("Read", "Read", True),
                              ("Bash|Write", "Read", False), ("mcp__.*", "mcp__x__y", True),
                              ("Rea", "Read", False), ("(", "Read", False)):
            with self.subTest(m=m, tool=tool):
                self.assertEqual(hooks.matcher_covers(m, tool), want)

    def test_matcher_covers_every_checked_tool(self):
        # Claude Code calls the hook only for tools the matcher names: the unit tests
        # above call it directly, so they can't notice a tool the matcher misses.
        hooks = load_hooks_module()
        with open(os.path.join(ROOT, "framework", "templates", "settings.json"), encoding="utf-8") as f:
            self.assertEqual(hooks.registration_gaps(json.load(f)), [])
        with open(SCRIPT, encoding="utf-8") as f:
            src = f.read()
        named = set()
        for group in re.findall(r"\btool (?:==|in) (\([^)]*\)|\"[A-Za-z]+\")", src):
            named.update(re.findall(r"\"([A-Z][A-Za-z]+)\"", group))
        self.assertTrue({"Read", "Grep", "Glob", "Bash", "Write"} <= named, named)
        self.assertEqual(named - set(hooks.LIMITS_TOOLS), set(), "a tool the code checks is missing from LIMITS_TOOLS")


def load_hooks_module():
    spec = importlib.util.spec_from_file_location("juvant_hooks", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


OLD_MATCHER = "Bash|Write|Edit|MultiEdit|NotebookEdit|mcp__.*"


class Registration(HookCase):
    def write_settings(self, matcher=OLD_MATCHER, extra=None):
        with open(os.path.join(ROOT, "framework", "templates", "settings.json"), encoding="utf-8") as f:
            s = json.load(f)
        if matcher is None:
            s["hooks"]["PreToolUse"] = []
        else:
            s["hooks"]["PreToolUse"][0]["matcher"] = matcher
        if extra:
            s["hooks"]["PreToolUse"].append(extra)
        os.makedirs(os.path.join(self.repo, ".claude"), exist_ok=True)
        with open(os.path.join(self.repo, ".claude", "settings.json"), "w", encoding="utf-8") as f:
            json.dump(s, f, indent=2)
        return s

    def settings(self):
        with open(os.path.join(self.repo, ".claude", "settings.json"), encoding="utf-8") as f:
            return json.load(f)

    def fix(self):
        env = dict(os.environ, CLAUDE_PROJECT_DIR=self.repo)
        return subprocess.run([sys.executable, SCRIPT, "fix-registration"], capture_output=True, text=True, env=env, timeout=20)

    def test_session_start_warns_when_tools_are_not_registered(self):
        self.write_settings()
        _, out, _ = self.run_hook("session-start", {"session_id": "s", "source": "startup"})
        self.assertIn("Read, Grep, Glob", out.get("systemMessage", ""), "the CEO sees it on screen")
        self.assertIn("aren't checked", out["hookSpecificOutput"]["additionalContext"])

    def test_no_warning_with_the_template(self):
        self.write_settings(matcher="Bash|Read|Write|Edit|MultiEdit|NotebookEdit|Grep|Glob|Skill|mcp__.*")
        _, out, _ = self.run_hook("session-start", {"session_id": "s", "source": "startup"})
        self.assertNotIn("aren't checked", json.dumps(out))

    def test_fix_adds_missing_tools_and_keeps_the_rest(self):
        other = {"matcher": "WebFetch", "hooks": [{"type": "command", "command": "echo mine"}]}
        self.write_settings(matcher=OLD_MATCHER + "|WebSearch", extra=other)
        p = self.fix()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("Read, Grep, Glob", p.stdout)
        s = self.settings()
        hooks = load_hooks_module()
        self.assertEqual(hooks.registration_gaps(s), [])
        self.assertIn("WebSearch", s["hooks"]["PreToolUse"][0]["matcher"], "the company's own additions stay")
        self.assertIn(other, s["hooks"]["PreToolUse"], "other hooks untouched")
        self.assertIn(P_LOCAL + "outlook_send_mail", s["permissions"]["deny"])
        before = open(os.path.join(self.repo, ".claude", "settings.json"), encoding="utf-8").read()
        p = self.fix()
        self.assertEqual((p.returncode, p.stdout), (0, ""), "a second run changes nothing")
        self.assertEqual(open(os.path.join(self.repo, ".claude", "settings.json"), encoding="utf-8").read(), before)

    def test_fix_warns_but_does_not_rewrite_a_removed_registration(self):
        s = self.write_settings(matcher=None)
        p = self.fix()
        self.assertEqual(p.returncode, 0, "update goes on")
        self.assertIn("doesn't register the hard-limits hook", p.stderr)
        self.assertEqual(self.settings(), s, "the company's settings stay as they are")
        _, out, _ = self.run_hook("session-start", {"session_id": "s", "source": "startup"})
        self.assertIn("aren't checked", out.get("systemMessage", ""), "the CEO still sees it every session")

    def test_fix_without_or_with_broken_settings(self):
        self.assertEqual(self.fix().returncode, 0, "no settings: nothing to do")
        os.makedirs(os.path.join(self.repo, ".claude"), exist_ok=True)
        open(os.path.join(self.repo, ".claude", "settings.json"), "w").write("{not json")
        p = self.fix()
        self.assertEqual(p.returncode, 1)
        self.assertIn("unreadable", p.stderr)

    def test_matcher_rules(self):
        hooks = load_hooks_module()
        for m, tool, want in (("", "Read", True), ("*", "Read", True), ("Read", "Read", True),
                              ("Bash|Write", "Read", False), ("mcp__.*", "mcp__x__y", True),
                              ("Rea", "Read", False), ("(", "Read", False)):
            with self.subTest(m=m, tool=tool):
                self.assertEqual(hooks.matcher_covers(m, tool), want)


if __name__ == "__main__":
    unittest.main()
