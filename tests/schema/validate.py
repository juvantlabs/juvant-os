#!/usr/bin/env python3
"""
tests/schema/validate.py — Static + dynamic checks against scripts/schema.sql.

Run: python3 tests/schema/validate.py
Exit: 0 on all pass, 1 on any failure.

Checks:
  1. Schema applies to a clean SQLite DB without errors.
  2. All expected tables and indexes are present.
  3. CHECK constraints reject known-invalid values (negative test).
  4. Seed rows in model_pricing exist (FEAT-024).
  5. Default values resolve correctly on plain INSERTs.
  6. The upgrade-v0.5.sql script applies cleanly to a v0.4-shape DB.

Does NOT cover behavior of hooks/seed paths — see tests/hooks/.
"""

from __future__ import annotations

import re
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "scripts" / "schema.sql"
UPGRADE_PATH = ROOT / "scripts" / "upgrade-v0.5.sql"

EXPECTED_TABLES = {
    # Core
    "agents", "messages", "master_context", "session_snapshots",
    # Company ops
    "manifests", "decisions", "hiring_log", "productivity",
    "security_audit_log",
    # Tool matrix
    "agent_tool_matrix",
    # Disclosure
    "disclosure_policies",
    # Counterparties
    "counterparties", "counterparty_contacts", "counterparty_routing",
    "counterparty_history", "inbound_queue", "adapter_dead_letters",
    # ADR 0024 — outbound action queue (outbox)
    "outbox",
    # Knowledge & projects
    "knowledge_base", "projects", "project_maturity_history",
    # FEAT-019 / handbook ADR 0004 Track 3
    "agent_actions_log",
    # ADR 0004 Track 4 (kill switch / observability)
    "agent_kill_switch",
    # FEAT-024
    "agent_token_usage", "model_pricing",
    # Portal
    "portal_offline_messages",
    # R5c — append-only audit events (decisions#303/#308)
    "audit_events",
}

EXPECTED_INDEXES = {
    "idx_pmh_project_time",
    "idx_actions_log_session",
    "idx_actions_log_agent",
    "idx_actions_log_status",
    "idx_token_usage_time",
    "idx_token_usage_agent",
    "idx_token_usage_principal",
    "idx_token_usage_project",
    "idx_token_usage_session",
    "idx_outbox_drain",
    "idx_outbox_scope",
    "idx_audit_events_target",
}


passes = 0
fails: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    global passes
    if ok:
        passes += 1
        print(f"  PASS: {name}")
    else:
        msg = f"  FAIL: {name}"
        if detail:
            msg += f"\n    {detail}"
        print(msg)
        fails.append(name)


def fresh_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(":memory:")
    conn.executescript(SCHEMA_PATH.read_text())
    return conn


# ─────────────────────────────────────────────
print("=== schema applies cleanly ===")
# ─────────────────────────────────────────────
try:
    fresh_conn().close()
    check("schema.sql executes without error", True)
except sqlite3.Error as e:
    check("schema.sql executes without error", False, str(e))

# ─────────────────────────────────────────────
print("\n=== expected tables present ===")
# ─────────────────────────────────────────────
conn = fresh_conn()
tables = {
    r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    )
}
missing = EXPECTED_TABLES - tables
check(
    f"all {len(EXPECTED_TABLES)} expected tables exist",
    not missing,
    f"missing: {sorted(missing)}" if missing else "",
)

# ─────────────────────────────────────────────
print("\n=== expected indexes present ===")
# ─────────────────────────────────────────────
indexes = {
    r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='index'"
    )
}
missing_idx = EXPECTED_INDEXES - indexes
check(
    f"all {len(EXPECTED_INDEXES)} expected indexes exist",
    not missing_idx,
    f"missing: {sorted(missing_idx)}" if missing_idx else "",
)

# ─────────────────────────────────────────────
print("\n=== CHECK constraints reject bad data ===")
# ─────────────────────────────────────────────

# projects.maturity_status — must be in enum.
conn.execute(
    "INSERT INTO projects (id, name, db_url, maturity_status) "
    "VALUES ('p1', 'Project 1', 'libsql://x', 'incubation')"
)
ok = False
try:
    conn.execute(
        "INSERT INTO projects (id, name, db_url, maturity_status) "
        "VALUES ('p2', 'Project 2', 'libsql://x', 'foo')"
    )
except sqlite3.IntegrityError:
    ok = True
check("projects.maturity_status rejects 'foo'", ok)

# project_maturity_history.to_status — must be in enum.
ok = False
try:
    conn.execute(
        "INSERT INTO project_maturity_history "
        "(project_id, to_status) VALUES ('p1', 'bar')"
    )
except sqlite3.IntegrityError:
    ok = True
