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
import fnmatch
import glob
import hashlib
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "limits.json")
ROOT = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
STATE = os.path.join(ROOT, "state")
ACTIVITY = os.path.join(STATE, "activity.jsonl")
FINDINGS = os.path.join(STATE, "limits-findings.jsonl")
CONTEXT_CAP = 9500
OUTCOME_CAP = 160
CHECK_SECONDS = 25
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
    return merge_extra(cfg, extra, path, COMPANY_LISTS, "company:")


def merge_extra(cfg, extra, path, lists, prefix, check_rules=None):
    """Append a company's or an extension's rules to cfg. `lists` is what it may add to."""
    company = prefix == "company:"
    who = "the company" if company else "an extension"
    if not isinstance(extra, dict):
        raise ValueError(f"{path}: expected a JSON object")
    added = []
    for key, val in extra.items():
        if key.startswith("_") or key == "version":
            continue
        if key == "known_prefixes" and (key,) in lists:
            if not isinstance(val, list) or not all(isinstance(x, str) and x.startswith("mcp__") and x.endswith("__") for x in val):
                raise ValueError(f"{path}: known_prefixes must be a list of 'mcp__<server>__' strings")
            cfg["known_prefixes"] = list(cfg["known_prefixes"]) + [x for x in val if x not in cfg["known_prefixes"]]
            continue
        if key == "secrets":
            sub = {"": val}
        elif key in ("mcp", "bash") and isinstance(val, dict):
            sub = val
        else:
            raise ValueError(f"{path}: '{key}' can't be set by {who} (only "
                             + ", ".join(sorted(".".join(x) for x in lists)) + ")")
        for sk, rules in sub.items():
            if sk.startswith("_"):
                continue
            where = (key,) if key == "secrets" else (key, sk)
            if where not in lists:
                raise ValueError(f"{path}: '{'.'.join(where)}' can't be set by {who}: it can only add "
                                 "rules that deny or ask, never exemptions")
            if not isinstance(rules, list):
                raise ValueError(f"{path}: '{'.'.join(where)}' must be a list of rules")
            for r in rules:
                if not isinstance(r, dict) or not r.get("id") or not r.get("pattern") or "input" in r:
                    raise ValueError(f"{path}: every rule in '{'.'.join(where)}' needs an id and a pattern (no input conditions)")
                added.append(r)
                default = "a company rule (.claude/limits-company.json)" if company else f"a rule of an extension ({path})"
                why = str(r.get("why") or default)
                if not company and r.get("why"):
                    why = f"an extension's own rule, in its publisher's words: {why}"
                r = dict(r, id=prefix + str(r["id"]), why=why)
                (cfg["secrets"] if key == "secrets" else cfg[key][sk]).append(r)
    if check_rules:
        check_rules(added, path)
    return cfg


# ── extensions (.claude/extensions, skills/extensions) ──────────────────────
EXTENSIONS = os.path.join(ROOT, ".claude", "extensions")
EXTENSION_LISTS = COMPANY_LISTS - {("known_prefixes",)}
EXTENSION_ID = re.compile(r"[a-z][a-z0-9]*(-[a-z0-9]+)*")


def pattern_cost(pattern):
    """How much a pattern can backtrack, or a ValueError for what an extension may not use: a slow
    pattern could make the gate time out, and a gate that times out doesn't block. Repeats only on
    a single character or class, with a maximum; alternatives multiply."""
    try:
        from re import _parser as parser  # 3.11+
    except ImportError:
        import sre_parse as parser
    single = ("LITERAL", "NOT_LITERAL", "ANY", "IN")

    def cost(tree):
        total = 1
        for op, arg in tree:
            name = str(op)
            if name in ("MAX_REPEAT", "MIN_REPEAT", "POSSESSIVE_REPEAT"):
                lo, hi, sub = arg
                if hi > 100:
                    raise ValueError("no open-ended * or +: give a maximum, like {0,40}")
                if len(sub) != 1 or str(sub[0][0]) not in single:
                    raise ValueError("a repeat goes on one character or class, not on a group")
                total *= hi - lo + 1
            elif name == "SUBPATTERN":
                total *= cost(arg[-1])
            elif name == "BRANCH":
                total *= sum(cost(x) for x in arg[1])
            elif name not in single + ("AT",):
                raise ValueError("lookarounds and back references aren't allowed")
            if total > 100:
                raise ValueError("too many ways to match: simplify it")
        return total
    return cost(parser.parse(pattern))


def check_extension_rules(rules, path):
    if len(rules) > 20:
        raise ValueError(f"{path}: at most 20 rules")
    for r in rules:
        if set(r) - {"id", "pattern", "why"} or not all(isinstance(v, str) for v in r.values()) \
                or not EXTENSION_ID.fullmatch(r["id"]) or len(r["id"]) > 40 or len(r["pattern"]) > 200 \
                or len(r.get("why", "")) > 200 or not r.get("why", "").isprintable():
            raise ValueError(f"{path}: a rule is an id, a pattern (200 characters) and a one-line why")
        try:
            pattern_cost(r["pattern"])
        except (ValueError, re.error, RecursionError, OverflowError) as e:
            raise ValueError(f"{path}: rule {r['id']}: {e}")
        if re.search(r["pattern"], ""):
            raise ValueError(f"{path}: rule {r['id']} matches everything")


def extension_lock():
    """{id: entry} from the lock; {} without extensions. ValueError if it can't be trusted."""
    path = os.path.join(EXTENSIONS, "lock.json")
    if not os.path.lexists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            lock = json.load(f)
        ext = lock["extensions"]
        ok = lock["version"] == 1 and all(EXTENSION_ID.fullmatch(k) and isinstance(e["files"], dict) for k, e in ext.items())
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        raise ValueError(f".claude/extensions/lock.json is unreadable ({e}): restore it from git")
    if not ok:
        raise ValueError(".claude/extensions/lock.json isn't in a known format: restore it from git")
    return ext


def merge_extensions(cfg):
    """Add the rules of every installed extension. A limits file that should be there and isn't, or can't
    be read, is an error: the hard limits fail closed, as with the framework's own."""
    if not os.path.isdir(EXTENSIONS):
        return cfg
    lock = extension_lock()
    found = {d for d in os.listdir(EXTENSIONS) if os.path.lexists(os.path.join(EXTENSIONS, d, "limits.json"))}
    wanted = {k for k, e in lock.items() if f".claude/extensions/{k}/limits.json" in e["files"] and not e.get("removing")}
    for ext in sorted(found | wanted):
        path = f".claude/extensions/{ext}/limits.json"
        try:
            with open(os.path.join(EXTENSIONS, ext, "limits.json"), encoding="utf-8") as f:
                extra = json.load(f)
            merge_extra(cfg, extra, path, EXTENSION_LISTS, f"ext:{ext}:", check_extension_rules)
        except (OSError, ValueError, TypeError, AttributeError) as e:
            if lock.get(ext, {}).get("removing"):
                continue
            raise ValueError(f"extension {ext}: its limits can't be read ({e}). The CEO restores it from a terminal in the "
                             f"company folder: `python3 .claude/skills/extensions/extensions.py plan repair {ext}`, then the "
                             "command it prints (or restores the file from git)")
    return cfg


def extension_problems():
    """What differs between the installed extensions and what the CEO approved."""
    if not os.path.isdir(EXTENSIONS):
        return []
    try:
        lock = extension_lock()
    except ValueError as e:
        return [str(e)]
    out = []
    for ext, entry in sorted(lock.items()):
        if entry.get("removing"):
            out.append(f"extension {ext}: its removal was interrupted; run `plan remove {ext}` again")
            continue
        changed, dirs = [], set()
        changed += [f"{rel} (left from an interrupted update)" for rel in entry.get("stale", [])]
        for rel, digest in entry["files"].items():
            dirs.add("/".join(rel.split("/")[:3]))
            p = os.path.join(ROOT, rel)
            try:
                with open(p, "rb") as f:
                    same = not os.path.islink(p) and hashlib.sha256(f.read().replace(b"\r\n", b"\n")).hexdigest() == digest
            except OSError:
                same = False
            if not same:
                changed.append(rel)
        for d in sorted(dirs):
            for base, subdirs, names in os.walk(os.path.join(ROOT, d)):
                for n in names + [x for x in subdirs if os.path.islink(os.path.join(base, x))]:
                    rel = os.path.relpath(os.path.join(base, n), ROOT).replace(os.sep, "/")
                    if rel not in entry["files"] and n != ".DS_Store":
                        changed.append(rel + " (not part of it)")
        if changed:
            out.append(f"extension {ext} isn't as approved: {', '.join(changed[:8])}" + (" …" if len(changed) > 8 else ""))
    for d in sorted(os.listdir(EXTENSIONS)):
        if d not in lock and d not in ("lock.json", ".DS_Store"):
            out.append(f".claude/extensions/{d} isn't an approved extension")
    return out


