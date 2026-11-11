#!/usr/bin/env python3
"""juvant-os v2 hooks. One script, one subcommand per Claude Code event.

    limits          PreToolUse: hard limits (design §7). Fails closed.
    session-start   SessionStart: status line, findings to surface, activity.
    subagent-start  SubagentStart: inject manifesto.md (+ roles/<id>.md), activity.
    subagent-stop   SubagentStop: activity.
    stop            Stop: activity.
    log-outcome     called by the wrap-up skill: [--agent TYPE] "one line".
    close-authorization  called by the long-task skill: <file> [reason].
    fix-registration  called by update.sh: register `limits` in .claude/settings.json
                    for every tool it checks (adds what's missing, keeps the rest).

Reads the event JSON on stdin. Paths are relative to $CLAUDE_PROJECT_DIR (the
company repo); the config sits next to this file. Standard library only.
"""
import json
import os
import re
import shlex
import subprocess
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
SETTINGS = os.path.join(ROOT, ".claude", "settings.json")
# Every built-in tool cmd_limits() looks at. Claude Code calls the hook only for
# tools its PreToolUse matcher in .claude/settings.json names, so the matcher
# must cover all of these and MCP tools; a test keeps this list and the code in step.
LIMITS_TOOLS = ("Bash", "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "Grep", "Glob", "Skill")
MCP_PROBE = "mcp__any__tool"
LIMITS_COMMAND = 'python3 "$CLAUDE_PROJECT_DIR/.claude/hooks/juvant_hooks.py" limits'


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


def log_decision(decision, reason):
    """Every limits deny or ask goes to the activity log: who, which tool, which rule. Best effort."""
    ev = globals().get("LAST_EVENT") or {}
    if ev.get("tool_name"):
        activity("limits_" + decision, ev, tool=str(ev.get("tool_name")), reason=one_line(reason, 200))


def deny(reason):
    log_decision("deny", reason)
    # stderr + exit 2 is what Claude Code treats as a block; the JSON is the
    # documented form. Both, so either reading of the contract denies.
    emit({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                 "permissionDecision": "deny",
                                 "permissionDecisionReason": reason}})
    sys.stderr.write(reason + "\n")
    sys.exit(2)


def ask(reason):
    log_decision("ask", reason)
    emit({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                 "permissionDecision": "ask",
                                 "permissionDecisionReason": reason}})
    sys.exit(0)


COMPANY_CONFIG = os.path.join(ROOT, ".claude", "limits-company.json")
# What a company file may add to: never exemptions (mcp.create, draft or private-publish rules).
COMPANY_LISTS = {("known_prefixes",), ("mcp", "deny"), ("mcp", "ask"), ("bash", "deny"), ("bash", "ask"), ("secrets",)}


def merge_company(cfg, path=None):
    """Append the company's own additions (.claude/limits-company.json) to the framework rules.
    The file is the company's: update never touches it, and writing it asks the CEO. It can only
    add. Anything else in it is an error, so the hard limits fail closed until it's fixed."""
    path = path or COMPANY_CONFIG
    if not os.path.exists(path):
        return cfg
    try:
        with open(path, encoding="utf-8") as f:
            extra = json.load(f)
    except (OSError, ValueError) as e:
        raise ValueError(f"{path} is unreadable ({e})")
    if not isinstance(extra, dict):
        raise ValueError(f"{path}: expected a JSON object")
    for key, val in extra.items():
        if key.startswith("_") or key == "version":
            continue
        if key == "known_prefixes":
            if not isinstance(val, list) or not all(isinstance(x, str) and x.startswith("mcp__") and x.endswith("__") for x in val):
                raise ValueError(f"{path}: known_prefixes must be a list of 'mcp__<server>__' strings")
            cfg["known_prefixes"] = list(cfg["known_prefixes"]) + [x for x in val if x not in cfg["known_prefixes"]]
            continue
        if key == "secrets":
            sub = {"": val}
        elif key in ("mcp", "bash") and isinstance(val, dict):
            sub = val
        else:
            raise ValueError(f"{path}: '{key}' can't be set by the company (only known_prefixes, mcp.deny, mcp.ask, "
                             "bash.deny, bash.ask, secrets)")
        for sk, rules in sub.items():
            if sk.startswith("_"):
                continue
            where = (key,) if key == "secrets" else (key, sk)
            if where not in COMPANY_LISTS:
                raise ValueError(f"{path}: '{'.'.join(where)}' can't be set by the company: it can only add "
                                 "rules that deny or ask, never exemptions")
            if not isinstance(rules, list):
                raise ValueError(f"{path}: '{'.'.join(where)}' must be a list of rules")
            for r in rules:
                if not isinstance(r, dict) or not r.get("id") or not r.get("pattern") or "input" in r:
                    raise ValueError(f"{path}: every rule in '{'.'.join(where)}' needs an id and a pattern (no input conditions)")
                r = dict(r, id="company:" + str(r["id"]), why=str(r.get("why") or "a company rule (.claude/limits-company.json)"))
                (cfg["secrets"] if key == "secrets" else cfg[key][sk]).append(r)
    return cfg


def load_config():
    with open(CONFIG, encoding="utf-8") as f:
        cfg = json.load(f)
    merge_company(cfg)
    # Compile now: a bad pattern must fail closed, not at match time.
    for rule in (cfg["mcp"]["deny"] + cfg["mcp"].get("create", []) + cfg["mcp"]["ask"]
                 + cfg["bash"]["deny"] + cfg["bash"]["ask"] + cfg["secrets"]):
        rule["re"] = re.compile(rule["pattern"])
        cond = rule.get("input")
        if cond is not None:
            cond["allow_re"] = re.compile(cond["allow"])
            cond["key_norm"] = re.sub(r"[^a-z0-9]", "", str(cond["key"]).lower())
            if not cond["key_norm"]:
                raise ValueError(f"rule {rule['id']}: empty input key")
    cfg["mcp"]["draft_allow_re"] = re.compile(cfg["mcp"]["draft_allow"])
    cfg["mcp"]["draft_never_re"] = re.compile(cfg["mcp"]["draft_never"])
    cfg["mcp"]["private_publish_re"] = re.compile(cfg["mcp"].get("private_publish", "(?!)"))
    return cfg