check("project_maturity_history.to_status rejects 'bar'", ok)

# ─────────────────────────────────────────────
print("\n=== model_pricing seed present (FEAT-024) ===")
# ─────────────────────────────────────────────
expected_models = {
    "claude-opus-4-7",
    "claude-sonnet-4-6",
    "claude-haiku-4-5-20251001",
}
seen = {
    r[0] for r in conn.execute("SELECT model FROM model_pricing")
}
missing_models = expected_models - seen
check(
    "all 3 baseline models seeded",
    not missing_models,
    f"missing: {sorted(missing_models)}" if missing_models else "",
)

# ─────────────────────────────────────────────
print("\n=== defaults resolve ===")
# ─────────────────────────────────────────────
conn.execute("INSERT INTO projects (id, name, db_url) VALUES ('p3', 'P3', 'x')")
row = conn.execute(
    "SELECT status, maturity_status FROM projects WHERE id='p3'"
).fetchone()
check(
    "projects defaults: status='active', maturity_status='incubation'",
    row == ("active", "incubation"),
    f"got {row}",
)

conn.execute("INSERT INTO agents (role) VALUES ('test-role')")
row = conn.execute(
    "SELECT bash_allow, status FROM agents WHERE role='test-role'"
).fetchone()
check(
    "agents defaults: bash_allow='[]', status='inactive'",
    row == ("[]", "inactive"),
    f"got {row}",
)

conn.close()

# ─────────────────────────────────────────────
print("\n=== upgrade-v0.5.sql applies to a v0.4-shape DB ===")
# ─────────────────────────────────────────────
upgrade_conn = sqlite3.connect(":memory:")
# Approximate v0.4 shape: just the projects + agents + security_audit_log
# tables, pre-FEAT-023/024/025. The security_audit_log table existed in
# v0.4 (5-layer audit) — its session_id column is added by the v0.6.1
# migration to support CSO Layer 5 orphan-audit detection.
upgrade_conn.executescript(
    """
    CREATE TABLE projects (
      id          TEXT PRIMARY KEY,
      name        TEXT NOT NULL,
      db_url      TEXT NOT NULL,
      status      TEXT DEFAULT 'active',
      created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
    );
    INSERT INTO projects (id, name, db_url) VALUES ('legacy', 'Legacy', 'libsql://l');
    CREATE TABLE agents (
      id    INTEGER PRIMARY KEY AUTOINCREMENT,
      role  TEXT UNIQUE NOT NULL
    );
    INSERT INTO agents (role) VALUES ('legacy-agent');
    CREATE TABLE security_audit_log (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      auditor         TEXT NOT NULL,
      scope           TEXT NOT NULL,
      audit_type      TEXT NOT NULL,
      created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
    );
    """
)
try:
    upgrade_conn.executescript(UPGRADE_PATH.read_text())
    check("upgrade-v0.5.sql applies", True)
except sqlite3.Error as e:
    check("upgrade-v0.5.sql applies", False, str(e))

# Verify the legacy project got an initial maturity_history backfill row.
backfill = upgrade_conn.execute(
    "SELECT COUNT(*) FROM project_maturity_history "
    "WHERE project_id='legacy' AND to_status='incubation'"
).fetchone()[0]
check("upgrade backfills project_maturity_history for existing project", backfill == 1)

upgrade_conn.close()

# ─────────────────────────────────────────────
# decisions.category allowlist consistency (BUG-063). The category-check trigger
# enumeration is duplicated across scripts/schema.sql (INS + UPD triggers) and
# scripts/migrate.sh (the DROP+CREATE patch pairs, ×2 for local + turso). They
# MUST enumerate the identical value set — a drift silently aborts writers whose
# category exists in one surface but not the enforcing one (this class has bitten
# twice: BUG-055 turso allow-list, BUG-063 CSO categories).
print("\n=== decisions.category allowlist consistency (BUG-063) ===")
_cat_re = re.compile(r"NEW\.category NOT IN \((.*?)\)", re.S)
_val_re = re.compile(r"'([a-z][a-z-]*)'")


def _cat_sets(text: str) -> list[frozenset[str]]:
    return [frozenset(_val_re.findall(m.group(1))) for m in _cat_re.finditer(text)]


_schema_sets = _cat_sets(SCHEMA_PATH.read_text())
_migrate_sets = _cat_sets((ROOT / "scripts" / "migrate.sh").read_text())
_all_sets = _schema_sets + _migrate_sets
check(
    "found the category enumerations (schema.sql ×2, migrate.sh ×2+)",
    len(_schema_sets) == 2 and len(_migrate_sets) >= 2,
    f"schema={len(_schema_sets)} migrate={len(_migrate_sets)}",
)
_canon = _schema_sets[0] if _schema_sets else frozenset()
_drift = [sorted(s ^ _canon) for s in _all_sets if s != _canon]
check(
    "every category enumeration agrees (schema.sql ⇄ migrate.sh, INS ⇄ UPD)",
    all(s == _canon for s in _all_sets),
    f"drift vs schema INS: {_drift}",
)
_required = {"system-audit", "incident-response", "security-remediation"}
check(
    "CSO-required categories present (system-audit/incident-response/security-remediation)",
    _required <= _canon,
    f"missing: {sorted(_required - _canon)}",
)

