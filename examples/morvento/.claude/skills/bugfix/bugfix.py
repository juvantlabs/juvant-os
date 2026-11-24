#!/usr/bin/env python3
"""bugfix.py — help send a juvant-os framework fix upstream (the bugfix skill).

  python3 .claude/skills/bugfix/bugfix.py prepare
      Clone juvant-os into a fresh temp folder on the branch fixes target.
      Prints the folder and the base branch.
  python3 .claude/skills/bugfix/bugfix.py check <clone> [--body <file>] [--term <word>]...
      Check the change against the base branch, plus the PR text, for anything
      that belongs to this company: its name, the CEO's and the agents' names,
      this machine's user and home path, the company's GitHub owner, and
      secret-shaped text. Exit 1 and list every hit; exit 0 if clean.

Runs from the company repo (.claude/skills/bugfix/). Writes nothing in it.
Standard library only.
"""
import argparse
import getpass
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
COMPANY = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
REPO_URL = os.environ.get("JUVANT_OS_REPO", "https://github.com/juvantlabs/juvant-os.git")
STATE = ".bugfix.json"


def git(*args, cwd=None, check=True):
    p = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if check and p.returncode != 0:
        sys.exit(f"bugfix: git {' '.join(args)} failed: {p.stderr.strip()}")
    return p.stdout


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def cmd_prepare(_):
    if not os.path.isfile(os.path.join(COMPANY, ".claude", "juvant-os.json")):
        sys.exit(f"bugfix: run me from a juvant-os v2 company repo; {COMPANY} isn't one")
    dest = tempfile.mkdtemp(prefix="juvant-os-fix-")
    # Fixes target the branch that carries v2: main once it has framework/FILES, else v2.
    for branch in ("main", "v2"):
        clone = os.path.join(dest, "juvant-os")
        p = subprocess.run(["git", "clone", "-q", "--branch", branch, REPO_URL, clone], capture_output=True, text=True)
        if p.returncode == 0 and os.path.isfile(os.path.join(clone, "framework", "FILES")):
            break
        subprocess.run(["rm", "-rf", clone])
    else:
        sys.exit(f"bugfix: no v2 branch found in {REPO_URL}")
    with open(os.path.join(clone, ".git", "info", "exclude"), "a", encoding="utf-8") as f:
        f.write(f"\n{STATE}\n")
    with open(os.path.join(clone, STATE), "w", encoding="utf-8") as f:
        json.dump({"base": branch, "company": COMPANY}, f)
    print(f"clone: {clone}\nbase: {branch}")


def company_terms(extra):
    """[(term, why)] that must not leave the company."""
    terms = []
    claude_md = read(os.path.join(COMPANY, "CLAUDE.md"))
    m = re.search(r"^# (.+?) — Chief of Staff", claude_md, re.M)
    if m:
        terms.append((m.group(1), "company name"))
    m = re.search(r"You are (.+?), Chief of Staff of .+?\. You work for (.+?), the CEO", claude_md)
    if m:
        terms += [(m.group(1), "Chief of Staff's name"), (m.group(2), "CEO's name")]
    m = re.search(r"^# (.+?) manifesto", read(os.path.join(COMPANY, "manifesto.md")), re.M)
    if m:
        terms.append((m.group(1), "company name"))
    roles = os.path.join(COMPANY, "roles")
    for name in sorted(os.listdir(roles)) if os.path.isdir(roles) else []:
        m = re.search(r"^name:\s*(.+)$", read(os.path.join(roles, name)), re.M)
        if m:
            terms.append((m.group(1).strip(), f"agent name ({name[:-3]})"))
    url = git("remote", "get-url", "origin", cwd=COMPANY, check=False).strip()
    m = re.search(r"github\.com[/:]([^/]+)/", url)
    if m:
        terms.append((m.group(1), "company's GitHub owner"))
    home = os.path.expanduser("~")
    terms += [(home, "home path"), (getpass.getuser(), "machine user")]
    for key in ("user.name", "user.email"):
        v = git("config", key, cwd=COMPANY, check=False).strip()
        if v:
            terms.append((v, f"git {key}"))
    terms += [(t, "extra term") for t in extra]
    out, seen = [], set()
    for t, why in terms:
        t = t.strip()
        # Placeholders and very short words would match everywhere.
        if len(t) < 3 or "{{" in t or t.lower() in ("juvantlabs", "root", "user") or t.lower() in seen:
            continue
        seen.add(t.lower())
        out.append((t, why))
    return out


def secret_patterns():
    try:
        with open(os.path.join(COMPANY, ".claude", "hooks", "limits.json"), encoding="utf-8") as f:
            return [(r["id"], re.compile(r["pattern"])) for r in json.load(f)["secrets"]]
    except (OSError, ValueError, KeyError, re.error):
        return []


def cmd_check(a):
    clone = os.path.abspath(a.clone)
    state = json.loads(read(os.path.join(clone, STATE)) or "{}")
    base = state.get("base") or "v2"
    git("fetch", "-q", "origin", base, cwd=clone, check=False)
    diff = git("diff", f"origin/{base}", cwd=clone, check=False)
    log = git("log", "--format=%an <%ae>%n%B", f"origin/{base}..HEAD", cwd=clone, check=False)
    untracked = git("ls-files", "--others", "--exclude-standard", cwd=clone, check=False).split()
    texts = []  # (where, text)
    current = "diff"
    for line in diff.splitlines():
        if line.startswith("+++ "):
            current = line[6:] if line.startswith("+++ b/") else line[4:]
        elif line.startswith("+") and not line.startswith("+++"):
            texts.append((current, line[1:]))
    for f in untracked:
        for line in read(os.path.join(clone, f)).splitlines():
            texts.append((f + " (new, not added)", line))
    texts += [("commit message", line) for line in log.splitlines()]
    if a.body:
        texts += [("PR text", line) for line in read(a.body).splitlines()]
    hits = []
    for term, why in company_terms(a.term):
        rx = re.compile(r"(?<![\w])" + re.escape(term) + r"(?![\w])", re.I)
        hits += [f"{where}: {why} ('{term}')" for where, text in texts if rx.search(text)]
    for sid, rx in secret_patterns():
        hits += [f"{where}: secret-shaped text ({sid})" for where, text in texts if rx.search(text)]
    if not texts:
        print("bugfix: no change found against origin/" + base)
        return 1
    if hits:
        print("bugfix: not generic yet. Rewrite these for a reader outside the company:")
        for h in sorted(set(hits)):
            print("  - " + h)
        return 1
    print(f"bugfix: clean ({len(texts)} lines checked against origin/{base})")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Send a juvant-os framework fix upstream.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("prepare")
    c = sub.add_parser("check")
    c.add_argument("clone")
    c.add_argument("--body")
    c.add_argument("--term", action="append", default=[])
    a = ap.parse_args()
    if a.cmd == "prepare":
        cmd_prepare(a)
        return 0
    return cmd_check(a)


if __name__ == "__main__":
    sys.exit(main())