EXTENSION_APPLY = re.compile(r"python3 (?:\./)?\.claude/skills/extensions/extensions\.py apply ([0-9a-f]{64})")
# The framework's own maintenance commands, alone and as documented: no extension's rule can stop them.
MAINTENANCE = re.compile(r"python3 (?:\./)?\.claude/skills/extensions/extensions\.py (?:list|check|plan(?: [\w./:-]+)+|apply [0-9a-f]{64})"
                         r"|bash (?:\./)?\.claude/skills/update/update\.sh(?: [\w.-]+)?")


def extension_command(command, cwd):
    """("ask"|"deny", text) for a command that installs, updates or removes an extension. Anything that
    runs a plan in other words than the documented ones is denied."""
    m = EXTENSION_APPLY.fullmatch(command.strip())
    if not m:
        plain = re.sub(r"[\"'\\\\]", "", command)
        runs = re.search(r"extensions\.py\s+apply\s+\S", plain, re.I)
        names = any(os.path.exists(os.path.join(STATE, "extensions", x + ".json")) for x in re.findall(r"[0-9a-f]{64}", plain))
        if not runs and not names:
            return None
        segments = shell_segments(command)
        if segments is not None and all(is_read_only(w) or (w[0] == "git" and len(w) > 1 and w[1] in GIT_READ) for w in segments):
            return None  # a message or a search that only mentions it
        if runs and not names and not re.search(r"skills/extensions|(^|[\s;&|/])extensions\.py\s+apply\s+[0-9a-f]{64}", plain, re.I):
            return None  # some other program's script
    if not m or os.path.realpath(cwd or ROOT) != os.path.realpath(ROOT):
        return "deny", ("run it on its own, from the company folder, exactly as `plan` printed it: "
                        "`python3 .claude/skills/extensions/extensions.py apply <plan-id>`")
    try:
        with open(os.path.join(STATE, "extensions", m.group(1) + ".json"), encoding="utf-8") as f:
            plan = json.load(f)
        text = json.dumps(plan, sort_keys=True, ensure_ascii=True, separators=(",", ":"))
        if hashlib.sha256(text.encode()).hexdigest() != m.group(1):
            raise ValueError("changed")
        return "ask", extension_summary(plan)
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return "deny", "there's no such plan, or it was changed: run `plan` again"


def extension_summary(plan):
    """What the CEO confirms: everything, the weightiest first, nothing cut."""
    verb = {"add": "INSTALL", "update": "UPDATE", "repair": "RESTORE", "remove": "REMOVE"}[plan["action"]]
    t = [f"{verb} extension {plan['id']} {plan['version']} from github.com/{plan['repo']}"
         + (f"/{plan['path']}" if plan["path"] else "") + f", release {plan['tag']} ({plan['commit'][:10]})."]
    if plan["api"] != "https://api.github.com":
        t[0] = f"TEST SOURCE {plan['api']}, NOT GITHUB. " + t[0]
    if plan["action"] != "remove":
        order = ("exceptions", "service", "mcp", "requires_extensions", "company_paths")
        new = sorted(plan["adds"], key=lambda x: (order.index(x.split(":")[0]), '"write"' not in x, x))
        t += ["NEW PERMISSIONS:"] + ["  + " + x for x in new] if new else ["No new permissions."]
        t.append(f"{len(plan['files'])} files.")
    if plan["drops_limits"]:
        t += ["LIMITS THAT DISAPPEAR:"] + ["  - " + x for x in sorted(plan["drops_limits"], key=lambda x: (".ask " in x, x))]
    if plan["limits"]:
        t += ["Limits it has:"] + ["  " + x for x in plan["limits"]]
    if plan["changed"]:
        t += ["Local changes that will be lost:"] + ["  ! " + x for x in plan["changed"]]
    if plan["config"]:
        t.append(f"It creates the company settings extensions/{plan['id']}.json.")
    if plan["action"] == "remove":
        t.append(f"Company settings (extensions/{plan['id']}.json) and memory stay.")
    else:
        t.append("Its skills are instructions written outside the company: confirm only if you've read what it does.")
    return "\n".join("".join(c if c.isprintable() else "?" for c in x) for x in t)


def load_config():
    with open(CONFIG, encoding="utf-8") as f:
        cfg = json.load(f)
    merge_company(cfg)
    merge_extensions(cfg)
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
    rt = cfg["mcp"]["resource_tools"]
    rt["path_key_re"] = re.compile(rt["path_key"])
    for verb in rt["verbs"] + [rt["ask_agent"]]:
        for key in ("tool", "server", "deny_last", "deny_words", "allow"):
            if key in verb:
                # A server may put its own name before the tool's.
                verb[key + "_re"] = re.compile(r"(\w+_)?(" + verb[key] + ")" if key == "tool" and verb is not rt["ask_agent"] else verb[key])
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


PLAIN_PATH = re.compile(r"/?[A-Za-z0-9_.@=:,!$+()'-]+(/[A-Za-z0-9_.@=:,!$+()'-]+)*/?")


def resource_path(cfg, inp):
    """(paths, plain): the resource paths in a generic tool's arguments, without their query. `plain` is False when it can't be trusted to say what the call does: none or several,
    not text, encoded, absolute, or with parts that a server could read differently."""
    key_re = cfg["mcp"]["resource_tools"]["path_key_re"]
    vals = [v for k, v in (inp or {}).items() if key_re.search(re.sub(r"[^a-z0-9]", "", str(k).lower()))]
    texts = [v for v in vals if isinstance(v, str)]
    plain = len(vals) == 1 and len(texts) == 1
    out = []
    for text in texts:
        raw = text.strip()
        path = re.split(r"[?#]", raw, maxsplit=1)[0]
        if raw != text or "#" in raw or not PLAIN_PATH.fullmatch(path) or any(p in (".", "..") for p in path.split("/")):
            plain = False
        path = urllib.parse.unquote(urllib.parse.unquote(path))
        path = re.sub(r"^[a-z]+://[^/]*", "", path, flags=re.I).replace("\\", "/")
        path = re.sub(r"^/?(v1\.0|beta)(?=/)", "", path, flags=re.I)
        out.append("/" + path.strip("/ \t\r\n"))
    return out, plain


def path_words(path):
    """The path's parts as comparable words: namespace and call brackets off, letters only.
    Parts with digits or long ones are identifiers, not words."""
    words = []
    parts = [p for p in path.split("/") if p]
    for i, part in enumerate(parts):
        word = re.sub(r"\(.*\)?$", "", part.strip()).rsplit(".", 1)[-1]
        is_id = len(word) > 40 or bool(re.search(r"\d", word))
        words.append("" if is_id and i < len(parts) - 1 else re.sub(r"[^a-z]", "", word))
    return words