# ── limits ───────────────────────────────────────────────────────────────────
def input_matches(cond, inp):
    """True if the tool's arguments satisfy a rule's "input" condition (top-level keys only)."""
    vals = [v for k, v in (inp or {}).items() if re.sub(r"[^a-z0-9]", "", str(k).lower()).endswith(cond["key_norm"])]
    if not vals:
        return bool(cond.get("when_missing"))
    return all(isinstance(v, str) and cond["allow_re"].fullmatch(v.strip().lower()) for v in vals)


def mcp_decision(cfg, tool, inp=None):
    """(decision, rule) for an mcp__ tool; decision in {None, 'deny', 'ask'}."""
    name = tool.rsplit("__", 1)[-1].lower()
    m = cfg["mcp"]
    is_draft = bool(m["draft_allow_re"].search(name)) and not m["draft_never_re"].search(name)
    private_page = bool(m["private_publish_re"].search(tool))
    for rule in m["deny"]:
        if rule["id"] == "outbound" and (is_draft or private_page):
            continue
        if rule["re"].search(name):
            return "deny", rule
    for rule in m.get("create", []):  # creating can't lose anything (hard limit 4, three classes)
        if rule["re"].search(name) and (rule.get("input") is None or input_matches(rule["input"], inp)):
            return None, rule
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
    global LAST_EVENT
    ev = read_event()
    LAST_EVENT = ev
    tool = str(ev.get("tool_name", ""))
    inp = ev.get("tool_input") or {}
    if not isinstance(inp, dict):
        inp = {}
    try:
        cfg = load_config()
    except (OSError, ValueError, KeyError, TypeError, re.error) as e:
        deny(f"juvant-os hard limits: config unreadable ({e}). Every checked tool is blocked until it is fixed: "
             f"run `update` for {CONFIG}, or correct .claude/limits-company.json with the CEO.")

    for rule in cfg["secrets"]:
        for text in texts_to_scan(tool, inp):
            if text and rule["re"].search(text):
                deny(f"juvant-os hard limit 3: secret-shaped text ({rule['id']}) in a {tool} call. "
                     "Secrets never go in the repo, memory or chat: the CEO stores them from their own terminal.")

    who = agent_identity(ev)
    row = private_violation(tool, inp, who)
    if row:
        deny(f"juvant-os private file: this file is marked private in {PRIVATE_REGISTRY} and `{who}` isn't among "
             f"the readers ({row}). Ask the CEO, or someone listed, to pass on what you need.")
    fp_ = str(inp.get("file_path") or "")
    if tool in ("Write", "Edit", "MultiEdit") and fp_ and norm_path(fp_) == norm_path(PRIVATE_REGISTRY):
        ask(f"juvant-os: {PRIVATE_REGISTRY} decides who can read private files. The CEO confirms every change.")

    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        target = str(inp.get("file_path") or inp.get("notebook_path") or "")
        if target and norm_path(target) == norm_path(AUTH_STATE):
            deny("juvant-os: state/authorizations.json is kept by the hooks. Nobody edits it.")
        if is_authorization_path(target):
            if tool == "NotebookEdit":
                deny("juvant-os: write long-task authorizations with Write.")
            record_pending_authorization(ev, tool, inp, target)
            ask("juvant-os long task: this writes an authorization for an unattended task. Read what it allows "
                "(actions, where, how many, until when, which agents). Confirming activates it for this session only; "
                "declining leaves nothing active.")

    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit") and in_claude_dir(
            str(inp.get("file_path") or inp.get("notebook_path") or "")):
        ask("juvant-os hard limit (protect-claude-dir): this changes .claude/, where the hard limits, agents and "
            "settings live. The CEO confirms; framework files change through the update skill.")

    if tool.startswith("mcp__"):
        decision, rule = mcp_decision(cfg, tool, inp)
        if decision:
            prefix = tool[: len(tool) - len(tool.rsplit("__", 1)[-1])]
            if prefix not in cfg["known_prefixes"]:
                append_jsonl(FINDINGS, {"ts": now(), "kind": "unlisted-prefix", "prefix": prefix,
                                        "tool": tool, "decision": decision, "rule": rule["id"]})
            if decision == "ask" and use_authorization(rule, tool, inp, ev):
                return  # inside a long-task authorization the CEO approved for this session
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
        decision, why = shared_repo_check(command, str(ev.get("cwd") or ROOT))
        if decision == "deny":
            deny(f"juvant-os hard limit (shared-repo): {why}. Writing where people outside the company read "
                 "is outbound: work on a branch, open a draft PR (gh pr create --draft), and the CEO merges.")
        elif decision == "ask":
            ask(f"juvant-os hard limit (shared-repo): {why}.")
        if AUTH_STATE_REL in command and bash_may_write(command, AUTH_STATE_REL):
            deny("juvant-os: state/authorizations.json is kept by the hooks. Nobody edits it.")
        if AUTH_DIR in command and bash_may_write(command, AUTH_DIR) and not CLOSE_AUTH.match(command):
            ask(f"juvant-os long task: this command may write in {AUTH_DIR}/. Authorizations are written with Write, "
                "and the CEO confirms them; close one with `python3 .claude/hooks/juvant_hooks.py close-authorization <file>`.")
        if PRIVATE_REGISTRY in command and bash_may_write(command, PRIVATE_REGISTRY):
            ask(f"juvant-os: {PRIVATE_REGISTRY} decides who can read private files. The CEO confirms every change.")
        why = framework_upstream_publish(command, str(ev.get("cwd") or ROOT))
        if why:
            ask(f"juvant-os hard limit 1 (outbound): {why}. The public juvant-os repository is read by everyone: "
                "the CEO checks the diff and the text first (bugfix skill).")
        if bash_writes_claude_dir(command, str(ev.get("cwd") or ROOT)):
            ask("juvant-os hard limit (protect-claude-dir): this command may change .claude/, where the hard limits, "
                "agents and settings live. The CEO confirms; framework files change through the update skill.")
        if cfg["bash"].get("rm_outside_repo") == "ask" and rm_outside_repo(cfg, command):
            ask("juvant-os hard limit (rm-outside-repo): recursive delete outside the company repo (hard limit 4).")


