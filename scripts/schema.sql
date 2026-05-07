-- Juvant OS — Turso (LibSQL) Schema
-- Source of truth: juvantlabs/juvant-os-pm/docs/session-commit-p1.md + p2.md
-- Apply with: ./scripts/migrate.sh
-- One DB per scope: company-<name>, project-<name>
-- Immutable rows: supersession only, no in-place edits (agent_tool_matrix, disclosure_policies)
--
-- Note on journal mode: Turso (LibSQL) uses WAL by default and rejects the
-- `PRAGMA journal_mode=WAL` statement when applied via `turso db shell`. For
-- the local SQLite path (provider=local in .juvant/config.json), the wizard
-- sets WAL via `sqlite3 file.db "PRAGMA journal_mode=WAL;"` outside this file.

-- ─────────────────────────────────────────────
-- CORE
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS agents (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  role                TEXT UNIQUE NOT NULL,
  -- e.g. 'cos' | 'cfo' | 'coo' | 'cto' | 'eng-api' | 'eng-platform'
  name                TEXT,
  -- compiled name e.g. 'Atlas', 'Theos', 'Hephaestus' — from SYSTEM_INVARIANTS.md §2 defaults
  scope               TEXT DEFAULT 'company',
  -- 'company' | 'project'
  project_id          TEXT,
  -- NULL for company-scope; project slug for project-scope
  status              TEXT DEFAULT 'inactive',
  -- 'active' | 'inactive' | 'context-warning' | 'context-critical'
  session_id          TEXT,
  -- Agent SDK session ID for resume
  session_path        TEXT,
  -- local path to session file
  model               TEXT,
  -- 'claude-opus-4-7' | 'claude-sonnet-4-6' | 'claude-haiku-4-5-20251001'
  template_version    TEXT,
  manifesto_status    TEXT DEFAULT 'pending',
  -- 'pending' | 'approved'
  manifesto_tier      INTEGER DEFAULT 2,
  -- 1 = blocking | 2 = async
  manifesto_deadline  DATETIME,
  tier1_bootstrap     INTEGER DEFAULT 0,
  -- 1 = approved via CEO-only bootstrap override (SYSTEM_INVARIANTS.md §1)
  precondition_bypassed TEXT,
  -- NULL | 'bootstrap' | 'project-bootstrap'
  bash_allow          TEXT DEFAULT '[]',
  -- JSON array of allowed first-token Bash binaries for this agent
  -- (handbook ADR 0004 Track 2 / FEAT-018). Populated at company init
  -- from hooks/bash-policy.json baseline; mutated only via
  -- tool-matrix-change decision (CA proposes, CSO reviews, CEO approves).
  -- Empty default '[]' means: no Bash for this agent unless a row in
  -- bash-policy.json grants it. Mirrors bash-policy.json for query speed.
  hired_by            TEXT,
  approved_by         TEXT,
  created_at          DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at          DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS messages (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  from_agent      TEXT NOT NULL,
  to_agent        TEXT NOT NULL,
  type            TEXT NOT NULL,
  -- 'task' | 'deliverable' | 'escalation' | 'ceo_approval' | 'policy_update'
  -- | 'meeting_transcript' | 'meeting_mention' | 'model_override_request'
  content         TEXT NOT NULL,
  priority        TEXT DEFAULT 'normal',
  -- 'critical' | 'high' | 'normal' | 'low'
  status          TEXT DEFAULT 'unread',
  -- 'unread' | 'read' | 'actioned'
  notify_ceo      INTEGER DEFAULT 0,
  ref_id          TEXT,
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
  read_at         DATETIME
);

CREATE TABLE IF NOT EXISTS master_context (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  key             TEXT UNIQUE NOT NULL,
  value           TEXT NOT NULL,
  -- bootstrap_completed_at: set by CEO once all 19 founding agents reach OPERATIONAL_RESTRICTED
  updated_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS session_snapshots (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  agent           TEXT NOT NULL,
  snapshot        TEXT NOT NULL,
  session_id      TEXT,
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- ─────────────────────────────────────────────
-- COMPANY OPS
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS manifests (
  id                      INTEGER PRIMARY KEY AUTOINCREMENT,
  agent                   TEXT NOT NULL,
  content                 TEXT NOT NULL,
  version                 TEXT DEFAULT '1.0',
  status                  TEXT DEFAULT 'pending',
  -- 'pending' | 'approved' | 'rejected'
  tier                    INTEGER DEFAULT 2,
  deadline                DATETIME,
  approved_by             TEXT,
  approved_at             DATETIME,
  tier1_bootstrap         INTEGER DEFAULT 0,
  -- 1 = approved via CEO-only bootstrap override (§1)
  precondition_bypassed   TEXT,
  -- NULL | 'bootstrap' | 'project-bootstrap'
  bootstrap_baseline      INTEGER DEFAULT 0,
  -- 1 = this manifesto was the CSO bootstrap_baseline audit post-bootstrap
  created_at              DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS decisions (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  agent           TEXT NOT NULL,
  title           TEXT NOT NULL,
  category        TEXT,
  -- 'model-override' | 'tool-matrix-change' | 'pr-spec' | 'gh-issue-spec'
  -- | 'gh-project-update-spec' | 'gh-milestone-spec' | 'install-spec'
  -- | 'branch-protection-spec' | 'release-spec' | 'deployment-spec'
  -- | 'secret-rotation-spec' | 'eng-output-held' | 'disclosure-unavailable'
  rationale       TEXT,
  status          TEXT DEFAULT 'proposed',
  -- 'proposed' | 'approved' | 'rejected' | 'executed'
  held_for_fallback INTEGER DEFAULT 0,
  -- 1 = held in VPE buffer during Disclosure Fallback Cascade Tier 4 (§3)
  approved_by     TEXT,
  approved_at     DATETIME,
  executed_by     TEXT,
  -- always COO for spec categories (single-writer §4)
  executed_at     DATETIME,
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS hiring_log (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  role            TEXT NOT NULL,
  requested_by    TEXT NOT NULL,
  rationale       TEXT,
  status          TEXT DEFAULT 'pending',
  -- 'pending' | 'approved' | 'denied'
  approved_by     TEXT,
  approved_at     DATETIME,
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS productivity (
  id                          INTEGER PRIMARY KEY AUTOINCREMENT,
  agent                       TEXT NOT NULL,
  project_id                  TEXT,
  week                        TEXT NOT NULL,
  -- ISO week e.g. '2026-W18'
  tasks_completed             INTEGER DEFAULT 0,
  escalations                 INTEGER DEFAULT 0,
  unnecessary_escalations     INTEGER DEFAULT 0,
  context_impaired_sessions   INTEGER DEFAULT 0,
  -- sessions where context-warning/critical flag was set; excluded from ranking
  tokens_used                 INTEGER DEFAULT 0,
  cost_usd                    REAL DEFAULT 0,
  ranking_score               REAL,
  created_at                  DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS security_audit_log (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  auditor         TEXT NOT NULL,
  -- always 'cso'
  scope           TEXT NOT NULL,
  -- 'company' | project_id
  audit_type      TEXT NOT NULL,
  -- '5-layer' | 'bootstrap_baseline' | 'incident' | 'monthly'
  layer           TEXT,
  -- 'access' | 'secrets' | 'network' | 'code' | 'agents' (for 5-layer)
  finding         TEXT,
  severity        TEXT,
  -- 'P0' | 'P1' | 'P2' | 'info'
  category        TEXT,
  -- 'disclosure-unavailable' | 'unauthorized-write' | 'secret-exposure' | ...
  status          TEXT DEFAULT 'open',
  -- 'open' | 'resolved' | 'accepted'
  bootstrap_baseline INTEGER DEFAULT 0,
  -- 1 = this is the post-bootstrap CSO audit
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
  resolved_at     DATETIME
);

-- ─────────────────────────────────────────────
-- TOOL MATRIX (immutable rows — supersession only)
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS agent_tool_matrix (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  role            TEXT NOT NULL,
  mcp_servers     TEXT,
  -- JSON array e.g. ["turso","github:read","bank:read"]
  -- bank is abstract: bound to concrete provider at company init
  -- COO is the SOLE bearer of github:write (SYSTEM_INVARIANTS.md §4)
  skills          TEXT,
  -- JSON array of skill paths e.g. ["/mnt/skills/public/pdf/SKILL.md"]
  channels        TEXT,
  -- JSON array e.g. ["m365-mail"]
  -- m365-mail receive for cmo is press scope only
  approved_by     TEXT DEFAULT 'ceo',
  version         TEXT,
  superseded_by   INTEGER,
  -- FK to newer row; NULL means current
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- ─────────────────────────────────────────────
-- DISCLOSURE
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS disclosure_policies (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  agent           TEXT NOT NULL,
  counterparty    TEXT,
  -- NULL = applies to all counterparties
  category        TEXT NOT NULL,
  level           TEXT NOT NULL,
  -- 'public' | 'restricted' | 'confidential'
  rationale       TEXT,
  approved_by     TEXT DEFAULT 'ceo',
  -- joint approval required for Universal CONFIDENTIAL edits (§5)
  valid_from      DATETIME DEFAULT CURRENT_TIMESTAMP,
  valid_until     DATETIME,
  superseded_by   INTEGER,
  -- immutable rows: supersession only, no in-place edits
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- ─────────────────────────────────────────────
-- COUNTERPARTIES
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS counterparties (
  id          TEXT PRIMARY KEY,
  -- e.g. 'commercialista-rossi'
  name        TEXT NOT NULL,
  type        TEXT,
  -- 'accountant' | 'legal' | 'partner' | 'investor' | 'press'
  agent_owner TEXT NOT NULL,
  -- which agent manages this relationship
  notes       TEXT
);

CREATE TABLE IF NOT EXISTS counterparty_contacts (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  counterparty_id TEXT NOT NULL,
  email           TEXT UNIQUE NOT NULL,
  name            TEXT,
  role            TEXT
  -- 'primary' | 'cc' | 'delegate'
);

CREATE TABLE IF NOT EXISTS counterparty_routing (
  counterparty    TEXT PRIMARY KEY,
  -- email or domain
  agent_owner     TEXT NOT NULL,
  added_by        TEXT DEFAULT 'ceo',
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS counterparty_history (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  counterparty_id TEXT NOT NULL,
  summary         TEXT NOT NULL,
  -- rolling summary max 2000 chars; compacted by agent when exceeded
  last_contact    DATETIME,
  updated_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS inbound_queue (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  counterparty_id TEXT NOT NULL,
  agent_owner     TEXT NOT NULL,
  content         TEXT NOT NULL,
  confidence      TEXT NOT NULL,
  -- 'whitelisted' | 'unverified' | 'unknown'
  status          TEXT DEFAULT 'pending',
  -- 'pending' | 'processing' | 'done' | 'failed'
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
  picked_up_at    DATETIME,
  completed_at    DATETIME
);

CREATE TABLE IF NOT EXISTS adapter_dead_letters (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  adapter         TEXT NOT NULL,
  -- 'm365-mail' | 'bank' | 'fiscal'
  payload         TEXT NOT NULL,
  error           TEXT,
  retry_count     INTEGER DEFAULT 0,
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
  last_retry      DATETIME
);

-- ─────────────────────────────────────────────
-- KNOWLEDGE & PROJECTS
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS knowledge_base (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  category        TEXT NOT NULL,
  -- 'strategic' | 'technical' | 'skill'
  title           TEXT NOT NULL,
  content         TEXT NOT NULL,
  source_project  TEXT,
  promoted_by     TEXT,
  -- 'chro' | 'ca'
  approved_by     TEXT DEFAULT 'ceo',
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS projects (
  id              TEXT PRIMARY KEY,
  -- project slug e.g. 'hardys'
  name            TEXT NOT NULL,
  db_url          TEXT NOT NULL,
  -- Turso URL for this project's DB
  status          TEXT DEFAULT 'active',
  -- OPERATIONAL lifecycle: 'active' | 'archived'
  -- (separate from maturity_status below — see JUVANT_OS.md § Project maturity status)
  maturity_status TEXT DEFAULT 'incubation'
    CHECK (maturity_status IN ('incubation','preview','general_availability')),
  -- MATURITY tier: 'incubation' | 'preview' | 'general_availability'
  -- Drives agent calibration (CoS suggestion aggressiveness, CMO publication
  -- guard, CFO revenue tagging, CSO audit thresholds). See JUVANT_OS.md.
  maturity_changed_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Append-only history of maturity transitions (promotions and demotions).
-- demotion=1 flagged when new tier is lower than previous tier.
-- Source-of-truth for "Cost report" / Morning Brief change callouts.
CREATE TABLE IF NOT EXISTS project_maturity_history (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id      TEXT NOT NULL,
  from_status     TEXT,
  -- NULL on initial assignment
  to_status       TEXT NOT NULL
    CHECK (to_status IN ('incubation','preview','general_availability')),
  demotion        INTEGER DEFAULT 0,
  -- 1 = transition went down the maturity ladder
  reason          TEXT,
  actor           TEXT,
  -- principal handle (FEAT-022) or 'ceo' fallback
  changed_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_pmh_project_time
  ON project_maturity_history(project_id, changed_at DESC);

-- ─────────────────────────────────────────────
-- AGENT ACTION AUDIT LOG (FEAT-019 / handbook ADR 0004 Track 3)
-- ─────────────────────────────────────────────

-- Append-only log of every tool invocation by every agent. Written by
-- hooks/pre-tool-use.sh BEFORE the tool runs (status='pending') and
-- updated post-execution by post-tool-use hooks (out of scope of v1.0).
-- Reconciliation against `decisions` detects state-fabrication
-- (cover-up failure mode of handbook ADR 0004).
CREATE TABLE IF NOT EXISTS agent_actions_log (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id    TEXT,
  agent         TEXT NOT NULL,
  tool_name     TEXT NOT NULL,
  args_hash     TEXT NOT NULL,
  -- SHA-256 of canonical (sorted-keys) JSON of tool_input.
  -- Full args NOT stored (privacy + size).
  -- (agent, tool_name, args_hash) is the fingerprint for reconciliation.
  result_hash   TEXT,
  -- SHA-256 of canonical-JSON result; NULL on failure or in-flight.
  status        TEXT NOT NULL,
  -- 'pending' | 'success' | 'failure' | 'denied'
  deny_reason   TEXT,
  -- non-NULL when status='denied'. Carries the diagnostic code per
  -- FEAT-025: 'deny:universal:<pattern>' | 'deny:allow-list:<binary>'
  -- | 'deny:no-role' | 'deny:policy-load-failure'.
  escalation_msg_id INTEGER,
  -- FK to messages.id when an allow-list deny opened a
  -- tool_authorization_request (FEAT-025). NULL otherwise.
  started_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
  ended_at      DATETIME
);
CREATE INDEX IF NOT EXISTS idx_actions_log_session
  ON agent_actions_log(session_id, started_at);
CREATE INDEX IF NOT EXISTS idx_actions_log_agent
  ON agent_actions_log(agent, started_at);
CREATE INDEX IF NOT EXISTS idx_actions_log_status
  ON agent_actions_log(status, started_at);

-- ─────────────────────────────────────────────
-- BASH ONE-SHOT GRANTS (FEAT-025)
-- ─────────────────────────────────────────────

-- Time-boxed CEO grant of a single Bash command for a single agent,
-- identified by (agent_role, args_hash). Created when the CEO clicks
-- "One-shot" on a tool_authorization_request Teams card. Consumed
-- on first matching call by hooks/pre-tool-use.sh, then ignored.
-- Default TTL 10 minutes — long enough for the agent to retry,
-- short enough that an unused grant does not linger.
CREATE TABLE IF NOT EXISTS bash_oneshot_grants (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  agent_role        TEXT NOT NULL,
  args_hash         TEXT NOT NULL,
  granted_by        TEXT NOT NULL,
  -- always 'ceo' (only authority allowed to grant)
  granted_at        DATETIME DEFAULT CURRENT_TIMESTAMP,
  expires_at        DATETIME NOT NULL,
  -- granted_at + 10 min by convention
  consumed          INTEGER DEFAULT 0,
  -- 1 = redeemed by a matching hook call
  consumed_at       DATETIME,
  decision_id       INTEGER
  -- FK to decisions.id of category 'tool-oneshot-approval' that
  -- recorded the CEO approval. CSO Layer 5 audit verifies every
  -- grant has a backing decision row (no fabrication).
);
CREATE INDEX IF NOT EXISTS idx_bash_oneshot_lookup
  ON bash_oneshot_grants(agent_role, args_hash, consumed, expires_at);

-- ─────────────────────────────────────────────
-- TOKEN USAGE & COST (FEAT-024)
-- ─────────────────────────────────────────────

-- Per-session and per-subagent-invocation token usage capture.
-- Written by hooks (Stop, SessionEnd, SubagentStop) from the session
-- transcript JSONL. computed_cost_usd is denormalized at write time so
-- historical reports do not drift if model_pricing is updated later.
CREATE TABLE IF NOT EXISTS agent_token_usage (
  id                  TEXT PRIMARY KEY,
  -- uuid
  session_id          TEXT NOT NULL,
  -- Claude Code session uuid
  parent_session_id   TEXT,
  -- subagent → main link; NULL for main session rows
  agent_name          TEXT NOT NULL,
  -- 'main' | 'cco' | 'cfo' | ... matches agents.role + 'main' for top-level
  principal_id        TEXT,
  -- FEAT-022 forward-compat (nullable until multi-principal active)
  project_slug        TEXT,
  -- FEAT-023 forward-compat; NULL for company-scope sessions
  model               TEXT NOT NULL,
  -- 'claude-opus-4-7' | 'claude-sonnet-4-6' | 'claude-haiku-4-5-20251001'
  input_tokens        INTEGER NOT NULL DEFAULT 0,
  output_tokens       INTEGER NOT NULL DEFAULT 0,
  cache_write_tokens  INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens   INTEGER NOT NULL DEFAULT 0,
  started_at          DATETIME NOT NULL,
  ended_at            DATETIME,
  computed_cost_usd   REAL
  -- denormalized snapshot using model_pricing row active at ended_at
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

-- Anthropic published pricing, versioned by effective_from.
-- Adopters refresh this table when Anthropic publishes new prices.
-- Historical agent_token_usage rows are unaffected (cost denormalized).
CREATE TABLE IF NOT EXISTS model_pricing (
  model                       TEXT NOT NULL,
  effective_from              DATE NOT NULL,
  effective_to                DATE,
  -- NULL = currently active row
  input_per_mtok_usd          REAL NOT NULL,
  output_per_mtok_usd         REAL NOT NULL,
  cache_write_per_mtok_usd    REAL NOT NULL,
  cache_read_per_mtok_usd     REAL NOT NULL,
  PRIMARY KEY (model, effective_from)
);

-- Initial seed — placeholder values. ADOPTERS MUST verify against
-- https://www.anthropic.com/pricing at install time and UPDATE rows where
-- the published price differs. The values below are best-effort drafts
-- and will produce inaccurate cost figures if not refreshed.
-- Refresh procedure: see JUVANT_OS.md § Cost report — pricing refresh.
INSERT OR IGNORE INTO model_pricing
  (model, effective_from, effective_to,
   input_per_mtok_usd, output_per_mtok_usd,
   cache_write_per_mtok_usd, cache_read_per_mtok_usd)
VALUES
  ('claude-opus-4-7',           '2026-01-01', NULL, 15.00, 75.00, 18.75, 1.50),
  ('claude-sonnet-4-6',         '2026-01-01', NULL,  3.00, 15.00,  3.75, 0.30),
  ('claude-haiku-4-5-20251001', '2026-01-01', NULL,  1.00,  5.00,  1.25, 0.10);

-- ─────────────────────────────────────────────
-- PORTAL
-- ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS portal_offline_messages (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  agent           TEXT NOT NULL,
  counterparty    TEXT NOT NULL,
  content         TEXT NOT NULL,
  status          TEXT DEFAULT 'pending',
  -- 'pending' | 'processed'
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
  processed_at    DATETIME
);