# ─────────────────────────────────────────────
# R5b/R5c audit-immutability DDL consistency (decisions#303/#308). Every
# trigger/view of the AUDIT IMMUTABILITY section of schema.sql must be
# re-applied by migrate.sh's shared R5_AUDIT_PATCHES array (DROP+CREATE) with
# an IDENTICAL body — otherwise an existing DB keeps a stale guard (or none),
# the drift class BUG-055/BUG-063 already hit for the category allowlist.
print("\n=== R5b/R5c audit-immutability DDL consistency (schema.sql ⇄ migrate.sh) ===")


def _norm_sql(s: str) -> str:
    s = "\n".join(re.sub(r"--.*$", "", ln) for ln in s.splitlines())
    s = re.sub(r"\s+", " ", s).strip()
    s = re.sub(r"\s*([(),;=<>])\s*", r"\1", s)
    return s.replace("IF NOT EXISTS ", "")


def _r5_objects(text: str) -> dict[str, str]:
    one = re.sub(r"\s+", " ", "\n".join(re.sub(r"--.*$", "", ln) for ln in text.splitlines()))
    out: dict[str, str] = {}
    for m in re.finditer(r"CREATE TRIGGER (?:IF NOT EXISTS )?(\w+) (.*? END;)", one):
        out[m.group(1)] = _norm_sql(f"CREATE TRIGGER {m.group(1)} {m.group(2)}")
    for m in re.finditer(r"CREATE VIEW (?:IF NOT EXISTS )?(\w+) (AS .*?;)", one):
        out[m.group(1)] = _norm_sql(f"CREATE VIEW {m.group(1)} {m.group(2)}")
    return out


_schema_txt = SCHEMA_PATH.read_text()
_marker = "CREATE TABLE IF NOT EXISTS audit_events"
_r5_schema = _r5_objects(_schema_txt[_schema_txt.index(_marker):]) if _marker in _schema_txt else {}
_mig_txt = (ROOT / "scripts" / "migrate.sh").read_text()
_m = re.search(r"\nR5_AUDIT_PATCHES=\((.*?)\n\)\n", _mig_txt, re.S)
_r5_mig = _r5_objects(_m.group(1)) if _m else {}
check(
    "schema.sql AUDIT IMMUTABILITY section + migrate.sh R5_AUDIT_PATCHES found",
    bool(_r5_schema) and bool(_r5_mig),
    f"schema objects={len(_r5_schema)} migrate objects={len(_r5_mig)}",
)
check(
    "same R5 trigger/view set in schema.sql and migrate.sh",
    set(_r5_schema) == set(_r5_mig),
    f"only schema: {sorted(set(_r5_schema) - set(_r5_mig))} only migrate: {sorted(set(_r5_mig) - set(_r5_schema))}",
)
_r5_drift = sorted(n for n in _r5_schema if n in _r5_mig and _r5_schema[n] != _r5_mig[n])
check("every R5 trigger/view body identical (schema.sql ⇄ migrate.sh)", not _r5_drift, f"drift: {_r5_drift}")
_r5_drops = set(re.findall(r'"DROP (?:TRIGGER|VIEW) IF EXISTS (\w+);"', _m.group(1) if _m else ""))
check(
    "migrate.sh DROPs every R5 object before re-CREATE",
    _r5_drops == set(_r5_mig),
    f"missing DROP: {sorted(set(_r5_mig) - _r5_drops)}",
)
_r5_uses = _mig_txt.count('"${R5_AUDIT_PATCHES[@]}"')
check(
    "both migrate branches (local + turso) apply R5_AUDIT_PATCHES",
    _r5_uses == 2,
    f"found {_r5_uses} use(s)",
)
_conn = fresh_conn()
_live = {r[0] for r in _conn.execute("SELECT name FROM sqlite_master WHERE type IN ('trigger','view')")}
_conn.close()
check(
    "every R5 object exists in a fresh schema.sql DB",
    set(_r5_schema) <= _live,
    f"missing: {sorted(set(_r5_schema) - _live)}",
)

# ─────────────────────────────────────────────
print("\n===================================================")
total = passes + len(fails)
print(f"Total: {total} · Passed: {passes} · Failed: {len(fails)}")
sys.exit(1 if fails else 0)
