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
    # Knowledge & projects
    "knowledge_base", "projects", "project_maturity_history",
    # FEAT-019
    "agent_actions_log",
    # FEAT-025
    "bash_oneshot_grants",
    # FEAT-024
    "agent_token_usage", "model_pricing",
    # Portal
    "portal_offline_messages",
}

EXPECTED_INDEXES = {
    "idx_pmh_project_time",
    "idx_actions_log_session",
    "idx_actions_log_agent",
    "idx_actions_log_status",
    "idx_bash_oneshot_lookup",
    "idx_token_usage_time",
    "idx_token_usage_agent",
    "idx_token_usage_principal",
    "idx_token_usage_project",
    "idx_token_usage_session",
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
# Approximate v0.4 shape: just the projects + agents tables, pre-FEAT-023/024/025.
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
print("\n===================================================")
total = passes + len(fails)
print(f"Total: {total} · Passed: {passes} · Failed: {len(fails)}")
sys.exit(1 if fails else 0)