# ── .claude/ protection (the hard limits must not edit themselves) ───────────
READ_ONLY_VERBS = {"cat", "less", "head", "tail", "ls", "grep", "rg", "wc", "diff", "file", "stat", "sha256sum", "shasum"}
GIT_READ = {"diff", "log", "show", "status", "ls-files", "blame", "add", "commit"}
# Framework scripts that never write under .claude/: the dashboard writes
# state/dashboard.html (hourly scheduled task), bugfix works in a temp clone.
OUTSIDE_WRITERS = (".claude/dashboard/build.py", ".claude/skills/bugfix/bugfix.py")
SANCTIONED = re.compile(r"^(bash|sh)\s+(\./)?\.claude/skills/update/update\.sh(\s|$)")


FRAMEWORK_MARKERS = ("juvant-os.json", "juvant-os-project.json")


def in_claude_dir(path):
    """True for this repo's .claude/, and for the .claude/ of any repo juvant-os is
    installed in (a project repo next door): its hooks and sharing record too."""
    if not path:
        return False
    full = os.path.realpath(path if os.path.isabs(path) else os.path.join(ROOT, path))
    base = os.path.realpath(os.path.join(ROOT, ".claude"))
    if full == base or full.startswith(base + os.sep):
        return True
    d = os.path.dirname(full)
    while d and d != os.path.dirname(d):
        if os.path.basename(d) == ".claude":
            return any(os.path.exists(os.path.join(d, m)) for m in FRAMEWORK_MARKERS)
        d = os.path.dirname(d)
    return False


# Claude Code's own working areas under ~/.claude (job scratch folders and the
# like): agents download and process files there. The rest of ~/.claude, user
# settings included, stays protected.
CLAUDE_HOME_SCRATCH = ("jobs", "shell-snapshots", "todos", "tmp", "paste-cache", "file-history", "statsig")


def protected_claude_path(word, here):
    """True if this word names a path in a .claude that the hard limits protect: this
    repo's, one where juvant-os is installed, or the user's ~/.claude (not its scratch areas)."""
    if ".claude" not in word:
        return False
    w = word
    if "=" in w and not w.startswith(("/", ".", "~")):
        w = w.split("=", 1)[1]  # --out=.claude/x
    w = re.sub(r"^\d*>>?\|?", "", w)  # 2>.claude/x
    if not w or "$" in w or "`" in w:
        return ".claude" in w  # can't resolve it: assume the worst
    # The path may sit inside a bigger word: python3 -c 'open(".claude/x", "w")'.
    candidates = re.findall(r"~?[\w./@+-]*\.claude(?:/[\w./@+-]*)?", w) or [w]
    home = os.path.realpath(os.path.expanduser("~/.claude"))
    for c in candidates:
        c = os.path.expanduser(c)
        full = os.path.realpath(c if os.path.isabs(c) else os.path.join(here or ROOT, c))
        if in_claude_dir(full):
            return True
        if (full == home or full.startswith(home + os.sep)) and \
                os.path.relpath(full, home).split(os.sep)[0] not in CLAUDE_HOME_SCRATCH:
            return True
    return False


def bash_writes_claude_dir(command, cwd=None):
    """True if a Bash command may write under a protected .claude/ outside the sanctioned
    update script. Follows `cd`: a relative write after moving into .claude/ counts."""
    if ".claude" not in command and not (cwd and protected_claude_path(os.path.join(cwd, "."), "/")):
        return False
    segments = shell_segments(command)
    if segments is None:
        return True
    here = cwd or ROOT
    for words in segments:
        seg = " ".join(words)
        core = list(words)
        while core and "=" in core[0] and not core[0].startswith(("-", "/", ".")):
            core = core[1:]
        if not core:
            continue
        verb = os.path.basename(core[0])
        if verb in ("cd", "pushd"):
            target = core[1] if len(core) > 1 else "~"
            if "$" in target or "`" in target or target == "-":
                if ".claude" in target:
                    return True  # moving somewhere we can't resolve, towards a .claude
                here = None
            else:
                here = os.path.normpath(os.path.join(here or ROOT, os.path.expanduser(target)))
            continue
        inside = bool(here) and protected_claude_path(os.path.join(here, "."), "/")
        if not inside and not any(protected_claude_path(w, here) for w in words if ".claude" in w):
            continue
        if SANCTIONED.match(seg) and not re.search(r"--(from|repo|target)\b", seg):
            continue  # update from a published tag only; a local source could carry anything
        for i, w in enumerate(words[:-1]):
            if w in (">", ">>", ">|") and protected_claude_path(words[i + 1], here):
                return True
        if any(re.match(r"^\d*>>?", w) and protected_claude_path(w, here) for w in words):
            return True
        if verb in READ_ONLY_VERBS:
            continue
        if verb == "git" and len(core) > 1 and core[1] in GIT_READ:
            continue
        if verb == "find" and not any(w in ("-delete", "-exec", "-execdir", "-ok") for w in core):
            continue
        if verb in ("python3", "python") and len(core) > 1 and core[1].endswith(".claude/hooks/juvant_hooks.py"):
            continue
        if (verb in ("python3", "python") and len(core) > 1 and core[1].endswith(OUTSIDE_WRITERS)
                and not any(protected_claude_path(w, here) for w in core[2:])):
            continue  # framework scripts that write outside .claude/ (they must run unattended)
        return True
    return False


# ── private files (memory/private.md) ───────────────────────────────────────
PRIVATE_REGISTRY = os.path.join("memory", "private.md")
SESSION_AGENTS = os.path.join(STATE, "session-agents.json")


def private_entries():
    """[(match, allowed set, raw)] from memory/private.md; [] if missing."""
    text = read_text(PRIVATE_REGISTRY) or ""
    out = []
    for line in text.splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 2 or not cells[0] or set(cells[0]) <= set("-: ") or cells[0].lower() in ("file", "path"):
            continue
        match = cells[0].strip("`").strip()
        allowed = {a.strip().lower() for a in re.split(r"[,;\s]+", cells[1]) if a.strip()}
        out.append((match, allowed, line.strip()))
    return out


def agent_identity(ev):
    """Subagent type; else the type the session started as; else cos (main session)."""
    a = str(ev.get("agent_type") or "")
    if a:
        return a.lower()
    try:
        with open(SESSION_AGENTS, encoding="utf-8") as f:
            a = str(json.load(f).get(str(ev.get("session_id", "")), ""))
    except (OSError, ValueError, AttributeError):
        a = ""
    return (a or "cos").lower()


