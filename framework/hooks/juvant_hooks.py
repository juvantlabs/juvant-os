#!/usr/bin/env python3
"""juvant-os v2 hooks. One script, one subcommand per Claude Code event.

    limits          PreToolUse: hard limits (design §7). Fails closed.
    session-start   SessionStart: status line, findings to surface, activity.
    subagent-start  SubagentStart: inject manifesto.md (+ roles/<id>.md), activity.
    subagent-stop   SubagentStop: activity.
    stop            Stop: activity.
    log-outcome     called by the wrap-up skill: [--agent TYPE] "one line".

Reads the event JSON on stdin. Paths are relative to $CLAUDE_PROJECT_DIR (the
company repo); the config sits next to this file. Standard library only.
"""
import json
import os
import re
import shlex
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "limits.json")
ROOT = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
STATE = os.path.join(ROOT, "state")
ACTIVITY = os.path.join(STATE, "activity.jsonl")
FINDINGS = os.path.join(STATE, "limits-findings.jsonl")
CONTEXT_CAP = 9500
OUTCOME_CAP = 160
ROLE_ID = re.compile(r"^[a-z][a-z0-9-]{0,40}$")


# ── small helpers ────────────────────────────────────────────────────────────
def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def read_event():
    raw = sys.stdin.read()
    try:
        ev = json.loads(raw) if raw.strip() else {}
    except ValueError:
        ev = {}
    return ev if isinstance(ev, dict) else {}