def resource_decision(cfg, tool, inp):
    """(decision, rule) for a tool with a generic verb, judged on the path in its arguments;
    (None, None) if the tool isn't one or the path is known to be harmless."""
    rt = cfg["mcp"]["resource_tools"]
    prefix, _, name = tool.lower().rpartition("__")
    name = name.replace("-", "_")
    agent = rt["ask_agent"]
    if agent["tool_re"].fullmatch(name):
        keys = {re.sub(r"[^a-z0-9]", "", str(k).lower()) for k in (inp or {})}
        if agent["server_re"].search(prefix.replace("-", "_")) or agent["when_key"] in keys:
            return "ask", dict(agent, unattended=False)
    for verb in rt["verbs"]:
        if not verb["tool_re"].fullmatch(name):
            continue
        rule = dict(verb, unattended=False)
        paths, plain = resource_path(cfg, inp)
        for path in paths:
            words = path_words(path.lower())
            last = words[-1] if words else ""
            if verb.get("deny_last_re") and verb["deny_last_re"].fullmatch(last):
                return "deny", rule
            if verb.get("deny_words_re") and any(verb["deny_words_re"].fullmatch(w) for w in words if w):
                return "deny", rule
            # What the path names is judged by the same rules as a tool's own name.
            for part in re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", path).lower().split("/"):
                for r in cfg["mcp"]["deny"]:
                    if r["id"] != "outbound" and r["re"].search(part):
                        return "deny", r
        if plain and verb.get("allow_re") and verb["allow_re"].fullmatch(paths[0].lower()):
            return None, None
        return "ask", rule
    return None, None


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
    decision, rule = resource_decision(cfg, tool, inp)
    if decision:
        return decision, rule
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

    if tool == "Bash" and MAINTENANCE.fullmatch(str(inp.get("command", "")).strip()):
        for rules in (cfg["secrets"], cfg["bash"]["deny"], cfg["bash"]["ask"]):
            rules[:] = [r for r in rules if not r["id"].startswith("ext:")]
    for rule in cfg["secrets"]:
        for text in texts_to_scan(tool, inp):
            if text and rule["re"].search(text):
                deny(f"juvant-os hard limit 3: secret-shaped text ({rule['id']}) in a {tool} call. "
                     "Secrets never go in the repo, memory or chat: the CEO stores them from their own terminal.")

    who = agent_identity(ev)
    try:
        hit = private_violation(tool, inp, who, os.path.realpath(str(ev.get("cwd") or ROOT)))
    except (OSError, ValueError, TypeError, IndexError, KeyError, RecursionError, re.error) as e:
        # A check that fails must not let the call through, nor skip the limits below.
        deny(f"juvant-os private files: this call couldn't be checked ({type(e).__name__}). Write it more simply.")
    if hit:
        name = hit[1]  # the row says why it's private: not for non-readers
        if name == SED_RUNS:
            deny(f"juvant-os private file: sed's `e` runs text as a command, which can't be checked against {PRIVATE_REGISTRY}. "
                 "Run the command on its own, or use sed without `e`.")
        if name:
            deny(f"juvant-os private file: this call could show `{name}`, marked private in {PRIVATE_REGISTRY}, and `{who}` "
                 f"isn't among the readers. Nothing else is blocked: repeat it without that file (Grep: glob "
                 f"`!{name}`; grep: `--exclude={name}`; rg: `-g '!{name}'`; git: `-- . ':(exclude)<its path>'`), in a narrower "
                 "folder, or listing file names only (`grep -l`).")
        deny(f"juvant-os private file: this file is marked private in {PRIVATE_REGISTRY} and `{who}` isn't among "
             f"the readers. Ask the CEO, or someone listed, to pass on what you need.")
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
            if target.endswith(SESSION_SETTINGS_SUFFIX):
                content = content_after(tool, inp, norm_path(target))
                why = session_settings_problem(content) if content is not None else "its content can't be worked out"
                if why:
                    deny(f"juvant-os long task: session permissions {target}: {why}.")
                record_pending_authorization(ev, tool, inp, target)
                ask("juvant-os long task: these are Claude Code permissions for one unattended session: the commands it "
                    "may run without asking, and the targets it may treat as trusted. Read them. Confirming lets a "
                    "collaborator session start with them (claude --settings); they end with that session.")
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
            if decision == "ask":
                # A generic verb can't be covered by a long-task authorization: its scope can't say what it does.
                auth = use_authorization(rule, tool, inp, ev) if rule.get("unattended", True) else None
                if auth and auth[0] == "allow":
                    return  # inside a long-task authorization the CEO approved for this session
                if auth and auth[0] == "past":
                    # A confirmation here helps nobody: unattended nobody answers, attended a hurried
                    # click lets through what the authorization meant to exclude (FEAT-091).
                    deny(f"juvant-os long task: {tool} is past the authorization {auth[1]}: {auth[2]}. "
                         "Don't retry: set it aside for the CEO (your log and 'Waiting for the CEO'). Doing more "
                         "needs a new authorization, approved by the CEO.")
            reason = f"juvant-os hard limit ({rule['id']}): {tool} — {rule['why']}."
            deny(reason) if decision == "deny" else ask(reason)
        return

    if tool == "Bash":
        command = str(inp.get("command", ""))
        for rule in cfg["bash"]["deny"]:
            if rule["re"].search(command):
                deny(f"juvant-os hard limit ({rule['id']}): {rule['why']}.")
        ext = extension_command(command, str(ev.get("cwd") or ROOT))
        if ext:  # before any rule that asks: the CEO must see this text, not another
            (deny if ext[0] == "deny" else ask)(f"juvant-os extensions: {ext[1]}")
        for rule in cfg["bash"]["ask"]:
            if not rule["id"].startswith("ext:") and rule["re"].search(command):
                ask(f"juvant-os hard limit ({rule['id']}): {rule['why']}.")
        decision, why = shared_repo_check(command, str(ev.get("cwd") or ROOT))
        if decision == "deny":
            deny(f"juvant-os hard limit (shared-repo): {why}. Writing where people outside the company read "
                 "is outbound: work on a branch, open a draft PR (gh pr create --draft), and the CEO merges.")
        elif decision == "ask":
            ask(f"juvant-os hard limit (shared-repo): {why}.")
        if AUTH_STATE_REL in command and bash_may_write(command, AUTH_STATE_REL):
            deny("juvant-os: state/authorizations.json is kept by the hooks. Nobody edits it.")
        launch = claude_launch_problem(command, str(ev.get("cwd") or ROOT))
        if launch:
            (deny if launch[0] == "deny" else ask)(f"juvant-os: {launch[1]}.")
        if AUTH_DIR in command and bash_may_write(command, AUTH_DIR) and not is_close_command(command):
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
        for rule in cfg["bash"]["ask"]:  # an extension's asks come last: they never stand in for a deny or another ask
            if rule["id"].startswith("ext:") and rule["re"].search(command):
                ask(f"juvant-os hard limit ({rule['id']}): {rule['why']}.")


# ── .claude/ protection (the hard limits must not edit themselves) ───────────
READ_ONLY_VERBS = {"cat", "less", "more", "head", "tail", "ls", "grep", "egrep", "fgrep", "rg", "wc", "diff", "cmp",
                   "file", "stat", "sha256sum", "shasum", "md5", "md5sum", "cut", "tr", "uniq", "nl", "column", "tree",
                   "du", "basename", "dirname", "realpath", "readlink", "jq", "yq", "od", "xxd", "hexdump", "strings",
                   "bat", "echo", "printf", "test", "[", "true", "pwd", "which", "type"}
# sed, awk and sort read unless told to write: in-place or output flags, or write/exec commands in a script.
SED_WRITES = re.compile(r"(^|[;{}\s/])[wWe]\s+\S")


def is_read_only(core):
    """True if this simple command (verb first) only reads. Redirects are checked separately."""
    if not core:
        return True
    verb, args = os.path.basename(core[0]), core[1:]
    if verb in READ_ONLY_VERBS:
        return True
    if verb in ("sed", "gsed"):
        return not any(re.match(r"^-[a-zA-Z]*i", a) or a.startswith("--in-place") or SED_WRITES.search(a) for a in args)
    if verb in ("awk", "gawk", "mawk"):
        return not any((">" in a or "system" in a or "|" in a) for a in args)
    if verb == "sort":
        return not any(a == "-o" or a.startswith(("-o", "--output")) for a in args)
    return False
GIT_READ = {"diff", "log", "show", "status", "ls-files", "blame", "add", "commit"}
# Framework scripts that never write under .claude/: the dashboard writes
# state/dashboard.html (hourly scheduled task), bugfix works in a temp clone.
EXTENSIONS_SCRIPT = ".claude/skills/extensions/extensions.py"
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


def is_claude_home_scratch(rel):
    """True if this path, relative to ~/.claude, is one of Claude Code's working areas. Under
    projects/ only a session's tool-results (downloads, long output) is: memory and transcripts aren't."""
    parts = rel.split(os.sep)
    if parts[0] in CLAUDE_HOME_SCRATCH:
        return True
    return len(parts) >= 4 and parts[0] == "projects" and parts[3] == "tool-results"


def protected_claude_path(word, here):
    """True if this word names a path in a .claude that the hard limits protect: this
    repo's, one where juvant-os is installed, or the user's ~/.claude (not its scratch areas)."""
    w = word
    if ".claude" not in w:
        # A relative path counts only when the command is already inside a .claude folder.
        if not here or ".claude" not in here or os.path.isabs(os.path.expanduser(w)) or not w.strip():
            return False
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
                not is_claude_home_scratch(os.path.relpath(full, home)):
            return True
    return False


