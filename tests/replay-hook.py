#!/usr/bin/env python3
"""Replay real shell commands through two versions of the hard-limits hook and show what changed.

    python3 tests/replay-hook.py <old company folder> <new company folder> [transcripts glob ...]

Each folder is a company with juvant-os installed (setup.sh), one with the release before, one with the change.
The commands come from Claude Code transcripts on this machine (default: ~/.claude/projects/*/*.jsonl): they
stay on this machine, and only counts and the changed commands are printed. Not run by CI."""
import glob
import json
import os
import subprocess
import sys
from collections import Counter
from multiprocessing import Pool

RANK = {"allow": 0, "ask": 1, "deny": 2, "error": 3}


def decide(args):
    co, command = args
    try:
        p = subprocess.run([sys.executable, os.path.join(co, ".claude", "hooks", "juvant_hooks.py"), "limits"],
                           input=json.dumps({"tool_name": "Bash", "tool_input": {"command": command}, "cwd": co, "session_id": "s"}),
                           capture_output=True, text=True, timeout=40, env=dict(os.environ, CLAUDE_PROJECT_DIR=co))
        out = json.loads(p.stdout)["hookSpecificOutput"] if p.stdout.strip() else {}
        return out.get("permissionDecision", "allow"), out.get("permissionDecisionReason", "")
    except (subprocess.TimeoutExpired, ValueError, KeyError) as e:
        return "error", str(e)


def commands(patterns):
    found = set()
    for path in (p for pattern in patterns for p in glob.glob(os.path.expanduser(pattern))):
        with open(path, errors="ignore") as f:
            for line in f:
                if '"Bash"' not in line:
                    continue
                try:
                    for block in json.loads(line)["message"]["content"]:
                        if block.get("name") == "Bash" and len(block["input"]["command"]) < 20000:
                            found.add(block["input"]["command"])
                except (ValueError, KeyError, TypeError, AttributeError):
                    pass
    return sorted(found)


def main():
    old, new = (os.path.abspath(x) for x in sys.argv[1:3])
    cmds = commands(sys.argv[3:] or ["~/.claude/projects/*/*.jsonl"])
    with Pool(10) as pool:
        before = pool.map(decide, [(old, c) for c in cmds])
        after = pool.map(decide, [(new, c) for c in cmds])
    print(f"{len(cmds)} commands; old -> new:", dict(Counter((a[0], b[0]) for a, b in zip(before, after))))
    for title, keep in (("STRICTER", lambda a, b: RANK[b] > RANK[a]), ("LOOSER", lambda a, b: RANK[b] < RANK[a])):
        changed = [(c, a, b) for c, a, b in zip(cmds, before, after) if keep(a[0], b[0])]
        print(f"\n{title}: {len(changed)}")
        for c, a, b in changed:
            print(f"  {a[0]} -> {b[0]}  {(b[1] or a[1])[:80]}\n    {c[:300]!r}")


if __name__ == "__main__":
    main()