def norm_path(p):
    p = os.path.expanduser(str(p))
    return os.path.realpath(p if os.path.isabs(p) else os.path.join(ROOT, p))


def private_violation(tool, inp, who):
    """The registry row that this call would break, or None."""
    entries = private_entries()
    if not entries:
        return None
    blob = json.dumps(inp, ensure_ascii=False)
    for match, allowed, raw in entries:
        if who in allowed:
            continue
        is_url = "://" in match or not ("/" in match or "." in os.path.basename(match))
        if is_url:
            if match in blob:
                return raw
            continue
        target = norm_path(match)
        if tool in ("Read", "Edit", "MultiEdit", "Write", "NotebookEdit"):
            fp = inp.get("file_path") or inp.get("notebook_path") or ""
            if fp and norm_path(fp) == target:
                return raw
        elif tool in ("Grep", "Glob"):
            p = inp.get("path") or ""
            if p and norm_path(p) == target:
                return raw
        elif tool == "Bash":
            cmd = str(inp.get("command", ""))
            rel = os.path.relpath(target, os.path.realpath(ROOT))
            if match in cmd or target in cmd or (not rel.startswith("..") and rel in cmd):
                return raw
        elif tool.startswith("mcp__") and match in blob:
            return raw
    return None


# ── long-task authorizations (memory/authorizations/) ────────────────────────
# A long task runs unattended under an authorization the CEO approved when it
# started. Writing one asks the CEO; at that moment the hook records the session
# and a hash of the content about to be written. An authorization counts only
# while the file still has that exact content, for that session (and the
# subagents it names), before it expires, within its scope and its maximum, and
# only for actions that would otherwise ask. Denies are never affected.
AUTH_DIR = "memory/authorizations"
AUTH_STATE_REL = "state/authorizations.json"
AUTH_STATE = os.path.join(ROOT, AUTH_STATE_REL)
AUTH_DEFAULT_HOURS = 12
AUTH_MAX_HOURS = 24
CLOSE_AUTH = re.compile(r"^\s*python3?\s+(\./)?\.claude/hooks/juvant_hooks\.py\s+close-authorization\s+[^;&|<>`$()]+$")


def bash_may_write(command, needle):
    """True if some part of a Bash command that names `needle` may write to it: a redirect
    into it, or a command other than a known read (cat, grep, git diff…). A read piped into
    something else (cat x | python3 -m json.tool) is a read. Unparseable: assume it writes."""
    segments = shell_segments(command)
    if segments is None:
        return True
    for words in segments:
        if not any(needle in w for w in words):
            continue
        for i, w in enumerate(words):
            if w in (">", ">>", ">|") and i + 1 < len(words) and needle in words[i + 1]:
                return True
            if re.match(r"^\d*>>?\|?\S", w) and needle in w:
                return True
        core = list(words)
        while core and "=" in core[0] and not core[0].startswith(("-", "/", ".")):
            core = core[1:]
        if not core:
            continue
        verb = os.path.basename(core[0])
        if verb in READ_ONLY_VERBS or verb == "jq":
            continue
        if verb == "git" and len(core) > 1 and core[1] in GIT_READ:
            continue
        if verb == "find" and not any(w in ("-delete", "-exec", "-execdir", "-ok") for w in core):
            continue
        return True
    return False


def is_authorization_path(p):
    if not p:
        return False
    full, base = norm_path(p), norm_path(AUTH_DIR)
    return full.startswith(base + os.sep) and full.endswith(".md")


