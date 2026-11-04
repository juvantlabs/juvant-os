#!/usr/bin/env python3
"""
tests/schema/test-template-columns.py — agent templates vs the real schema (BUG-074).

Agent templates tell agents which tables and columns to use. When a name doesn't
exist the write fails or the read returns nothing, and the agent's memory step
silently stops working. The checks read the forms templates use:
  INSERT INTO t (a, b='x'), t(a, b), t.col, FROM t WHERE col = ...,
  INSERT INTO / UPDATE / FROM / JOIN <name>
against scripts/schema.sql, loaded into a real database. Also rejects NOW(), which
SQLite doesn't have, and status='open' on decisions, which is outside its vocabulary
(`operational-violation` rows are the documented exception).

KNOWN_GAPS is a ratchet: gaps already tracked in BUG-074 and not fixed yet. A new
gap fails; so does an entry that no longer occurs, so the list can only shrink.

Run: python3 tests/schema/test-template-columns.py   Exit: 0 pass, 1 fail.
"""

from __future__ import annotations

import re
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Words a template writes after `table.` or in `table (…)` that are prose, not columns.
PROSE = {
    "counterparties.analysts", "counterparties.clients", "counterparties.counsel",
    "counterparties.courts", "counterparties.influencers", "counterparties.journalists",
    "counterparties.notai", "counterparties.partners", "counterparties.podcasters",
    "counterparties.prospects", "counterparties.regulators",
    "counterparty_history.prospects", "decisions.deployment", "decisions.incident",
    "decisions.since",
    "manifests.installed_", "manifests.restricted", "projects.monthly",
}

KNOWN_GAPS: set[str] = {
    "agents.cfo", "agents.last_bank_sync", "agents.last_deadline_sweep",
    "counterparties.consent_pointer",
    "decisions.reviewed_by",
    "knowledge_base.authored_by", "knowledge_base.retracted_at",
    "knowledge_base.status", "knowledge_base.tags",
    "manifests.scope", "manifests.tier1_chro_approved_at", "manifests.tier1_cto_approved_at",
    "manifests.upstream_breaking", "manifests.upstream_changelog", "manifests.upstream_version",
    "messages.tools_used",
}

SQLWORDS = {"select", "from", "where", "and", "or", "not", "null", "is", "in", "values",
            "set", "order", "by", "limit", "group", "desc", "asc", "like", "as", "on",
            "join", "exists", "datetime", "count", "case", "when", "then", "else", "end",
            "distinct", "max", "min"}
FILE_SUFFIXES = {"md", "sh", "sql", "json"}


def scan(text: str, objs: set[str], cols: dict[str, set[str]]) -> set[str]:
    alt = "|".join(sorted(map(re.escape, objs), key=len, reverse=True))
    found: set[str] = set()
    for line in text.splitlines():
        if "NOW()" in line:
            found.add("sql:NOW()")
        if re.search(r"\bdecisions WHERE .*\bstatus\s*=\s*'open'", line) and "operational-violation" not in line:
            found.add("decisions.status='open'")
        for m in re.finditer(r"\b(?:INSERT INTO|UPDATE|FROM|JOIN)\s+([a-z][a-z0-9_]*)\b", line):
            t = m.group(1)
            if t not in objs and "_" in t and not t.startswith(("project_", "sqlite_")):
                found.add(t)
        for m in re.finditer(rf"\b({alt})\s*\(([^()]*)\)", line):
            t = m.group(1)
            for raw in m.group(2).split(","):
                c = raw.strip().split("=")[0].strip().strip("`")
                if re.fullmatch(r"[a-z][a-z0-9_]*", c) and c not in cols[t] and c not in SQLWORDS:
                    found.add(f"{t}.{c}")
        for m in re.finditer(rf"\b({alt})\.([a-z][a-z0-9_]*)\b", line):
            t, c = m.group(1), m.group(2)
            if c not in cols[t] and c not in FILE_SUFFIXES:
                found.add(f"{t}.{c}")
        for m in re.finditer(rf"\bFROM\s+({alt})\b(?:\s+[a-z]+)?\s+WHERE\s+(.*)", line):
            t = m.group(1)
            for c in re.findall(r"\b([a-z][a-z0-9_]*)\s*(?:=|!=|<=|>=|<|>|\bIN\b|\bIS\b|\bLIKE\b)", m.group(2)):
                if c not in cols[t] and c not in SQLWORDS:
                    found.add(f"{t}.{c}")
        for m in re.finditer(rf"(?:^|[`\s])({alt})\s+WHERE\s+(.*)", line):
            t = m.group(1)
            for c in re.findall(r"\b([a-z][a-z0-9_]*)\s*(?:=|!=|<=|>=|<|>|\bIN\b|\bIS\b|\bLIKE\b)", m.group(2).split("`")[0]):
                if c not in cols[t] and c not in SQLWORDS:
                    found.add(f"{t}.{c}")
    return found


def main() -> int:
    db = sqlite3.connect(":memory:")
    db.executescript((ROOT / "scripts/schema.sql").read_text())
    objs = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type IN ('table','view')")}
    objs = {o for o in objs if not o.startswith("sqlite_")}
    cols = {t: {r[1] for r in db.execute(f'PRAGMA table_info("{t}")')} for t in objs}

    # The scanner itself: a known-bad line must be caught, a good one must not.
    bad = "`INSERT INTO messages (agent='x', content)` and `messages WHERE agent='x'` and `no_such_table` FROM no_such_table"
    good = "`INSERT INTO messages (from_agent='x', to_agent, content)` and `session_snapshots WHERE agent='x'`"
    fails = 0
    if scan(bad, objs, cols) != {"messages.agent", "no_such_table"}:
        print(f"  FAIL scanner self-check: {sorted(scan(bad, objs, cols))}")
        fails += 1
    if scan(good, objs, cols):
        print(f"  FAIL scanner self-check, false positive: {sorted(scan(good, objs, cols))}")
        fails += 1

    where: dict[str, set[str]] = {}
    for p in sorted((ROOT / "agents").rglob("*.md")):
        for ref in scan(p.read_text(), objs, cols):
            where.setdefault(ref, set()).add(p.stem)

    found = set(where) - PROSE
    for ref in sorted(found - KNOWN_GAPS):
        print(f"  FAIL not in the schema: {ref} ({', '.join(sorted(where[ref]))})")
        fails += 1
    for ref in sorted(KNOWN_GAPS - found):
        print(f"  FAIL fixed, remove it from KNOWN_GAPS: {ref}")
        fails += 1
    print(f"  {len(where)} references outside the schema; {len(KNOWN_GAPS)} tracked in BUG-074")
    print(f"\n RESULTS: {'PASS' if not fails else 'FAIL'} ({fails} failed)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