def bash_writes_claude_dir(command, cwd=None):
    """True if a Bash command may write under a protected .claude/ outside the sanctioned
    update script. Follows `cd`: a relative write after moving into .claude/ counts."""
    if ".claude" not in command and ".claude" not in (cwd or ""):
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
        if not inside and not any(protected_claude_path(w, here) for w in words):
            continue
        if SANCTIONED.match(seg) and not re.search(r"--(from|repo|target)\b", seg):
            continue  # update from a published tag only; a local source could carry anything
        for i, w in enumerate(words[:-1]):
            if w in (">", ">>", ">|") and protected_claude_path(words[i + 1], here):
                return True
        if any(re.match(r"^\d*>>?", w) and protected_claude_path(w, here) for w in words):
            return True
        if is_read_only(core):
            continue
        if verb == "git" and len(core) > 1 and core[1] in GIT_READ:
            continue
        if verb == "find" and not any(w in ("-delete", "-exec", "-execdir", "-ok") for w in core):
            continue
        if verb in ("python3", "python") and len(core) > 1 and core[1].endswith(".claude/hooks/juvant_hooks.py"):
            continue
        if (verb in ("python3", "python") and len(core) > 2 and core[1].endswith(EXTENSIONS_SCRIPT)
                and core[2] in ("plan", "list", "check") and not any(protected_claude_path(w, here) for w in core[2:])):
            continue  # these only read .claude/; `apply` asks on its own (extension_command)
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


def private_rows(who):
    """[(absolute path or None, match, raw)] of the registry rows `who` isn't a reader of; None for URLs and ids."""
    out = []
    for match, allowed, raw in private_entries():
        if who not in allowed:
            is_url = "://" in match or not ("/" in match or "." in os.path.basename(match))
            out.append((None if is_url else norm_path(match), match, raw))
    return out


def brace_expand(word):
    m = re.search(r"\{([^{}]*,[^{}]*)\}", word)
    if not m:
        return [word]
    out = []
    for alt in m.group(1).split(",")[:20]:
        out += brace_expand(word[:m.start()] + alt + word[m.end():])
        if len(out) > 200:
            break
    return out


def glob_component(pattern, name):
    try:
        return fnmatch.fnmatchcase(name, re.sub(r"\[\^", "[!", pattern))
    except re.error:
        return True


def glob_parts(pats, names):
    """Match path components; `**` stands for any number of them."""
    if not pats:
        return not names
    if pats[0] == "**":
        return any(glob_parts(pats[1:], names[i:]) for i in range(len(names) + 1))
    return bool(names) and glob_component(pats[0], names[0]) and glob_parts(pats[1:], names[1:])


def path_relation(word, here, target):
    """"file" if this word (wildcards included) names the target, "dir" if a folder above it, else ""."""
    best = ""
    for w in brace_expand(word)[:200]:
        w = os.path.expanduser(w)
        full = os.path.normpath(w if os.path.isabs(w) else os.path.join(here, w))
        parts = full.split(os.sep)
        fixed = next((i for i, p in enumerate(parts) if re.search(r"[*?\[]", p)), len(parts))
        # Names are compared without case: macOS file systems usually ignore it.
        base = os.path.realpath(os.sep.join(parts[:fixed]) or os.sep)
        pats = [p.casefold() for p in base.split(os.sep) if p] + [p.casefold() for p in parts[fixed:]]
        names = [p.casefold() for p in target.split(os.sep) if p]
        if glob_parts(pats, names):
            return "file"
        if any(glob_parts(pats, names[:i]) for i in range(len(names))):
            best = "dir"
    return best


RG_TYPES = {"py": (".py",), "js": (".js", ".jsx", ".mjs", ".cjs"), "ts": (".ts", ".tsx"), "json": (".json",),
            "sh": (".sh", ".bash"), "yaml": (".yml", ".yaml"), "html": (".html", ".htm"), "css": (".css",)}


def globs_select(globs, target, base):
    """True if ripgrep-style globs (`!` excludes, the last match wins) leave the target in the search."""
    globs = [g for g in globs if g]
    if not globs:
        return True
    rel = os.path.relpath(target, base).casefold().split(os.sep)
    selected = all(g.startswith("!") for g in globs)
    for g in globs:
        neg, body = g.startswith("!"), g.lstrip("!").casefold()
        for b in brace_expand(body):
            b = b.strip("/")
            hit = glob_parts(b.split("/"), rel) if "/" in b else glob_component(b, rel[-1])
            if neg:  # excluding a folder excludes what is in it
                hit = hit or any(glob_parts(b.split("/"), rel[:i]) for i in range(1, len(rel)))
            if hit:
                selected = not neg
    return selected


# Commands that show names or sizes, not content, or that only write.
NAME_ONLY = {"ls", "stat", "wc", "du", "basename", "dirname", "realpath", "readlink", "test", "[", "echo", "printf",
             "tree", "touch", "mkdir", "cd", "pushd", "rmdir", "rm", "chmod", "chown"}
WRAPPERS = {"sudo", "env", "command", "builtin", "time", "nice", "nohup", "exec", "then", "do", "else", "if", "while", "!", "{"}
WHILE_READ = re.compile(r"\bwhile\s+(IFS=\S*\s+)?read\b")
SUBST = re.compile(r"\$\(([^()]*)\)|`([^`]*)`")
GREP_VERBS = {"grep", "egrep", "fgrep", "ggrep", "zgrep", "rg", "ag", "ack"}
GREP_ARG_SHORT = "efABCmdDgtT"
GREP_ARG_LONG = {"--regexp", "--file", "--after-context", "--before-context", "--context", "--max-count", "--glob",
                 "--iglob", "--type", "--type-not", "--include", "--exclude", "--exclude-dir", "--color", "--colour"}
REV = re.compile(r"^[A-Za-z0-9_@][\w./^~@{}-]*$")


def drop_redirects(words):
    """The words without output redirects (`2>/dev/null`, `> file`, `2>&1`): they aren't arguments."""
    out, i = [], 0
    while i < len(words):
        w = words[i]
        if w and set(w) <= set("<>&|") and ">" in w:
            if out and out[-1].isdigit():
                out.pop()
            i += 2
            continue
        out.append(w)
        i += 1
    return out


def piped_segments(command):
    """[(words, reads a pipe)], or None if the command can't be parsed."""
    try:
        lex = shlex.shlex(command.replace("\\\n", " ").replace("\n", "\n ; "), posix=True, punctuation_chars=";&|<>")
        lex.whitespace_split = True
        lex.commenters = ""
        out, cur, piped = [], [], False
        for tok in lex:
            if tok and set(tok) <= set(";&|"):
                if cur:
                    out.append((cur, piped))
                cur, piped = [], tok in ("|", "|&")
            else:
                cur.append(tok)
        if cur:
            out.append((cur, piped))
        return out
    except ValueError:
        return None