def append_jsonl(path, row):
    """Best effort: logging never blocks a tool call or a session."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    except OSError:
        pass


def one_line(text, cap):
    text = " ".join(str(text or "").split())
    return text if len(text) <= cap else text[: cap - 1] + "…"


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")


def deny(reason):
    # stderr + exit 2 is what Claude Code treats as a block; the JSON is the
    # documented form. Both, so either reading of the contract denies.
    emit({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                 "permissionDecision": "deny",
                                 "permissionDecisionReason": reason}})
    sys.stderr.write(reason + "\n")
    sys.exit(2)


def ask(reason):
    emit({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                 "permissionDecision": "ask",
                                 "permissionDecisionReason": reason}})
    sys.exit(0)


def load_config():
    with open(CONFIG, encoding="utf-8") as f:
        cfg = json.load(f)
    # Compile now: a bad pattern must fail closed, not at match time.
    for rule in cfg["mcp"]["deny"] + cfg["mcp"]["ask"] + cfg["bash"]["deny"] + cfg["bash"]["ask"] + cfg["secrets"]:
        rule["re"] = re.compile(rule["pattern"])
    cfg["mcp"]["draft_allow_re"] = re.compile(cfg["mcp"]["draft_allow"])
    cfg["mcp"]["draft_never_re"] = re.compile(cfg["mcp"]["draft_never"])
    return cfg


# ── limits ───────────────────────────────────────────────────────────────────
def mcp_decision(cfg, tool):
    """(decision, rule) for an mcp__ tool; decision in {None, 'deny', 'ask'}."""
    name = tool.rsplit("__", 1)[-1].lower()
    m = cfg["mcp"]
    is_draft = bool(m["draft_allow_re"].search(name)) and not m["draft_never_re"].search(name)
    for rule in m["deny"]:
        if rule["id"] == "outbound" and is_draft:
            continue
        if rule["re"].search(name):
            return "deny", rule
    for rule in m["ask"]:
        if rule["re"].search(name):
            return "ask", rule
    return None, None


def texts_to_scan(tool, inp):
    if tool == "Bash":
        return [inp.get("command", "")]
    if tool == "Write":
        return [inp.get("content", "")]
    if tool == "Edit":
        return [inp.get("new_string", "")]
    if tool == "MultiEdit":
        return [e.get("new_string", "") for e in inp.get("edits", []) if isinstance(e, dict)]
    if tool == "NotebookEdit":
        return [inp.get("new_source", "")]
    return []


def shell_segments(command):
    """Split a command into simple commands (lists of words) on ; & | and newlines
    outside quotes, keeping redirection operators as words. None if it can't be
    parsed (unbalanced quotes): callers treat that as unsafe."""
    try:
        lex = shlex.shlex(command.replace("\n", " ; "), posix=True, punctuation_chars=";&|<>")
        lex.whitespace_split = True
        segments, cur = [], []
        for tok in lex:
            if tok and set(tok) <= set(";&|"):
                if cur:
                    segments.append(cur)
                cur = []
            else:
                cur.append(tok)
        if cur:
            segments.append(cur)
        return segments
    except ValueError:
        return None


def rm_outside_repo(cfg, command):
    """True if a recursive rm targets something outside the repo and temp dirs."""
    root = os.path.realpath(ROOT)
    temps = tuple(cfg["bash"]["temp_dirs"])
    segments = shell_segments(command)
    if segments is None:
        segments = [s.split() for s in re.split(r"[;&|\n]+", command)]
    for words in segments:
        while words and (words[0] in ("sudo", "env", "command", "builtin") or "=" in words[0]):
            words = words[1:]
        if not words or os.path.basename(words[0]) != "rm":
            continue
        flags = [w for w in words[1:] if w.startswith("-") and not w.startswith("--")]
        long_flags = [w for w in words[1:] if w.startswith("--")]
        recursive = any("r" in f[1:].lower() for f in flags) or "--recursive" in long_flags
        if not recursive:
            continue
        for target in (w for w in words[1:] if not w.startswith("-")):
            if target.startswith(("~", "$HOME", "${HOME}")) or ".." in target.split("/"):
                return True
            if target.startswith("/"):
                real = os.path.realpath(target)
                if real.startswith(temps) or target.startswith(temps):
                    continue
                if real == root or not real.startswith(root + os.sep):
                    return True
            elif target in ("*", ".", "./", ".git", "./.git"):
                return True  # the whole repo, or its history
    return False


def cmd_limits():
    ev = read_event()
    tool = str(ev.get("tool_name", ""))
    inp = ev.get("tool_input") or {}
    if not isinstance(inp, dict):
        inp = {}
    try:
        cfg = load_config()
    except (OSError, ValueError, KeyError, TypeError, re.error) as e:
        deny(f"juvant-os hard limits: config unreadable ({CONFIG}: {e}). Every checked tool is blocked until it is restored (run `update`).")

    for rule in cfg["secrets"]:
        for text in texts_to_scan(tool, inp):
            if text and rule["re"].search(text):
                deny(f"juvant-os hard limit 3: secret-shaped text ({rule['id']}) in a {tool} call. "
                     "Secrets never go in the repo, memory or chat: the CEO stores them from their own terminal.")

    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit") and in_claude_dir(
            str(inp.get("file_path") or inp.get("notebook_path") or "")):
        ask("juvant-os hard limit (protect-claude-dir): this changes .claude/, where the hard limits, agents and "
            "settings live. The CEO confirms; framework files change through the update skill.")

    if tool.startswith("mcp__"):
        decision, rule = mcp_decision(cfg, tool)
        if decision:
            prefix = tool[: len(tool) - len(tool.rsplit("__", 1)[-1])]
            if prefix not in cfg["known_prefixes"]:
                append_jsonl(FINDINGS, {"ts": now(), "kind": "unlisted-prefix", "prefix": prefix,
                                        "tool": tool, "decision": decision, "rule": rule["id"]})
            reason = f"juvant-os hard limit ({rule['id']}): {tool} — {rule['why']}."
            deny(reason) if decision == "deny" else ask(reason)
        return

    if tool == "Bash":
        command = str(inp.get("command", ""))
        for rule in cfg["bash"]["deny"]:
            if rule["re"].search(command):
                deny(f"juvant-os hard limit ({rule['id']}): {rule['why']}.")
        for rule in cfg["bash"]["ask"]:
            if rule["re"].search(command):
                ask(f"juvant-os hard limit ({rule['id']}): {rule['why']}.")
        if bash_writes_claude_dir(command):
            ask("juvant-os hard limit (protect-claude-dir): this command may change .claude/, where the hard limits, "
                "agents and settings live. The CEO confirms; framework files change through the update skill.")
        if cfg["bash"].get("rm_outside_repo") == "ask" and rm_outside_repo(cfg, command):
            ask("juvant-os hard limit (rm-outside-repo): recursive delete outside the company repo (hard limit 4).")


# ── .claude/ protection (the hard limits must not edit themselves) ───────────
READ_ONLY_VERBS = {"cat", "less", "head", "tail", "ls", "grep", "rg", "wc", "diff", "file", "stat", "sha256sum", "shasum"}
GIT_READ = {"diff", "log", "show", "status", "ls-files", "blame", "add", "commit"}
SANCTIONED = re.compile(r"^(bash|sh)\s+(\./)?\.claude/skills/update/update\.sh(\s|$)")


def in_claude_dir(path):
    if not path:
        return False
    full = os.path.realpath(path if os.path.isabs(path) else os.path.join(ROOT, path))
    base = os.path.realpath(os.path.join(ROOT, ".claude"))
    return full == base or full.startswith(base + os.sep)


def bash_writes_claude_dir(command):
    """True if a Bash command may write under .claude/ outside the sanctioned update script."""
    if ".claude" not in command:
        return False
    segments = shell_segments(command)
    if segments is None:
        return True
    for words in segments:
        seg = " ".join(words)
        if ".claude" not in seg:
            continue
        if SANCTIONED.match(seg) and not re.search(r"--(from|repo|target)\b", seg):
            continue  # update from a published tag only; a local source could carry anything
        for i, w in enumerate(words[:-1]):
            if w in (">", ">>", ">|") and ".claude" in words[i + 1]:
                return True
        if any(re.match(r"^\d*>>?\S*\.claude", w) for w in words):
            return True
        while words and "=" in words[0] and not words[0].startswith(("-", "/", ".")):
            words = words[1:]
        if not words:
            continue
        verb = os.path.basename(words[0])
        if verb in READ_ONLY_VERBS:
            continue
        if verb == "git" and len(words) > 1 and words[1] in GIT_READ:
            continue
        if verb == "find" and not any(w in ("-delete", "-exec", "-execdir", "-ok") for w in words):
            continue
        if verb in ("python3", "python") and len(words) > 1 and words[1].endswith(".claude/hooks/juvant_hooks.py"):
            continue
        return True
    return False


# ── context injection and activity ───────────────────────────────────────────
def read_text(rel):
    try:
        with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return None


def activity(event, ev, **extra):
    row = {"ts": now(), "event": event, "session": ev.get("session_id", "")}
    for key in ("agent_type", "agent_id"):
        if ev.get(key):
            row[key] = ev[key]
    row.update({k: v for k, v in extra.items() if v})
    append_jsonl(ACTIVITY, row)


def cmd_subagent_start():
    ev = read_event()
    activity("subagent_start", ev)
    parts = []
    manifesto = read_text("manifesto.md") or read_text(os.path.join(".claude", "company-manifesto.md"))
    parts.append("# Company manifesto\n\n" + manifesto if manifesto
                 else "# Company manifesto\n\n(manifesto.md is missing from the company repo: tell the CEO.)")
    agent = str(ev.get("agent_type", ""))
    if ROLE_ID.match(agent):
        card = read_text(os.path.join("roles", agent + ".md"))
        if card:
            parts.append(f"# Your role card (roles/{agent}.md)\n\n" + card)
    text = "\n\n".join(parts)
    if len(text) > CONTEXT_CAP:
        text = text[:CONTEXT_CAP] + "\n\n[truncated: read manifesto.md and your role card in full]"
    emit({"hookSpecificOutput": {"hookEventName": "SubagentStart", "additionalContext": text}})


MAP_CAP = 2500
DIGEST_CAP = 5000
RECENT_DECISIONS = 8


def frontmatter(text):
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    out = {}
    if m:
        for line in m.group(1).splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                out[k.strip()] = v.strip()
    return out


def memory_digest():
    """Short memory context for the main session: map, recent active decisions,
    and what the latest journal says is waiting for the CEO."""
    parts = []
    m = read_text(os.path.join("memory", "map.md"))
    if m:
        parts.append("## memory/map.md\n\n" + (m if len(m) <= MAP_CAP else m[:MAP_CAP] + "\n[…truncated: read memory/map.md]"))
    ddir = os.path.join(ROOT, "memory", "decisions")
    rows = []
    try:
        names = sorted((n for n in os.listdir(ddir) if n.endswith(".md")), reverse=True)
    except OSError:
        names = []
    for n in names:
        text = read_text(os.path.join("memory", "decisions", n)) or ""
        fm = frontmatter(text)
        if fm.get("status", "active") != "active":
            continue
        title = next((l[2:].strip() for l in text.splitlines() if l.startswith("# ")), n[:-3])
        rows.append(f"- {fm.get('date', n[:10])} — {title} (memory/decisions/{n})")
        if len(rows) == RECENT_DECISIONS:
            break
    if rows:
        parts.append("## Recent decisions (active)\n\n" + "\n".join(rows))
    prow = []
    pdir = os.path.join(ROOT, "memory", "projects")
    try:
        slugs = sorted(n for n in os.listdir(pdir) if os.path.isdir(os.path.join(pdir, n)))
    except OSError:
        slugs = []
    for slug in slugs:
        card = read_text(os.path.join("memory", "projects", slug, "README.md")) or ""
        status = frontmatter(card).get("status", "active")
        if status == "closed":
            continue
        name = next((l[2:].strip() for l in card.splitlines() if l.startswith("# ")), slug)
        latest = ""
        try:
            ds = sorted((n for n in os.listdir(os.path.join(pdir, slug, "decisions")) if n.endswith(".md")), reverse=True)
        except OSError:
            ds = []
        if ds:
            dt_ = read_text(os.path.join("memory", "projects", slug, "decisions", ds[0])) or ""
            latest = "; latest decision: " + next((l[2:].strip() for l in dt_.splitlines() if l.startswith("# ")), ds[0][:-3])
        prow.append(f"- {name} ({status}) — memory/projects/{slug}/{latest}")
        if len(prow) == 10:
            break
    if prow:
        parts.append("## Projects\n\n" + "\n".join(prow))
    jdir = os.path.join(ROOT, "memory", "journal")
    try:
        days = sorted((n for n in os.listdir(jdir) if re.match(r"\d{4}-\d{2}-\d{2}\.md$", n)), reverse=True)
    except OSError:
        days = []
    if days:
        text = read_text(os.path.join("memory", "journal", days[0])) or ""
        waiting = [l.strip() for l in text.splitlines() if re.match(r"^\s*-\s*Waiting for the CEO", l, re.I)]
        if waiting:
            parts.append(f"## Waiting for the CEO (memory/journal/{days[0]})\n\n" + "\n".join(waiting))
    if not parts:
        return ""
    text = "# Company memory digest\n\nFrom the files in memory/. Search memory/ for anything else; if a fact isn't there, say it isn't recorded.\n\n" + "\n\n".join(parts)
    return text if len(text) <= DIGEST_CAP else text[:DIGEST_CAP] + "\n[…truncated]"


def cmd_session_start():
    ev = read_event()
    activity("session_start", ev, source=ev.get("source", ""))
    lines = []
    agent = str(ev.get("agent_type", ""))
    if ROLE_ID.match(agent):
        # A dedicated agent running as this session's main agent (claude --agent
        # <id>, or a collaborator session). CLAUDE.md describes the Chief of
        # Staff; this session is not the CoS.
        lines.append(f"This session runs as `{agent}`, not as the Chief of Staff: CLAUDE.md describes the "
                     "CoS's job. Keep its company rules (hard limits, memory, manifesto) and follow your own "
                     "role and the brief you were given. The CEO can talk to you directly here.")
        card = read_text(os.path.join("roles", agent + ".md"))
        if card:
            lines.append(f"# Your role card (roles/{agent}.md)\n\n" + card[:CONTEXT_CAP])
    try:
        load_config()
        lines.append("juvant-os hard limits active: outbound draft-only, no payments or invoice issuing, "
                     "no secrets in files or commands, destructive changes ask the CEO.")
    except (OSError, ValueError, KeyError, TypeError, re.error) as e:
        lines.append(f"WARNING: juvant-os hard limits config is unreadable ({e}). Checked tools are blocked. "
                     "Tell the CEO and restore it with `update`.")
    prefixes = set()
    try:
        with open(FINDINGS, encoding="utf-8") as f:
            for line in f:
                try:
                    prefixes.add(json.loads(line).get("prefix", ""))
                except ValueError:
                    continue
    except OSError:
        pass
    prefixes.discard("")
    if not ROLE_ID.match(agent):
        digest = memory_digest()
        if digest:
            lines.append(digest)
    if prefixes:
        lines.append("Tell the CEO: limited tools were called under MCP prefixes the permission rules don't list ("
                     + ", ".join(sorted(prefixes)) + "). The hook blocked them; add the prefixes to "
                     "`known_prefixes` and to the permission denies in .claude/settings.json.")
    emit({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "\n".join(lines)}})


def cmd_subagent_stop():
    ev = read_event()
    activity("subagent_stop", ev, outcome=one_line(ev.get("last_assistant_message", ""), OUTCOME_CAP))


def cmd_stop():
    ev = read_event()
    activity("stop", ev, outcome=one_line(ev.get("last_assistant_message", ""), OUTCOME_CAP))


def cmd_log_outcome():
    args = sys.argv[2:]
    agent = ""
    if len(args) >= 2 and args[0] == "--agent":
        agent, args = args[1], args[2:]
    text = one_line(" ".join(args), OUTCOME_CAP)
    if not text:
        sys.stderr.write('usage: juvant_hooks.py log-outcome [--agent TYPE] "one line"\n')
        sys.exit(2)
    row = {"ts": now(), "event": "outcome", "outcome": text}
    if agent:
        row["agent_type"] = agent
    append_jsonl(ACTIVITY, row)
    print("logged")


COMMANDS = {
    "limits": cmd_limits,
    "session-start": cmd_session_start,
    "subagent-start": cmd_subagent_start,
    "subagent-stop": cmd_subagent_stop,
    "stop": cmd_stop,
    "log-outcome": cmd_log_outcome,
}

if __name__ == "__main__":
    name = sys.argv[1] if len(sys.argv) > 1 else ""
    if name not in COMMANDS:
        sys.stderr.write("usage: juvant_hooks.py " + "|".join(COMMANDS) + "\n")
        sys.exit(2)
    try:
        COMMANDS[name]()
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001 — a crash in limits must block, elsewhere it must not
        if name == "limits":
            deny(f"juvant-os hard limits: the check failed ({type(e).__name__}: {e}). Blocked to stay safe.")
        sys.stderr.write(f"juvant_hooks {name}: {type(e).__name__}: {e}\n")
        sys.exit(0)
