#!/usr/bin/env python3
"""
tests/schema/test-category-allowlist.py — decisions.category allowlist drift guard
(BUG-063 / BUG-074, decisions#267).

The allowlist lives in six places that must agree:
  scripts/schema.sql            decisions_category_check_ins + _upd
  scripts/migrate.sh            the same two triggers (COMMON_PATCHES, shared by local + turso)
  scripts/governance-backfill.sh CANONICAL_LIST
  JUVANT_OS.md                  the schema quick reference + the Memory Commit enumeration

and every category an agent template (or JUVANT_OS.md / SYSTEM_INVARIANTS.md)
tells an agent to WRITE to `decisions` must be in it — otherwise the trigger
aborts a write the framework itself prescribes (the BUG-074 class, four times).

Also checks: no BEFORE INSERT trigger in migrate.sh references OLD (BUG-079),
and the schema really accepts every listed category and rejects others.

Run: python3 tests/schema/test-category-allowlist.py   Exit: 0 pass, 1 fail.
"""

from __future__ import annotations

import re
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
fails: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(("  ok   " if ok else "  FAIL ") + name + ("" if ok else f" — {detail}"))
    if not ok:
        fails.append(name)


def names(s: str) -> list[str]:
    return re.findall(r"'([a-z0-9-]+)'", s)


def diff(a: set[str], b: set[str]) -> str:
    return f"only in first: {sorted(a - b)}; only in second: {sorted(b - a)}"


schema = (ROOT / "scripts/schema.sql").read_text()
canon: dict[str, list[str]] = {}
for trig in ("decisions_category_check_ins", "decisions_category_check_upd"):
    m = re.search(trig + r".*?NOT IN \((.*?)\);", schema, re.S)
    canon[trig] = names(re.sub(r"--[^\n]*", "", m.group(1))) if m else []
ref = set(canon["decisions_category_check_ins"])
print(f"== schema.sql allowlist: {len(ref)} categories ==")
check("schema.sql: _ins and _upd lists are identical", ref == set(canon["decisions_category_check_upd"]),
      diff(ref, set(canon["decisions_category_check_upd"])))
check("schema.sql: no duplicates", len(ref) == len(canon["decisions_category_check_ins"]))

mig = (ROOT / "scripts/migrate.sh").read_text()
lists = re.findall(r"CREATE TRIGGER decisions_category_check_(ins|upd) .*?NOT IN \((.*?)\); END;", mig)
check("migrate.sh: 2 category triggers (ins + upd, shared by local + turso)", len(lists) == 2, f"found {len(lists)}")
for i, (kind, body) in enumerate(lists):
    check(f"migrate.sh: trigger #{i + 1} ({kind}) matches schema.sql", set(names(body)) == ref,
          diff(set(names(body)), ref))
for m in re.finditer(r"CREATE TRIGGER (?:IF NOT EXISTS )?(\w+) BEFORE INSERT ON \w+ (.*?) END;", mig):
    check(f"migrate.sh: INSERT trigger {m.group(1)} does not reference OLD", "OLD." not in m.group(2))

bf = (ROOT / "scripts/governance-backfill.sh").read_text()
m = re.search(r'CANONICAL_LIST="(.*?)"', bf, re.S)
check("governance-backfill.sh: CANONICAL_LIST matches schema.sql", bool(m) and set(names(m.group(1))) == ref,
      diff(set(names(m.group(1))) if m else set(), ref))

jo = (ROOT / "JUVANT_OS.md").read_text()
m = re.search(r"`category` canonical values: `(.*?)`", jo)
check("JUVANT_OS.md: schema quick reference matches", bool(m) and set(names(m.group(1))) == ref,
      diff(set(names(m.group(1))) if m else set(), ref))
m = re.search(r"decisions_category_check_\*` triggers in scripts/schema.sql\s+\+ scripts/migrate.sh\): (.*?)\.\n", jo, re.S)
prose = set(re.findall(r"[a-z0-9-]+", m.group(1))) if m else set()
check("JUVANT_OS.md: Memory Commit enumeration matches", prose == ref, diff(prose, ref))

print("== every prescribed decisions write is allowlisted ==")
write_form = re.compile(r"(?<!FROM )(?<!WHERE )\bdecisions`?(?: rows?)?,?\s+(?:with\s+)?category\s+`([a-z0-9-]+)`")
docs = sorted((ROOT / "agents").rglob("*.md")) + [ROOT / "JUVANT_OS.md", ROOT / "SYSTEM_INVARIANTS.md"]
missing: dict[str, set[str]] = {}
for f in docs:
    text = re.sub(r"\s+", " ", f.read_text())
    for w in write_form.finditer(text):
        if w.group(1) not in ref:
            missing.setdefault(w.group(1), set()).add(str(f.relative_to(ROOT)))
check("agent templates write only allowlisted categories", not missing,
      "; ".join(f"{c} ({', '.join(sorted(v))})" for c, v in sorted(missing.items())))

print("== the schema enforces it ==")
db = sqlite3.connect(":memory:")
db.executescript(schema)
rejected = []
for c in sorted(ref):
    try:
        db.execute("INSERT INTO decisions (agent, title, category) VALUES ('t', 't', ?)", (c,))
    except sqlite3.DatabaseError:
        rejected.append(c)
check("every allowlisted category is accepted on INSERT", not rejected, str(rejected))
try:
    db.execute("INSERT INTO decisions (agent, title, category) VALUES ('t', 't', 'not-a-category')")
    check("an unknown category is rejected", False, "insert succeeded")
except sqlite3.DatabaseError:
    check("an unknown category is rejected", True)

print(f"\n RESULTS: {'FAIL' if fails else 'PASS'} ({len(fails)} failed)")
sys.exit(1 if fails else 0)