def read_raw(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def sha256(text):
    import hashlib
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def content_after(tool, inp, path):
    """The file's content once this Write/Edit/MultiEdit runs; None if it can't be worked out."""
    if tool == "Write":
        return str(inp.get("content", ""))
    text = read_raw(path)
    if text is None:
        return None
    edits = [inp] if tool == "Edit" else [e for e in inp.get("edits", []) if isinstance(e, dict)]
    for e in edits:
        old, new = str(e.get("old_string", "")), str(e.get("new_string", ""))
        if not old or old not in text:
            return None
        text = text.replace(old, new) if e.get("replace_all") else text.replace(old, new, 1)
    return text


def load_auth_state():
    try:
        with open(AUTH_STATE, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_auth_state(d):
    os.makedirs(os.path.dirname(AUTH_STATE), exist_ok=True)
    tmp = AUTH_STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=1)
    os.replace(tmp, AUTH_STATE)


def auth_key(path):
    return os.path.relpath(norm_path(path), os.path.realpath(ROOT))


def record_pending_authorization(ev, tool, inp, path):
    content = content_after(tool, inp, norm_path(path))
    if content is None:
        return  # nothing recorded: whatever gets written won't count
    st = load_auth_state()
    st[auth_key(path)] = {"session": str(ev.get("session_id", "")), "hash": sha256(content),
                          "recorded": time.time(), "used": 0}
    try:
        save_auth_state(st)
    except OSError:
        pass


def split_list(s):
    return [x.strip() for x in re.split(r"[,\s]+", str(s or "")) if x.strip()]


def parse_ts(s):
    """Epoch seconds from an ISO timestamp (Z or offset; no offset = UTC); None if unparseable."""
    import datetime as dt
    try:
        t = dt.datetime.fromisoformat(str(s).strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if t.tzinfo is None:
        t = t.replace(tzinfo=dt.timezone.utc)
    return t.timestamp()


def scope_matches(fm, inp):
    """Every scope_<key> in the authorization must be among the tool's arguments with an allowed
    value. Keys compare without case or punctuation (driveId = drive_id), exactly: `parent_id` is
    not `target_parent_id`. `scope_a|b: X` names one thing that tools call differently (the folder
    is `parent_item_id` for an upload, `expected_parent_id` for a delete): one of them must be given."""
    scopes = {k[len("scope_"):]: split_list(v.replace(",", " ")) for k, v in fm.items() if k.startswith("scope_")}
    if not scopes:
        return False  # an authorization says where, or it covers nothing
    norm = lambda x: re.sub(r"[^a-z0-9]", "", str(x).lower())  # noqa: E731
    for key, allowed in scopes.items():
        names = {norm(n) for n in key.split("|") if norm(n)}
        vals = [v for k, v in inp.items() if norm(k) in names]
        if not names or not vals or not all(isinstance(v, str) and v.strip() in allowed for v in vals):
            return False
    return True


def use_authorization(rule, tool, inp, ev):
    """The authorization file that covers this would-be `ask`, counted and logged; None if none does."""
    session = str(ev.get("session_id", ""))
    if not session:
        return None
    st = load_auth_state()
    if not st:
        return None
    sub = str(ev.get("agent_type") or "").lower()
    try:
        with open(SESSION_AGENTS, encoding="utf-8") as f:
            own = str(json.load(f).get(session, "")).lower()
    except (OSError, ValueError, AttributeError):
        own = ""
    if sub == own:
        sub = ""  # the session's own main agent, not a subagent
    name = tool.rsplit("__", 1)[-1].lower()
    t = time.time()
    for key, rec in st.items():
        if not isinstance(rec, dict) or rec.get("session") != session or rec.get("closed"):
            continue
        raw = read_raw(os.path.join(ROOT, key))
        if raw is None or sha256(raw) != rec.get("hash"):
            continue
        fm = frontmatter(raw)
        if fm.get("status", "").lower() != "active" or rule["id"] not in split_list(fm.get("actions")):
            continue
        recorded = float(rec.get("recorded") or 0)
        expires = parse_ts(fm["expires"]) if fm.get("expires") else recorded + AUTH_DEFAULT_HOURS * 3600
        if expires is None or t > min(expires, recorded + AUTH_MAX_HOURS * 3600):
            continue
        if fm.get("tools"):
            try:
                if not re.search(fm["tools"], name):
                    continue
            except re.error:
                continue
        if sub and sub not in [a.lower() for a in split_list(fm.get("agents"))]:
            continue
        if not scope_matches(fm, inp):
            continue
        try:
            cap = int(fm.get("max", "0"))
        except ValueError:
            continue
        if int(rec.get("used", 0)) >= cap:
            continue
        rec["used"] = int(rec.get("used", 0)) + 1
        try:
            save_auth_state(st)
        except OSError:
            return None  # can't count it: don't allow it
        activity("authorized", ev, tool=tool, rule=rule["id"], authorization=key, count=rec["used"])
        return key
    return None


def cmd_close_authorization():
    args = sys.argv[2:]
    if not args or not is_authorization_path(args[0]):
        sys.stderr.write(f"usage: juvant_hooks.py close-authorization {AUTH_DIR}/<file>.md [reason]\n")
        sys.exit(2)
    path = norm_path(args[0])
    raw = read_raw(path)
    if raw is None:
        sys.stderr.write(f"close-authorization: {args[0]} not found\n")
        sys.exit(1)
    st = load_auth_state()
    rec = st.get(auth_key(path))
    if isinstance(rec, dict):
        rec["closed"] = time.time()
        save_auth_state(st)
    if re.search(r"^status:.*$", raw, re.M):
        raw = re.sub(r"^status:.*$", "status: closed", raw, count=1, flags=re.M)
    elif raw.startswith("---\n"):
        raw = "---\nstatus: closed\n" + raw[4:]
    reason = one_line(" ".join(args[1:]), 200)
    raw = raw.rstrip("\n") + f"\n\nClosed {now()}" + (f": {reason}" if reason else "") + ".\n"
    with open(path, "w", encoding="utf-8") as f:
        f.write(raw)
    activity("authorization_closed", {}, authorization=auth_key(path), reason=reason)
    print(f"closed {auth_key(path)}")


# ── repositories shared outside the company ──────────────────────────────────
def repo_root(path):
    """The git checkout containing path (nearest .git upwards), or None."""
    p = os.path.abspath(path or ROOT)
    while True:
        if os.path.exists(os.path.join(p, ".git")):
            return p
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent


def shared_with(root=None):
    """Who outside the company reads the checkout at root (its .claude/juvant-os-project.json); "" if internal."""
    try:
        with open(os.path.join(root or ROOT, ".claude", "juvant-os-project.json"), encoding="utf-8") as f:
            return str(json.load(f).get("shared_with") or "").strip()
    except (OSError, ValueError, AttributeError):
        return ""


def current_branch(root=None):
    try:
        out = subprocess.run(["git", "-C", root or ROOT, "symbolic-ref", "--short", "-q", "HEAD"],
                             capture_output=True, text=True, timeout=5)
        return out.stdout.strip()
    except Exception:  # noqa: BLE001
        return ""


DEFAULT_BRANCHES = {"main", "master", "trunk", "develop"}


def default_branches(root):
    names = set(DEFAULT_BRANCHES)
    try:
        out = subprocess.run(["git", "-C", root, "symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        if out:
            names.add(out.split("/", 1)[-1])
    except Exception:  # noqa: BLE001
        pass
    return names


def git_subcommand(words, here):
    """(index of git's subcommand, directory it acts on), parsing git's global options."""
    i = 1
    while i < len(words) and words[i].startswith("-"):
        w = words[i]
        if w == "-C" and i + 1 < len(words):
            here = os.path.normpath(os.path.join(here, os.path.expanduser(words[i + 1])))
            i += 2
        elif w in ("--git-dir", "--work-tree") and i + 1 < len(words):
            here = os.path.normpath(os.path.join(here, os.path.expanduser(words[i + 1])))
            i += 2
        elif w.startswith(("--git-dir=", "--work-tree=")):
            here = os.path.normpath(os.path.join(here, os.path.expanduser(w.split("=", 1)[1])))
            i += 1
        elif w in ("-c", "--namespace", "--config-env") and i + 1 < len(words):
            i += 2
        else:
            i += 1
    return i, here


def gh_repo_arg(words):
    for i, w in enumerate(words):
        if w in ("-R", "--repo") and i + 1 < len(words):
            return words[i + 1]
        if w.startswith("--repo="):
            return w.split("=", 1)[1]
    return ""


def origin_matches(root, named):
    """True if the checkout's origin is the GitHub repo named owner/repo (or a URL to it)."""
    try:
        url = subprocess.run(["git", "-C", root, "remote", "get-url", "origin"], capture_output=True,
                             text=True, timeout=5).stdout.strip()
    except Exception:  # noqa: BLE001
        return False
    norm = lambda u: re.sub(r"(\.git)?/?$", "", re.sub(r"^.*github\.com[/:]", "", u.strip())).lower()  # noqa: E731
    return bool(url) and norm(url) == norm(named)


def shared_repo_check(command, cwd):
    """(decision, reason) for a command that publishes to a shared repository's default
    branch, merges a PR there, or opens a non-draft PR there; (None, None) otherwise.
    Each segment is resolved to the checkout it acts on: the event's cwd, a preceding
    `cd`, `git -C` / `--git-dir` / `--work-tree`, or a `gh -R` that matches that checkout."""
    if "git" not in command and "gh" not in command:
        return None, None
    segments = shell_segments(command)
    if segments is None:
        return None, None
    here = cwd or ROOT
    for words in segments:
        if not words:
            continue
        verb = os.path.basename(words[0])
        if verb == "cd" and len(words) > 1:
            here = os.path.normpath(os.path.join(here, os.path.expanduser(words[1])))
            continue
        if verb == "git":
            i, target = git_subcommand(words, here)
            if i >= len(words) or words[i] != "push":
                continue
            root = repo_root(target)
            who = shared_with(root) if root else ""
            if not who:
                continue
            args = words[i + 1:]
            if any(a in ("--all", "--mirror") for a in args):
                return "deny", f"pushing every branch of a repository shared with {who}"
            dests = [a.split(":")[-1].replace("refs/heads/", "").lstrip("+") for a in [a for a in args if not a.startswith("-")][1:]]
            defaults, branch = default_branches(root), current_branch(root)
            if any(d in defaults or (d == "HEAD" and branch in defaults) for d in dests):
                return "deny", f"pushing to the default branch of a repository shared with {who}"
            if not dests and branch in defaults:
                return "deny", f"pushing the default branch of a repository shared with {who}"
        elif verb == "gh" and len(words) >= 3 and words[1] == "pr" and words[2] in ("merge", "create"):
            named = gh_repo_arg(words)
            root = repo_root(here)
            if named and not (root and origin_matches(root, named)):
                if words[2] == "merge" or ("--draft" not in words and "-d" not in words):
                    return "ask", (f"`gh pr {words[2]}` on {named}, which isn't checked out here, so whether people "
                                   "outside the company read it can't be checked. The CEO confirms")
                continue
            who = shared_with(root) if root else ""
            if not who:
                continue
            if words[2] == "merge":
                return "deny", f"merging a pull request in a repository shared with {who}"
            if "--draft" not in words and "-d" not in words:
                return "deny", f"opening a non-draft pull request in a repository shared with {who}"
    return None, None


UPSTREAM_RE = re.compile(r"(github\.com[/:]|^|\s)[\w.-]+/juvant-os(\.git)?/?(\s|$)")


def repo_is_juvant_os(path):
    """True if the git checkout at path has a remote named after juvant-os (upstream or a fork)."""
    try:
        out = subprocess.run(["git", "-C", path, "remote", "-v"], capture_output=True, text=True, timeout=5).stdout
    except Exception:  # noqa: BLE001
        return False
    return any(UPSTREAM_RE.search(line.split("\t", 1)[-1].split(" ")[0]) for line in out.splitlines() if "\t" in line)


def framework_upstream_publish(command, cwd):
    """Reason string if the command publishes to the juvant-os repository (PR, issue, push,
    fork, security report); else None. Follows `cd` inside the command."""
    if "gh" not in command and "git" not in command:
        return None
    segments = shell_segments(command)
    if segments is None:
        return None
    here = cwd
    for words in segments:
        if not words:
            continue
        verb = os.path.basename(words[0])
        if verb == "cd" and len(words) > 1:
            here = os.path.normpath(os.path.join(here, os.path.expanduser(words[1])))
            continue
        if verb == "git" and len(words) > 1 and "-C" in words[:-1]:
            here = os.path.normpath(os.path.join(here, os.path.expanduser(words[words.index("-C") + 1])))
        action = None
        if verb == "gh" and len(words) >= 3 and (words[1], words[2]) in (("pr", "create"), ("issue", "create"), ("repo", "fork"), ("release", "create")):
            action = f"gh {words[1]} {words[2]}"
        elif verb == "gh" and len(words) >= 2 and words[1] == "api" and any("security-advisories" in w for w in words):
            action = "a security report"
        elif verb == "git" and "push" in words[1:4]:
            action = "git push"
        if not action:
            continue
        named = [w for i, w in enumerate(words) if i and words[i - 1] in ("-R", "--repo")]
        if any(re.search(r"(^|/)juvant-os$", n) for n in named) or any("/juvant-os/" in w for w in words if "repos/" in w):
            return f"{action} to the juvant-os repository"
        if not named and repo_is_juvant_os(here):
            return f"{action} from a juvant-os checkout"
    return None


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


def waiting_for_ceo():
    """(day, ["- Waiting for the CEO: …"]) from the latest journal's last session section
    (each wrap-up writes the current list, so earlier ones are stale); (None, []) if none."""
    jdir = os.path.join(ROOT, "memory", "journal")
    try:
        days = sorted((n for n in os.listdir(jdir) if re.match(r"\d{4}-\d{2}-\d{2}\.md$", n)), reverse=True)
    except OSError:
        return None, []
    if not days:
        return None, []
    text = read_text(os.path.join("memory", "journal", days[0])) or ""
    found = [l.strip() for l in text.splitlines() if re.match(r"^\s*-\s*Waiting for the CEO", l, re.I)]
    return days[0], found[-1:]


WAITING_SHOW_CAP = 1200


def waiting_banner():
    """What the CEO sees on screen at session start: the agent can't speak first."""
    day, waiting = waiting_for_ceo()
    items = [re.sub(r"^\s*-\s*Waiting for the CEO\s*:?\s*", "", l, flags=re.I) for l in waiting]
    items = [i for i in items if i and not re.match(r"^(see|nothing|none)\b", i, re.I)]
    if not items:
        return ""
    text = f"Waiting for you (memory/journal/{day}):\n" + "\n".join("• " + i for i in items)
    if len(text) > WAITING_SHOW_CAP:
        text = text[:WAITING_SHOW_CAP].rsplit(" ", 1)[0] + " …"
    return text + "\nAsk the Chief of Staff to go through them."


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
    day, waiting = waiting_for_ceo()
    if waiting:
        parts.append(f"## Waiting for the CEO (memory/journal/{day})\n\n" + "\n".join(waiting))
    if not parts:
        return ""
    text = "# Company memory digest\n\nFrom the files in memory/. Search memory/ for anything else; if a fact isn't there, say it isn't recorded.\n\n" + "\n\n".join(parts)
    return text if len(text) <= DIGEST_CAP else text[:DIGEST_CAP] + "\n[…truncated]"


SHARING_CACHE_HOURS = 24


def github_sharing_note():
    """Warn when GitHub shows outside collaborators on a repo not marked shared,
    or on the company repo. Cached for a day; silent when gh or the repo is unavailable."""
    cache = os.path.join(STATE, "sharing-check.json")
    try:
        with open(cache, encoding="utf-8") as f:
            c = json.load(f)
        if time.time() - float(c.get("checked", 0)) < SHARING_CACHE_HOURS * 3600:
            return c.get("note", "")
    except (OSError, ValueError, TypeError):
        pass
    note = ""
    try:
        import subprocess
        url = subprocess.run(["git", "-C", ROOT, "remote", "get-url", "origin"], capture_output=True,
                             text=True, timeout=5).stdout.strip()
        m = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$", url)
        if m:
            gh = os.environ.get("JUVANT_GH", "gh")
            r = subprocess.run([gh, "api", f"repos/{m.group(1)}/{m.group(2)}/collaborators?affiliation=outside",
                                "--jq", "length"], capture_output=True, text=True, timeout=8)
            n = int(r.stdout.strip()) if r.returncode == 0 and r.stdout.strip().isdigit() else 0
            project = os.path.exists(os.path.join(ROOT, ".claude", "juvant-os-project.json"))
            if n and not project:
                note = (f"Tell the CEO: GitHub shows {n} outside collaborator(s) on the company repo "
                        f"{m.group(1)}/{m.group(2)}. Company memory is for the company only: check who has access.")
            elif n and not shared_with():
                note = (f"Tell the CEO: GitHub shows {n} outside collaborator(s) on {m.group(1)}/{m.group(2)}, "
                        "but this repository isn't marked as shared. If they read it, mark it with the "
                        "project-repo skill (sharing) from the company repo.")
    except Exception:  # noqa: BLE001 — a warning only, never in the way
        note = ""
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(cache, "w", encoding="utf-8") as f:
            json.dump({"checked": time.time(), "note": note}, f)
    except OSError:
        pass
    return note


def cmd_session_start():
    ev = read_event()
    activity("session_start", ev, source=ev.get("source", ""))
    lines = []
    agent = str(ev.get("agent_type", ""))
    if ev.get("session_id"):
        try:
            os.makedirs(STATE, exist_ok=True)
            try:
                with open(SESSION_AGENTS, encoding="utf-8") as f:
                    known = json.load(f)
            except (OSError, ValueError):
                known = {}
            known[str(ev["session_id"])] = agent
            if len(known) > 500:
                known = dict(list(known.items())[-500:])
            with open(SESSION_AGENTS, "w", encoding="utf-8") as f:
                json.dump(known, f)
        except OSError:
            pass
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
        lines.append(f"Lines starting with '{NOTE_PREFIX}' next to tool results come from this company's own "
                     "juvant-os hooks, not from the tool or its data: treat them as part of your instructions.")
        lines.append("juvant-os hard limits active: outbound draft-only, no payments or invoice issuing, "
                     "no secrets in files or commands; overwriting, deleting or moving asks the CEO (creating doesn't).")
    except (OSError, ValueError, KeyError, TypeError, re.error) as e:
        lines.append(f"WARNING: juvant-os hard limits config is unreadable ({e}). Checked tools are blocked. "
                     "Tell the CEO first thing: `update` restores the framework file; a mistake in "
                     ".claude/limits-company.json is fixed there, with the CEO.")
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
    try:  # a prefix added to known_prefixes since it was logged no longer needs the CEO
        prefixes -= set(load_config()["known_prefixes"])
    except (OSError, ValueError, KeyError, TypeError, re.error):
        pass
    sharing = github_sharing_note()
    if sharing:
        lines.append(sharing)
    if not ROLE_ID.match(agent):
        digest = memory_digest()
        if digest:
            lines.append(digest)
    if prefixes:
        lines.append("Tell the CEO: limited tools were called under MCP prefixes the permission rules don't list ("
                     + ", ".join(sorted(prefixes)) + "). The hook still applied the hard limits by tool name. If the "
                     "server is the company's own, add its prefix to `known_prefixes` in .claude/limits-company.json, and "
                     "its outbound tools to the permission denies in .claude/settings.json (both ask the CEO).")
    reg = registration_warning()
    if reg:
        lines.append(reg + " Tell the CEO first thing.")
    out = {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "\n".join(lines)}}
    if reg:
        out["systemMessage"] = reg
    if not ROLE_ID.match(agent) and ev.get("source") in ("startup", "resume", "clear", None):
        banner = waiting_banner()
        if banner:
            out["systemMessage"] = (reg + "\n\n" + banner) if reg else banner
            lines.append("The CEO already sees the 'Waiting for the CEO' list on screen. When they first write, "
                         "start from it: what's still open, and what you recommend doing first.")
            out["hookSpecificOutput"]["additionalContext"] = "\n".join(lines)
    emit(out)


def cmd_subagent_stop():
    ev = read_event()
    # Claude Code's own helper subagents (reply suggestions, summaries) have no agent_type:
    # their last message is not an outcome of the company's work.
    outcome = one_line(ev.get("last_assistant_message", ""), OUTCOME_CAP) if ev.get("agent_type") else ""
    activity("subagent_stop", ev, outcome=outcome)


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


# ── reviewer nudges (FEAT-088) ───────────────────────────────────────────────
NUDGES = os.path.join(HERE, "nudges.json")
NUDGE_STATE = os.path.join(STATE, "nudges.json")
NOTE_PREFIX = "juvant-os hook note:"
LAST_EVENT = {}


def nudge_note(ev):
    """The note for this (allowed) call, or "": first domain call in a session, and once more after repeat_after."""
    tool = str(ev.get("tool_name", ""))
    session = str(ev.get("session_id", ""))
    if not session or ev.get("agent_type"):
        return ""  # subagents are the reviewers, or have their own brief
    try:
        with open(NUDGES, encoding="utf-8") as f:
            cfg = json.load(f)
        domains = cfg["domains"]
        repeat = int(cfg.get("repeat_after", 8))
    except (OSError, ValueError, KeyError, TypeError):
        return ""
    inp = ev.get("tool_input") if isinstance(ev.get("tool_input"), dict) else {}
    skill = str(inp.get("skill") or inp.get("command") or inp.get("name") or "").strip().lstrip("/").lower() if tool == "Skill" else ""
    skill = skill.rsplit(":", 1)[-1]
    domain = None
    for d, spec in domains.items():
        try:
            if tool.startswith("mcp__") and spec.get("tools") and re.search(spec["tools"], tool.lower()):
                domain = d
            elif skill and spec.get("skills") and re.search(spec["skills"], skill):
                domain = d
        except (re.error, TypeError):
            continue
        if domain:
            break
    if not domain:
        return ""
    try:
        with open(SESSION_AGENTS, encoding="utf-8") as f:
            own = str(json.load(f).get(session, "")).lower()
    except (OSError, ValueError, AttributeError):
        own = ""
    if own == domain:
        return ""  # this session runs as that role
    try:
        with open(NUDGE_STATE, encoding="utf-8") as f:
            st = json.load(f)
        if not isinstance(st, dict):
            st = {}
    except (OSError, ValueError):
        st = {}
    counts = st.setdefault(session, {})
    counts[domain] = int(counts.get(domain, 0)) + 1
    if len(st) > 200:
        st = dict(list(st.items())[-200:])
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(NUDGE_STATE, "w", encoding="utf-8") as f:
            json.dump(st, f)
    except OSError:
        return ""
    n = counts[domain]
    spec = domains[domain]
    if n == 1:
        return f"{NOTE_PREFIX} {spec.get('note', '')}".strip()
    if n == repeat and spec.get("again"):
        return f"{NOTE_PREFIX} {spec['again']}"
    return ""


def nudge_after_limits():
    """Called only when the limits check let the call through. Never blocks, never fails a call."""
    try:
        note = nudge_note(LAST_EVENT)
    except Exception:  # noqa: BLE001
        return
    if note:
        emit({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": note}})
        activity("nudge", LAST_EVENT, note=note[:80], tool=str(LAST_EVENT.get("tool_name", "")))


# ── hook registration in .claude/settings.json ──────────────────────────────
def matcher_covers(matcher, tool):
    """Claude Code's matcher rule: empty or "*" matches every tool, otherwise a regex
    matched against the whole tool name."""
    m = str(matcher or "").strip()
    if m in ("", "*"):
        return True
    try:
        return re.fullmatch(m, tool) is not None
    except re.error:
        return False


def limits_entries(settings):
    """The PreToolUse entries that run `juvant_hooks.py ... limits`."""
    pre = ((settings.get("hooks") or {}).get("PreToolUse") or []) if isinstance(settings, dict) else []
    return [e for e in pre if isinstance(e, dict) and any(
        isinstance(h, dict) and "juvant_hooks.py" in str(h.get("command", ""))
        and re.search(r"\slimits\s*$", str(h.get("command", ""))) for h in (e.get("hooks") or []))]


def registration_gaps(settings):
    """Checked tools (and "mcp__*") that no `limits` entry's matcher covers."""
    entries = limits_entries(settings)
    probes = list(LIMITS_TOOLS) + [MCP_PROBE]
    gaps = [t for t in probes if not any(matcher_covers(e.get("matcher"), t) for e in entries)]
    return ["mcp__*" if t == MCP_PROBE else t for t in gaps]


def load_settings():
    with open(SETTINGS, encoding="utf-8") as f:
        return json.load(f)


def registration_warning():
    """A line for the CEO if the limits hook doesn't see every checked tool; "" otherwise."""
    try:
        gaps = registration_gaps(load_settings())
    except (OSError, ValueError):
        return ""
    if not gaps:
        return ""
    return ("WARNING: juvant-os hard limits aren't checked on " + ", ".join(gaps) + ": .claude/settings.json "
            "doesn't register the limits hook for them. Fix: run `bash .claude/skills/update/update.sh` (it repairs "
            "the registration even when nothing is new), or from the company repo "
            "`CLAUDE_PROJECT_DIR=$PWD python3 .claude/hooks/juvant_hooks.py fix-registration`; then commit and start a new session.")


def cmd_fix_registration():
    try:
        settings = load_settings()
    except FileNotFoundError:
        print("fix-registration: no .claude/settings.json, nothing to fix")
        return
    except (OSError, ValueError) as e:
        sys.stderr.write(f"fix-registration: .claude/settings.json is unreadable ({e}); fix it by hand\n")
        sys.exit(1)
    gaps = registration_gaps(settings)
    if not gaps:
        return
    entries = limits_entries(settings)
    if not entries:
        # Removing the hook is the company's own (out-of-spec) choice: say so loudly, don't rewrite it.
        sys.stderr.write("fix-registration: WARNING: .claude/settings.json doesn't register the hard-limits hook at "
                         f"all, so no hard limit is checked. The template registers `{LIMITS_COMMAND}` under "
                         "PreToolUse: restore it with the CEO.\n")
        return
    names = [("mcp__.*" if g == "mcp__*" else g) for g in gaps]
    e = entries[0]
    old = str(e.get("matcher") or "").strip()
    e["matcher"] = "|".join([old] + names) if old else "|".join(names)
    with open(SETTINGS, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("fix-registration: the hard-limits hook in .claude/settings.json now also checks " + ", ".join(gaps))


COMMANDS = {
    "close-authorization": cmd_close_authorization,
    "fix-registration": cmd_fix_registration,
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
        if name == "limits":
            nudge_after_limits()
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001 — a crash in limits must block, elsewhere it must not
        if name == "limits":
            deny(f"juvant-os hard limits: the check failed ({type(e).__name__}: {e}). Blocked to stay safe.")
        sys.stderr.write(f"juvant_hooks {name}: {type(e).__name__}: {e}\n")
        sys.exit(0)