def grep_args(args):
    """(short flags, long flags, [(option, value)], positionals) of a grep-like command."""
    short, long_, opts, pos, i = "", [], [], [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            pos += args[i + 1:]
            break
        if a.startswith("--"):
            name, eq, val = a.partition("=")
            long_.append(name)
            if not eq and name in GREP_ARG_LONG and not name.startswith("--colo") and i + 1 < len(args):
                i += 1
                val = args[i]
            opts.append((name, val))
        elif a.startswith("-") and len(a) > 1:
            for k, ch in enumerate(a[1:], 1):
                short += ch
                if ch in GREP_ARG_SHORT:
                    val = a[k + 1:]
                    if not val and i + 1 < len(args):
                        i += 1
                        val = args[i]
                    opts.append(("-" + ch, val))
                    break
        else:
            pos.append(a)
        i += 1
    return short, long_, opts, pos


def grep_shows(verb, args, here, target, piped, names_fed):
    """True if this grep/rg can print lines of the target."""
    short, long_, opts, pos = grep_args(args)
    if not any(o in ("-e", "-f", "--regexp", "--file") for o, _ in opts) and "--files" not in long_:
        pos = pos[1:]
    recursive = verb in ("rg", "ag", "ack") or "r" in short or "R" in short or \
        any(o in ("--recursive", "--dereference-recursive") for o in long_) or ("-d", "recurse") in opts
    quiet = (set(short) & set("lLcq") if verb != "rg" else set(short) & set("lcq")) or \
        set(long_) & {"--files-with-matches", "--files-without-match", "--count", "--quiet", "--silent", "--files"}
    rel = [path_relation(p, here, target) for p in pos]
    if quiet and not names_fed:
        return False
    if "file" in rel:
        return True
    if not recursive or ("dir" not in rel and (pos or piped or not path_relation(".", here, target))):
        return False
    name = os.path.basename(target).casefold()
    if verb in ("rg", "ag", "ack"):
        return globs_select([v for o, v in opts if o in ("-g", "--glob", "--iglob")], target, here)
    inc = [v.casefold() for o, v in opts if o == "--include"]
    if inc and not any(glob_component(b, name) for v in inc for b in brace_expand(v)):
        return False
    if any(o == "--exclude" and glob_component(v.casefold(), name) for o, v in opts):
        return False
    above = [p.casefold() for p in os.path.dirname(target).split(os.sep) if p]
    return not any(o == "--exclude-dir" and any(glob_component(v.strip("/").casefold(), p) for p in above) for o, v in opts)


def git_out(here, *args):
    try:
        p = subprocess.run(["git", "-C", here, "--no-optional-locks", *args], capture_output=True, text=True, timeout=5)
        return p.stdout.strip() if p.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def git_shows(args, here, target, names_fed):
    """True if this git command can print content of the target."""
    while args and args[0].startswith("-"):
        if args[0] == "-C" and len(args) > 1:
            here = os.path.normpath(os.path.join(here, os.path.expanduser(args[1])))
        args = args[2:] if args[0] in ("-C", "-c") else args[1:]
    if not args:
        return False
    sub, rest = args[0], args[1:]
    if sub not in ("grep", "log", "show", "diff", "stash", "archive", "blame", "cat-file", "reflog", "whatchanged",
                   "format-patch"):
        return False
    top = git_out(here, "rev-parse", "--show-toplevel")
    if not top:
        return False
    top = os.path.realpath(top)
    inside = target.casefold().startswith(top.casefold() + os.sep)
    if not inside:
        return False
    for w in rest:  # <rev>:<path>
        if ":" in w and not w.startswith((":", "-")):
            p = w.split(":", 1)[1]
            if p and path_relation(p, here if p.startswith("./") or p.startswith("../") else top, target) == "file":
                return True
    paths, dash = [], "--" in rest
    if dash:
        k = rest.index("--")
        rest, paths = rest[:k], rest[k + 1:]
    flags = [w for w in rest if w.startswith("-")]
    plain = [w for w in rest if not w.startswith("-")]
    magic = [w for w in plain if w.startswith(":")]
    plain = [w for w in plain if not w.startswith(":")]
    if sub == "grep" and not any(f.startswith("-e") for f in flags):
        plain = plain[1:]
    if not dash:
        onpaths = [w for w in plain if path_relation(w, here, target) or os.path.lexists(os.path.join(here, w))
                   or re.match(r"^(\.\w|\.\.?/|/)", w)]
        paths, plain = onpaths, [w for w in plain if w not in onpaths]
    for w in paths + magic:
        m = re.match(r"^:(?:!|\^|\(exclude\))(/?)(.*)$", w)
        if m and path_relation(m.group(2) or ".", top if m.group(1) else here, target):
            return False
    wanted = [w for w in paths if not w.startswith((":!", ":^", ":(exclude)"))]
    if wanted and not any(w.startswith(":") or path_relation(w, here, target) for w in wanted):
        return False
    if sub in ("blame", "cat-file"):
        return any(path_relation(w, here, target) == "file" for w in wanted)
    spec = ":(top,literal,icase)" + os.path.relpath(target, top)
    # Anything git itself can't confirm counts as shown.
    tracked = git_out(top, "log", "--all", "-1", "--format=%h", "--", spec) != "" or git_out(top, "ls-files", "--", spec) != ""
    if sub == "grep":
        names = any(f in ("--files-with-matches", "--name-only", "--count", "-q", "--quiet", "-c", "-l", "-L")
                    or re.match(r"^-[a-zA-Z]*[lLcq]", f) for f in flags)
        return (tracked or any(f in ("--untracked", "--no-index") for f in flags)) and (names_fed or not names)
    if not tracked:
        return False
    if sub == "archive":
        return True
    patch = any(f in ("-p", "-u", "--patch", "--patch-with-stat", "-c", "--cc") or f.startswith(("-U", "--unified", "-G", "-L"))
                for f in flags if not (f.startswith("-G")))
    if any(f in ("--name-only", "--name-status", "--stat", "--shortstat", "--numstat", "--dirstat", "--summary", "--quiet",
                 "-s", "--no-patch") or f.startswith("--stat=") for f in flags) and not patch:
        return False
    if sub in ("log", "reflog") and not patch:
        return False
    if sub == "stash":
        return bool(plain) and plain[0] == "show" and patch
    if sub == "diff":
        revs = [w for w in plain if w]
        if not all(REV.match(w) for w in revs):
            return True
        cached = [f for f in flags if f in ("--cached", "--staged")]
        out = git_out(top, "diff", "--no-ext-diff", "--name-only", *cached, *revs, "--", spec)
        return out != ""
    if sub == "show":
        revs = plain or ["HEAD"]
        if not all(REV.match(w) for w in revs):
            return any(not REV.match(w) and ":" not in w for w in revs)
        return git_out(top, "show", "--no-ext-diff", "--name-only", "--format=", *revs, "--", spec) != ""
    return True


def find_shows(args, here, target, names_fed):
    roots = []
    for a in args:
        if a.startswith(("-", "(", "!")):
            break
        roots.append(a)
    if not any(path_relation(r, here, target) for r in (roots or ["."])):
        return False
    runs = [i for i, a in enumerate(args) if a in ("-exec", "-execdir", "-ok", "-okdir")]
    if not names_fed and not any(os.path.basename((args[i + 1:i + 2] or [""])[0]) not in NAME_ONLY for i in runs):
        return False
    name = os.path.basename(target).casefold()
    if "-o" not in args and "-or" not in args:
        for i, a in enumerate(args[:-1]):
            if a in ("-name", "-iname"):
                hit = glob_component(args[i + 1].casefold(), name)
                if hit == (args[i - 1] in ("!", "-not", "\\!")):
                    return False
    return True


def copy_shows(verb, args, here, target):
    """True if a recursive copy or archive takes the target along with a folder."""
    flags = "".join(a[1:] for a in args if a.startswith("-") and not a.startswith("--"))
    words = [a for a in args if not a.startswith("-")]
    ex = [a.split("=", 1)[1] for a in args if a.startswith("--exclude=")]
    ex += [args[i + 1] for i, a in enumerate(args[:-1]) if a in ("--exclude", "-x")]
    name = os.path.basename(target).casefold()
    if any(glob_component(os.path.basename(e.rstrip("/")).casefold(), name) for e in ex):
        return False
    if verb in ("tar", "gtar", "bsdtar"):
        mode = flags + (words[0] if words and not args[0].startswith("-") else "")
        if not set(mode) & set("cru") and not any(a in ("--create", "--append", "--update") for a in args):
            return False
    elif verb == "zip":
        if "r" not in flags:
            return False
        words = words[1:]
    else:  # cp, rsync, scp, ditto, mv: the last word is the destination
        if verb in ("cp", "gcp", "scp") and not set(flags) & set("rRa") and "--recursive" not in args and "--archive" not in args:
            return False
        words = words[:-1]
    return any(path_relation(w, here, target) for w in words)


COPIERS = {"tar", "gtar", "bsdtar", "zip", "cp", "gcp", "scp", "rsync", "ditto", "mv"}


# Single-quoted text is ignored only in commands made of these verbs: none of them runs its arguments.
QUOTING_VERBS = {"sed", "gsed", "grep", "egrep", "fgrep", "rg", "echo", "printf", "cat", "head", "tail", "ls", "wc",
                 "cut", "sort", "uniq", "tr", "diff", "cd", "git"}
QUOTING_GIT = {"diff", "log", "show", "status", "add", "commit"}
# Constructions where an apostrophe may not be a quote, or where quotes nest: a comment, a heredoc, $'…'.
UNSURE_QUOTES = re.compile(r"(^|[\s;&|()`])#|<<|\$'")


def quoting_is_plain(command):
    """True if single-quoted text in this command is surely inert. In doubt, False: it is checked as a command."""
    if UNSURE_QUOTES.search(command):
        return False
    segments = piped_segments(command)
    if not segments:
        return False
    for words, _ in segments:
        verb, args = words[0], words[1:]
        if verb not in QUOTING_VERBS:
            return False
        if verb == "git" and (not args or args[0] not in QUOTING_GIT):
            return False
        if verb in ("sed", "gsed") and any(re.search(r"/[a-zA-Z0-9]*e[a-zA-Z0-9]*\s*(;|\}|$)|(^|[;{}\s/0-9$])e(\s|;|$)", a) for a in args):
            return False  # GNU sed's e runs a command
        if verb == "rg" and any(a.startswith("--pre") for a in args):
            return False
    return True


def without_single_quoted(command):
    """The command with single-quoted text blanked, if that text is surely inert; else the command as it is."""
    if "'" not in command or not quoting_is_plain(command):
        return command
    out, quote, i = [], "", 0
    while i < len(command):
        ch = command[i]
        if ch == "\\" and quote != "'":
            out.append(command[i:i + 2])
            i += 2
            continue
        if quote == '"' and (ch == "`" or command.startswith(("$(", "${"), i)):
            return command  # quotes nest in there
        if ch in "'\"" and quote in ("", ch):
            quote = "" if quote else ch
        out.append(" " if quote == "'" and ch != "'" else ch)
        i += 1
    return command if quote else "".join(out)


def substitutions(command):
    """[(inner command, its output names files another command reads)] for $(…) and `…`."""
    out = []
    raw, command = command, without_single_quoted(command)
    for m in SUBST.finditer(command):
        k = 1 if m.group(1) is not None else 2
        inner = raw[m.start(k):m.end(k)]
        before = re.split(r"[;&|\n(]", command[:m.start()])[-1].split()
        while before and before[0] in WRAPPERS:
            before = before[1:]
        feeds = bool(before) and "=" not in before[0] and os.path.basename(before[0]) not in NAME_ONLY and before[0] != "git"
        out.append((inner, feeds))
    return out


SED_CARRIERS = {"sed", "gsed", "timeout", "gtimeout", "find", "parallel", "stdbuf", "ionice", "caffeinate", "busybox"}
SED_RUNS = "sed runs a command"  # what bash_shows returns for it


def sed_scripts(args):
    """The script text of a sed command line: -e values joined, or the first word that isn't an option."""
    scripts, first, given, i = [], None, False, 0
    while i < len(args):
        a = args[i]
        if a == "--sandbox":
            return ""  # sed itself refuses e, r and w
        if a.startswith("--"):
            name, eq, val = a.partition("=")
            if len(name) > 3 and ("--expression".startswith(name) or "--file".startswith(name)):
                if not eq:
                    i += 1
                    val = args[i] if i < len(args) else ""
                given = True
                if "--expression".startswith(name):
                    scripts.append(val)
        elif a.startswith("-") and len(a) > 1:
            for k, ch in enumerate(a[1:], 1):
                if ch in "efl":
                    val = a[k + 1:]
                    if not val and ch != "l":
                        i += 1
                        val = args[i] if i < len(args) else ""
                    if ch != "l":
                        given = True
                    if ch == "e":
                        scripts.append(val)
                    break
                if ch in "iI":  # GNU: the rest is a suffix; BSD: the next word may be
                    if k == len(a) - 1 and i + 1 < len(args) and (args[i + 1] == "" or args[i + 1].startswith(".")):
                        i += 1
                    break
        elif first is None:
            first = a
        i += 1
    return "\n".join(scripts) if given else (first or "")


def sed_part(text, i, delim, brackets):
    """(part, index after its closing delimiter), or (None, i) if there is none."""
    start = i
    while i < len(text):
        ch = text[i]
        if ch == "\\":
            i += 2
            continue
        if brackets and ch == "[":
            j = i + 1
            j += text[j:j + 1] == "^"
            j += text[j:j + 1] == "]"
            end = text.find("]", j)
            if end > 0:
                i = end + 1
                continue
        if ch == delim:
            return text[start:i], i + 1
        i += 1
    return None, start


def sed_regex(text, i, delim):
    """Like sed_part. GNU sed ends a regex at the delimiter even inside [...] (and then refuses it); BSD doesn't."""
    part, j = sed_part(text, i, delim, False)
    if part is not None and re.search(r"\[[^\]]*$", re.sub(r"\\.", "", part)):
        wide, k = sed_part(text, i, delim, True)
        if wide is not None:
            return wide, k
    return part, j


def sed_effects(script):
    """(True if the script runs a command with GNU sed's e, [files it reads with r or R])."""
    i, n, files = 0, len(script), []

    def eol(k):
        e = script.find("\n", k)
        return n if e < 0 else e

    while i < n:
        ch = script[i]
        if ch in " \t\r\n;{}!,~+0123456789$":
            i += 1
        elif ch == "/" or ch == "\\":
            k = i + 1 + (ch == "\\")
            part, k = sed_regex(script, k, "/" if ch == "/" else script[i + 1:i + 2] or "/")
            if part is None:
                return False, files
            while script[k:k + 1] and script[k] in "IM":
                k += 1
            i = k
        elif ch in "sy":
            delim = script[i + 1:i + 2]
            if not delim or delim in "\n\\":
                return False, files
            part, k = sed_regex(script, i + 2, delim) if ch == "s" else sed_part(script, i + 2, delim, False)
            if part is None:
                return False, files
            part, k = sed_part(script, k, delim, False)
            if part is None:
                return False, files
            i = k
            while ch == "s" and script[i:i + 1] and script[i] in "gpiImMe0123456789w":
                if script[i] == "e":
                    return True, files
                if script[i] == "w":
                    i = eol(i)
                    break
                i += 1
        elif ch == "e":
            return True, files
        elif ch in "rR":
            files.append(script[i + 1:eol(i)].strip())
            i = eol(i)
        elif ch in "wW#":
            i = eol(i)
        elif ch in "aic":
            i = eol(i + 1)
            while i < n and script[i - 1] == "\\":
                i = eol(i + 1)
        elif ch in ":btT":
            i += 1
            while i < n and script[i] in " \t":
                i += 1
            while i < n and script[i] not in " \t;\n}":  # GNU ends a label at a space
                i += 1
        else:
            i += 1
    return False, files


def bash_shows(command, cwd, target, depth=0, fed=False):
    """True if a Bash command can show or copy the target without writing its path literally.
    Text matching: it follows cd, wildcards, simple variables and the usual search commands.
    It can't follow interpreters or every shell construction."""
    segments = piped_segments(command)
    if segments is None:
        segments = [(s.split(), False) for s in re.split(r"[;&|\n]+", command)]
    here = cwd or ROOT
    env = {"HOME": os.path.expanduser("~"), "CLAUDE_PROJECT_DIR": ROOT}
    for inner, feeds in substitutions(command) if depth < 3 else ():
        found = bash_shows(inner, here, target, depth + 1, feeds)
        if found:
            return found
    fed = fed or bool(WHILE_READ.search(command)) or any(
        os.path.basename(w) == "xargs" and os.path.basename(next((x for x in ws[i + 1:] if not x.startswith("-")
                                                                  and x != "{}" and not x.isdigit()), "echo")) not in NAME_ONLY
        for ws, _ in segments for i, w in enumerate(ws))

    def sub(w):
        return re.sub(r"\$(?:\{(\w+)\}|(\w+))", lambda m: env.get(m.group(1) or m.group(2), m.group(0)), w)

    for raw, piped in segments:
        words = []
        for w in drop_redirects(raw):
            if re.search(r"\s", sub(w)):  # a quoted script or text: not a word to trim
                words.append(sub(w))
                continue
            w = re.sub(r"^[({`]+(?=[^,]*$)|^\$\(", "", sub(w)) if not w.startswith("${") else sub(w)
            w = w.rstrip("`")
            if w.endswith(")") and "(" not in w:
                w = w.rstrip(")")
            if w:
                words.append(w)
        while words and (os.path.basename(words[0]) in WRAPPERS or re.match(r"^\w+=", words[0])):
            m = re.match(r"^(\w+)=(.*)$", words[0], re.S)
            if m:
                env[m.group(1)] = m.group(2)
                if path_relation(m.group(2), here, target) == "file":
                    return True
            words = words[1:]
        if not words:
            continue
        verb, args = os.path.basename(words[0]), words[1:]
        for i, w in enumerate(words[:-1]):
            if w == "<" and path_relation(words[i + 1], here, target) == "file":
                return True
            if w == "<" and not words[i + 1].startswith("("):
                args = [a for j, a in enumerate(words[1:], 1) if j not in (i, i + 1)]
        if verb in ("cd", "pushd"):
            t = next((a for a in args if a == "-" or not a.startswith("-")), "~")
            if t != "-" and "$" not in t:
                here = os.path.normpath(os.path.join(here, os.path.expanduser(t)))
            continue
        if verb in ("bash", "sh", "zsh", "eval") and depth < 3:
            script = " ".join(args) if verb == "eval" else next(
                (args[i + 1] for i, a in enumerate(args[:-1]) if re.match(r"^-[a-z]*c$", a)), "")
            found = script and bash_shows(script, here, target, depth + 1)
            if found:
                return found
        if verb in ("xargs",):
            k = next((i for i, a in enumerate(args) if not a.startswith("-") and a != "{}" and not a.isdigit()), None)
            if k is None:
                continue
            verb, args = os.path.basename(args[k]), args[k + 1:]
            piped = True
        if verb in SED_CARRIERS:
            k = 0 if verb in ("sed", "gsed") else next(
                (j + 1 for j, a in enumerate(args) if os.path.basename(a) in ("sed", "gsed")), None)
            runs, reads = sed_effects(sed_scripts(args[k:])) if k is not None else (False, [])
            if any(f and path_relation(f, here, target) == "file" for f in reads):
                return True
            if runs:
                return SED_RUNS  # what it runs may come from the input: it can't be checked
        if verb in GREP_VERBS:
            if grep_shows(verb, args, here, target, piped, fed):
                return True
            continue
        if verb == "git":
            if git_shows(args, here, target, fed):
                return True
            continue
        if verb == "find":
            if find_shows(args, here, target, fed):
                return True
            continue
        if verb in COPIERS and copy_shows(verb, args, here, target):
            return True
        if verb in NAME_ONLY and not (fed and verb == "ls"):
            continue
        if verb in ("sed", "gsed", "awk", "gawk", "mawk", "jq", "yq"):
            k = next((i for i, a in enumerate(args) if not a.startswith("-")), None)
            args = args if k is None or any(a in ("-e", "-f") for a in args) else args[:k] + args[k + 1:]
        for w in args:
            for cand in {w, w.split("=", 1)[1] if "=" in w else w}:
                r = path_relation(cand, here, target) if cand and not cand.startswith("-") else ""
                if r == "file" or (r == "dir" and fed and verb == "ls") or \
                        (r == "dir" and verb == "diff" and any(re.match(r"^-[a-zA-Z]*r|^--recursive", a) for a in args)):
                    return True
    return False


def grep_tool_shows(inp, cwd, target):
    """True if a Grep tool call would return lines of the target."""
    if str(inp.get("output_mode") or "files_with_matches") != "content":
        return False
    root = str(inp.get("path") or cwd)
    if path_relation(root, cwd, target) != "dir":
        return False
    ext = RG_TYPES.get(str(inp.get("type") or ""))
    if ext and not target.casefold().endswith(ext):
        return False
    globs, cur, depth = [], "", 0
    for ch in str(inp.get("glob") or ""):  # split on spaces and commas outside braces
        depth += (ch == "{") - (ch == "}")
        if ch in " ," and depth <= 0:
            globs, cur = globs + [cur], ""
        else:
            cur += ch
    return globs_select(globs + [cur], target, os.path.realpath(os.path.join(cwd, os.path.expanduser(root))))


def private_violation(tool, inp, who, cwd=None):
    """(registry row, file name to exclude or "") that this call would break, or None. The name is
    set when the call only reaches the file through a folder, a wildcard or git."""
    rows = private_rows(who)
    if not rows:
        return None
    cwd = cwd or ROOT
    blob = json.dumps(inp, ensure_ascii=False)
    for target, match, raw in rows:
        if target is None:
            if match in blob:
                return raw, ""
            continue
        name = os.path.basename(target)
        if tool in ("Read", "Edit", "MultiEdit", "Write", "NotebookEdit", "Grep", "Glob"):
            fp = str(inp.get("path" if tool in ("Grep", "Glob") else "file_path") or inp.get("notebook_path") or "")
            if fp and (norm_path(fp) == target or path_relation(glob.escape(fp).replace("{", "[{]"), cwd, target) == "file"):
                return raw, ""
            if tool == "Grep" and grep_tool_shows(inp, cwd, target):
                return raw, name
        elif tool == "Bash":
            cmd = str(inp.get("command", ""))
            rel = os.path.relpath(target, os.path.realpath(ROOT))
            names = [match, target] + ([] if rel.startswith("..") else [rel])
            literal = cmd
            for n in names:  # naming the file to leave it out of a search isn't reading it
                literal = re.sub(r"(:!|:\^|:\(exclude\)|--exclude[= ]['\"]?|!)/?" + re.escape(n) + r"(?=['\"\s]|$)", "", literal)
            if any(n in literal for n in names):
                return raw, ""
            found = bash_shows(cmd, cwd, target)
            if found:
                return raw, (SED_RUNS if found == SED_RUNS else name)
        elif tool.startswith("mcp__") and match in blob:
            return raw, ""
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
def is_close_command(command):
    """True for `[cd <dir> &&] python3 .claude/hooks/juvant_hooks.py close-authorization <file> [reason]`:
    closing never needs the CEO. Each part is checked; anything else in the command, a redirect or a
    command substitution makes it an ordinary command."""
    if "`" in command or "$(" in command or "${" in command:
        return False
    segments = shell_segments(command)
    if not segments:
        return False
    closes = 0
    for words in segments:
        if any(w in (">", ">>", ">|", "<", "<<", "<<<") or re.match(r"^\d*[<>]", w) for w in words):
            return False
        if words[0] == "cd" and len(words) <= 2:
            continue
        if (len(words) >= 4 and os.path.basename(words[0]) in ("python3", "python")
                and words[1].endswith(".claude/hooks/juvant_hooks.py") and words[2] == "close-authorization"):
            closes += 1
            continue
        return False
    return closes > 0


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
        if is_read_only(core):
            continue
        if verb == "git" and len(core) > 1 and core[1] in GIT_READ:
            continue
        if verb == "find" and not any(w in ("-delete", "-exec", "-execdir", "-ok") for w in core):
            continue
        if verb == "claude" and all((i > 0 and core[i - 1] == "--settings") or w.startswith("--settings=")
                                    for i, w in enumerate(core) if needle in w):
            continue  # a session started with these settings reads the file (claude_launch_problem checks it)
        return True
    return False


def is_authorization_path(p):
    if not p:
        return False
    full, base = norm_path(p), norm_path(AUTH_DIR)
    return full.startswith(base + os.sep) and (full.endswith(".md") or full.endswith(SESSION_SETTINGS_SUFFIX))


# ── session permissions (FEAT-092) ───────────────────────────────────────────
# A long task that Claude Code's own permission system would stop (auto mode
# blocks IaC applies, repo creation, deploys…) gets narrow Claude Code rules for
# its session only: memory/authorizations/<name>.settings.json, approved by the
# CEO like the authorization, passed with `claude --settings <file>`. The hooks
# validate what such a file may hold, and allow a launch with --settings only
# for an approved, unchanged one. Money, outbound and secrets stay denied by the
# hooks whatever Claude Code's permissions say.
SESSION_SETTINGS_SUFFIX = ".settings.json"
INTERPRETERS = {"python", "python3", "node", "bash", "sh", "zsh", "fish", "ruby", "perl", "php", "pwsh", "eval", "env",
                "xargs", "sudo", "su", "exec", "nohup", "time", "watch", "osascript", "deno", "bun", "npx", "uvx"}
CLAUDE_UNSAFE_FLAGS = {"--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--bare",
                       "--safe-mode", "--restricted", "--setting-sources"}


def session_settings_problem(text):
    """Why this session-settings file isn't acceptable, or None. Only narrow additions are allowed."""
    try:
        d = json.loads(text)
    except ValueError as e:
        return f"not valid JSON ({e})"
    if not isinstance(d, dict):
        return "expected a JSON object"
    for key in d:
        if key not in ("permissions", "autoMode") and not key.startswith("_"):
            return f"'{key}' can't be set here: only permissions.allow, permissions.deny and autoMode.environment"
    perms = d.get("permissions", {})
    if not isinstance(perms, dict):
        return "permissions must be an object"
    for key in perms:
        if key not in ("allow", "deny"):
            return f"permissions.{key} can't be set here (no defaultMode, no ask, no additionalDirectories)"
    for rule in perms.get("allow", []):
        m = re.fullmatch(r"Bash\((.+)\)", str(rule).strip())
        if not m:
            return f"allow rule {rule!r}: only Bash(<command> …) rules are allowed"
        body = m.group(1).strip()
        words = body.replace(":*", "").split()
        if len(words) < 2 or any(c in body for c in "|;&`$<>") or "*" in body.replace(":*", "") or body.endswith(" *"):
            return f"allow rule {rule!r}: pin the command and its subcommand, with no wildcards, pipes or chaining"
        if os.path.basename(words[0]) in INTERPRETERS or os.path.basename(words[0]) == "claude":
            return f"allow rule {rule!r}: interpreters and wrappers can't be allowed, they run anything"
    am = d.get("autoMode", {})
    if not isinstance(am, dict):
        return "autoMode must be an object"
    for key, val in am.items():
        if key != "environment":
            return f"autoMode.{key} can't be set here: only autoMode.environment (describe the task's trusted targets)"
        if not isinstance(val, list) or "$defaults" not in val:
            return "autoMode.environment must be a list that starts with \"$defaults\" (keep the built-in rules)"
    return None


def approved_session_settings(path):
    """True if path is a session-settings file the CEO approved and nobody changed since (≤ 24 h)."""
    if not path.endswith(SESSION_SETTINGS_SUFFIX) or not is_authorization_path(path):
        return False
    rec = load_auth_state().get(auth_key(path))
    raw = read_raw(norm_path(path))
    if not isinstance(rec, dict) or rec.get("closed") or raw is None or sha256(raw) != rec.get("hash"):
        return False
    if time.time() > float(rec.get("recorded") or 0) + AUTH_MAX_HOURS * 3600:
        return False
    return session_settings_problem(raw) is None


def claude_launch_problem(command, cwd):
    """("deny"|"ask", why) for a `claude` launch that drops the hooks or permissions, or uses
    settings the CEO hasn't approved; None otherwise."""
    if "claude" not in command:
        return None
    segments = shell_segments(command)
    if segments is None:
        return None
    here = cwd or ROOT
    for words in segments:
        if not words:
            continue
        if words[0] == "cd" and len(words) > 1:
            here = os.path.normpath(os.path.join(here, os.path.expanduser(words[1])))
            continue
        if os.path.basename(words[0]) != "claude":
            continue
        flags = {w.split("=", 1)[0] for w in words if w.startswith("--")}
        bad = sorted(flags & CLAUDE_UNSAFE_FLAGS)
        if bad:
            return "deny", f"starting a session with {', '.join(bad)} would drop the hard limits or the permission checks"
        for i, w in enumerate(words):
            mode = words[i + 1] if w == "--permission-mode" and i + 1 < len(words) else (w.split("=", 1)[1] if w.startswith("--permission-mode=") else "")
            if mode == "bypassPermissions":
                return "deny", "starting a session with --permission-mode bypassPermissions would drop the permission checks"
            val = words[i + 1] if w == "--settings" and i + 1 < len(words) else (w.split("=", 1)[1] if w.startswith("--settings=") else None)
            if val is not None:
                path = os.path.normpath(os.path.join(here, os.path.expanduser(val)))
                if val.lstrip().startswith("{") or not approved_session_settings(path):
                    return "ask", (f"this starts a session with settings ({val}) that the CEO hasn't approved as a long-task "
                                   f"session-permissions file ({AUTH_DIR}/<name>{SESSION_SETTINGS_SUFFIX}, written and confirmed first)")
    return None


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
    """("allow", file) if an open authorization of this session covers this would-be `ask` (counted
    and logged); ("past", file, why) if one would cover it except that its max is used up or it has
    expired; None otherwise."""
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
    past = None
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
        if expires is None:
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
            cap = int(fm["max"])  # required: without it the authorization covers nothing
        except (KeyError, ValueError):
            continue
        if t > min(expires, recorded + AUTH_MAX_HOURS * 3600):
            past = past or (key, "it has expired")
            continue
        if int(rec.get("used", 0)) >= cap:
            past = past or (key, f"its max of {cap} is used up")
            continue
        rec["used"] = int(rec.get("used", 0)) + 1
        try:
            save_auth_state(st)
        except OSError:
            return None  # can't count it: don't allow it
        activity("authorized", ev, tool=tool, rule=rule["id"], authorization=key, count=rec["used"])
        return ("allow", key)
    return ("past",) + past if past else None


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
    activity("authorization_closed", {"session_id": rec.get("session", "") if isinstance(rec, dict) else ""},
             authorization=auth_key(path), reason=reason)
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


WAITING_LINE = re.compile(r"^(\s*)-\s*Waiting for the CEO\s*:?\s*(.*)$", re.I)
JOURNAL_FIELD = re.compile(r"^\s*-\s*(Done|Decided|Open|Waiting for the CEO|Notes|Next)\s*:", re.I)


def parse_waiting(text):
    """The items of the last "Waiting for the CEO" in a journal, or None if it has none. Two forms:
    one line (`- Waiting for the CEO: a; b`) or the label alone with a bulleted list under it, up
    to the next field (`- Open:`…) or heading. Sub-bullets join their item. An empty list is []."""
    lines = text.splitlines()
    idx = next((i for i in range(len(lines) - 1, -1, -1) if WAITING_LINE.match(lines[i])), None)
    if idx is None:
        return None
    base, rest = WAITING_LINE.match(lines[idx]).groups()
    if rest.strip():
        return [] if re.match(r"^(see|nothing|none|-)\b", rest.strip(), re.I) else [rest.strip()]
    items, top = [], None
    for line in lines[idx + 1:]:
        if line.lstrip().startswith("#") or (JOURNAL_FIELD.match(line) and len(line) - len(line.lstrip()) <= len(base)):
            break
        if not line.strip():
            continue
        m = re.match(r"^(\s*)[-*]\s+(.*)$", line)
        if not m:
            if items:
                items[-1] += " " + line.strip()  # a wrapped line
            continue
        ind, item = len(m.group(1)), m.group(2).strip()
        if top is None or ind <= top:
            top = ind if top is None else top
            items.append(item)
        else:
            prev = items[-1].rstrip(" ;,")
            items[-1] = prev + (" " if prev.endswith(":") else "; ") + item
    return items


def waiting_for_ceo():
    """(day, items) from the last "Waiting for the CEO" of the most recent journal that has one.
    Each wrap-up writes the whole current list, so earlier ones are stale; a newer journal without
    it (notes written outside a wrap-up) doesn't hide it. (None, []) if none."""
    jdir = os.path.join(ROOT, "memory", "journal")
    try:
        days = sorted((n for n in os.listdir(jdir) if re.match(r"\d{4}-\d{2}-\d{2}\.md$", n)), reverse=True)
    except OSError:
        return None, []
    for day in days[:60]:
        items = parse_waiting(read_text(os.path.join("memory", "journal", day)) or "")
        if items is not None:
            return day, items
    return None, []


WAITING_SHOW_CAP = 1200


def waiting_banner():
    """What the CEO sees on screen at session start: the agent can't speak first."""
    day, items = waiting_for_ceo()
    if not items:
        return ""
    text = f"Waiting for you (memory/journal/{day}):\n" + "\n".join("• " + i for i in items)
    if len(text) > WAITING_SHOW_CAP:
        text = text[:WAITING_SHOW_CAP].rsplit(" ", 1)[0] + " …"
    return text + "\nAsk the Chief of Staff to go through them."


def memory_digest(who="cos"):
    """Short memory context for the main session: map, recent active decisions,
    and what the latest journal says is waiting for the CEO."""
    parts = []
    hidden = {t.casefold() for t, _, _ in private_rows(who) if t}

    def shown(rel):  # private files stay out of the digest of an agent that can't read them
        return not hidden or norm_path(rel).casefold() not in hidden

    m = read_text(os.path.join("memory", "map.md")) if shown(os.path.join("memory", "map.md")) else None
    if m:
        parts.append("## memory/map.md\n\n" + (m if len(m) <= MAP_CAP else m[:MAP_CAP] + "\n[…truncated: read memory/map.md]"))
    ddir = os.path.join(ROOT, "memory", "decisions")
    rows = []
    try:
        names = sorted((n for n in os.listdir(ddir) if n.endswith(".md") and shown(os.path.join("memory", "decisions", n))), reverse=True)
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
        if not shown(os.path.join("memory", "projects", slug, "README.md")):
            continue
        card = read_text(os.path.join("memory", "projects", slug, "README.md")) or ""
        status = frontmatter(card).get("status", "active")
        if status == "closed":
            continue
        name = next((l[2:].strip() for l in card.splitlines() if l.startswith("# ")), slug)
        latest = ""
        try:
            ds = sorted((n for n in os.listdir(os.path.join(pdir, slug, "decisions"))
                         if n.endswith(".md") and shown(os.path.join("memory", "projects", slug, "decisions", n))), reverse=True)
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
    if waiting and shown(os.path.join("memory", "journal", day)):
        parts.append(f"## Waiting for the CEO (memory/journal/{day})\n\n" + "\n".join("- " + i for i in waiting))
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
    for problem in extension_problems():
        lines.append(f"WARNING, tell the CEO first thing: {problem}. Don't follow that extension's skills until it's "
                     "cleared (extensions skill: `plan repair`).")
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
        digest = memory_digest((agent or "cos").lower())
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
    if name == "limits" and hasattr(signal, "setitimer"):
        # A check that never ends would time out, and a hook that times out doesn't block.
        def too_long(*_):
            deny("juvant-os hard limits: the check took too long. Blocked to stay safe: write the call more simply.")
        signal.signal(signal.SIGALRM, too_long)
        signal.setitimer(signal.ITIMER_REAL, CHECK_SECONDS)
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
