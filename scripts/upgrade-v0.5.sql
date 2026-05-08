-- One-time upgrade for company DBs created before FEAT-023 / FEAT-024.
-- Apply with: turso db shell <url> < scripts/upgrade-v0.5.sql
-- (or: sqlite3 <file.db> < scripts/upgrade-v0.5.sql for local-mode adopters)
--
-- Safe to re-run only on DBs that have NOT yet had this script applied.
-- SQLite ALTER TABLE ADD COLUMN is NOT idempotent — re-running this script
-- on an already-upgraded DB will error on the ALTERs. The CREATE TABLE
-- and INSERT OR IGNORE statements ARE idempotent.
--
-- Recommended path for adopters who are unsure: take a backup first,
-- run the script, observe the ALTER errors (benign if columns exist),
-- and verify the resulting schema with `.schema projects` and
-- `.schema agent_token_usage`.

-- ─────────────────────────────────────────────
-- FEAT-023 — projects.maturity_status
-- ─────────────────────────────────────────────

-- SQLite ALTER TABLE rejects non-constant DEFAULT (CURRENT_TIMESTAMP).
-- The corresponding columns in scripts/schema.sql carry the live default;
-- here we ADD with a NULL default and backfill below.

ALTER TABLE projects
  ADD COLUMN maturity_status TEXT DEFAULT 'incubation'
  CHECK (maturity_status IN ('incubation','preview','general_availability'));

ALTER TABLE projects
  ADD COLUMN maturity_changed_at DATETIME;

UPDATE projects
   SET maturity_changed_at = CURRENT_TIMESTAMP
 WHERE maturity_changed_at IS NULL;

CREATE TABLE IF NOT EXISTS project_maturity_history (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id      TEXT NOT NULL,
  from_status     TEXT,
  to_status       TEXT NOT NULL
    CHECK (to_status IN ('incubation','preview','general_availability')),
  demotion        INTEGER DEFAULT 0,
  reason          TEXT,
  actor           TEXT,
  changed_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_pmh_project_time
  ON project_maturity_history(project_id, changed_at DESC);

-- Seed an initial history row for every existing project.
-- The CEO can re-run "Promote project <slug> to <tier>" afterwards to set
-- the actual current tier; this row only records the default assignment.
INSERT INTO project_maturity_history (project_id, from_status, to_status, actor, reason)
SELECT id, NULL, 'incubation', 'ceo', 'upgrade-v0.5 default backfill'
  FROM projects
 WHERE id NOT IN (SELECT project_id FROM project_maturity_history);

-- ─────────────────────────────────────────────
-- FEAT-018 / FEAT-019 — agent action log + Bash policy
-- ─────────────────────────────────────────────

-- agents.bash_allow column (FEAT-018 / handbook ADR 0004 Track 2).
-- Mirrors hooks/bash-policy.json entries for the agent at company-init time.
-- Default '[]' = no Bash; populated at company-init from baseline policy.
ALTER TABLE agents
  ADD COLUMN bash_allow TEXT DEFAULT '[]';

-- agent_actions_log (FEAT-019 / handbook ADR 0004 Track 3).
CREATE TABLE IF NOT EXISTS agent_actions_log (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id        TEXT,
  agent             TEXT NOT NULL,
  tool_name         TEXT NOT NULL,
  args_hash         TEXT NOT NULL,
  result_hash       TEXT,
  status            TEXT NOT NULL,
  deny_reason       TEXT,
  started_at        DATETIME DEFAULT CURRENT_TIMESTAMP,
  ended_at          DATETIME
);
CREATE INDEX IF NOT EXISTS idx_actions_log_session
  ON agent_actions_log(session_id, started_at);
CREATE INDEX IF NOT EXISTS idx_actions_log_agent
  ON agent_actions_log(agent, started_at);
CREATE INDEX IF NOT EXISTS idx_actions_log_status
  ON agent_actions_log(status, started_at);

-- FEAT-025 (escalate-deny + bash_oneshot_grants) is deferred to v1.1 —
-- intentionally omitted from this script. When FEAT-025 lands, a
-- successor upgrade script will add the bash_oneshot_grants table and
-- the agent_actions_log.escalation_msg_id column.

-- ─────────────────────────────────────────────
-- FEAT-024 — token usage + model pricing
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS agent_token_usage (
  id                  TEXT PRIMARY KEY,
  session_id          TEXT NOT NULL,
  parent_session_id   TEXT,
  agent_name          TEXT NOT NULL,
  principal_id        TEXT,
  project_slug        TEXT,
  model               TEXT NOT NULL,
  input_tokens        INTEGER NOT NULL DEFAULT 0,
  output_tokens       INTEGER NOT NULL DEFAULT 0,
  cache_write_tokens  INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens   INTEGER NOT NULL DEFAULT 0,
  started_at          DATETIME NOT NULL,
  ended_at            DATETIME,
  computed_cost_usd   REAL
);
CREATE INDEX IF NOT EXISTS idx_token_usage_time
  ON agent_token_usage(ended_at DESC);
CREATE INDEX IF NOT EXISTS idx_token_usage_agent
  ON agent_token_usage(agent_name, ended_at DESC);
CREATE INDEX IF NOT EXISTS idx_token_usage_principal
  ON agent_token_usage(principal_id, ended_at DESC);
CREATE INDEX IF NOT EXISTS idx_token_usage_project
  ON agent_token_usage(project_slug, ended_at DESC);
CREATE INDEX IF NOT EXISTS idx_token_usage_session
  ON agent_token_usage(session_id);

CREATE TABLE IF NOT EXISTS model_pricing (
  model                       TEXT NOT NULL,
  effective_from              DATE NOT NULL,
  effective_to                DATE,
  input_per_mtok_usd          REAL NOT NULL,
  output_per_mtok_usd         REAL NOT NULL,
  cache_write_per_mtok_usd    REAL NOT NULL,
  cache_read_per_mtok_usd     REAL NOT NULL,
  PRIMARY KEY (model, effective_from)
);

INSERT OR IGNORE INTO model_pricing
  (model, effective_from, effective_to,
   input_per_mtok_usd, output_per_mtok_usd,
   cache_write_per_mtok_usd, cache_read_per_mtok_usd)
VALUES
  ('claude-opus-4-7',           '2026-01-01', NULL, 15.00, 75.00, 18.75, 1.50),
  ('claude-sonnet-4-6',         '2026-01-01', NULL,  3.00, 15.00,  3.75, 0.30),
  ('claude-haiku-4-5-20251001', '2026-01-01', NULL,  1.00,  5.00,  1.25, 0.10);

-- ─────────────────────────────────────────────
-- v0.6.1 — security_audit_log.session_id (CSO Layer 5 orphan-audit
-- detection; closes the cover-up failure mode surfaced by the Gamma
-- Corp testco run on 2026-05-08). Backfilling existing rows is not
-- meaningful — the column is for forensic correlation of NEW CSO
-- audit rows with their originating Task subagent invocation.
-- ─────────────────────────────────────────────

ALTER TABLE security_audit_log
  ADD COLUMN session_id TEXT;
