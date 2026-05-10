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
  -- e.g. 'cos' | 'cfo' | 'coo' | 'cto' | 'eng-api'
  name                TEXT,
  -- compiled name e.g. 'Atlas', 'Theos', 'Coo' — from SYSTEM_INVARIANTS.md §2 defaults
  scope               TEXT DEFAULT 'company',
  -- 'company' | 'project'
  project_id          TEXT,
  -- NULL for company-scope; project slug for project-scope (e.g. 'hardys')
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
  hired_by            TEXT,
  approved_by         TEXT,
  bash_allow          TEXT DEFAULT '[]',
  -- JSON array mirror of hooks/bash-policy.json agent_allow[<role>] for
  -- query speed (handbook ADR 0004 Track 2). Populated at company init
  -- from baseline policy; mutated only via tool-matrix-change decision.
  -- Empty default '[]' means: no Bash for this agent unless granted.
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
  session_id      TEXT,
  -- Claude Code session_id of the CSO subagent invocation that produced
  -- this row. NULL is permitted for legacy rows but flagged by CSO Layer 5
  -- (orphan-audit detection — see agents/company/cso.md §11). New rows
  -- written by the CSO subagent capture the session_id from the event
  -- payload and use it to cross-reference agent_actions_log.tool_name='Task'
  -- entries; rows lacking this correlation are treated as forensically
  -- suspect (handbook ADR 0004 cover-up failure mode #6).
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
  -- v0.8.0 (ADR 0014 §4): single-writer-per-scope. eng-platform is
  -- the SOLE bearer of github:write at company scope; each project's
  -- eng-lead is the sole bearer at that project's scope (project
  -- DBs hold their own rows). Cross-scope writes are forbidden.
  skills          TEXT,
  -- JSON array of skill paths e.g. ["/mnt/skills/public/pdf/SKILL.md"]
  channels        TEXT,
  -- JSON array e.g. ["m365-mail"]
  -- m365-mail receive for cmo is press scope only
  approved_by     TEXT DEFAULT 'ceo',
  version         TEXT,
  superseded_by   INTEGER,
  -- FK to newer row; NULL means current. -1 means "superseded at
  -- migration time without a successor row pointer" (e.g. role
  -- removed in a version transition).
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- ─────────────────────────────────────────────
-- ROLE ALIASES — audit-time joins for renamed roles (ADR 0014 §7)
-- ─────────────────────────────────────────────
-- Populated by scripts/migrate.sh during version-pair migrations
-- (e.g. v0.7→v0.8 renames ca→cto, project cto→pca, coo→eng-lead, etc.).
-- New forks bootstrap with this table empty; only adopters that
-- migrate from a prior version populate rows here. CSO Layer 5
-- audits join historical rows in manifests/decisions/agent_actions_log/
-- inbound_queue/security_audit_log against this alias table when
-- reconciling activity-by-role across version boundaries.

CREATE TABLE IF NOT EXISTS role_aliases (
  old_role               TEXT NOT NULL,
  new_role               TEXT NOT NULL,
  scope                  TEXT,
  -- 'company' | 'project' | 'cross-scope' (e.g. vpe project→company-optional)
  introduced_in_version  TEXT,
  notes                  TEXT,
  PRIMARY KEY (old_role, new_role, scope)
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
  -- 'strategic' | 'technical' | 'skill' | 'research'
  title           TEXT NOT NULL,
  content         TEXT NOT NULL,
  source_project  TEXT,
  -- abstract project slug — 'hardys', etc.
  source_ref      TEXT,
  -- canonical pointer to the originating artifact:
  --   issue:  '<org>/<repo>#<num>'  e.g. 'juvantio/hardys-pm#76'
  --   file:   '<org>/<repo>/<path>' e.g. 'juvantio/hardys-pm/docs/decisions/ADR-007'
  --   doc:    '<org>/<repo>/<path>' e.g. 'juvantio/hardys-pm/docs/analysis/llm-evaluation-2026-alpha'
  -- helpers/kb-coverage.sh diffs canonical source list against
  -- DISTINCT source_ref to surface gaps. Per OP-007 + handbook ADR
  -- 0004 (audit-reconcile pattern).
  promoted_by     TEXT,
  -- 'chro' | 'ca' | 'cro'
  approved_by     TEXT DEFAULT 'ceo',
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Idempotent migration (existing DBs migrating from pre-source_ref):
-- SQLite ADD COLUMN is non-idempotent — wrap with || true if scripting.
--   ALTER TABLE knowledge_base ADD COLUMN source_ref TEXT;

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
  -- guard, CFO revenue tagging, CSO audit thresholds). See JUVANT_OS.md
  -- § Project maturity status (FEAT-023).
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

-- ─────────────────────────────────────────────
-- AGENT ACTION GUARDRAILS (handbook ADR 0004)
-- ─────────────────────────────────────────────
-- Append-only audit log of every tool call by every agent. Written
-- by PreToolUse + PostToolUse hooks BEFORE the agent has a chance
-- to write anywhere else. Agents have READ-ONLY convention on this
-- table — never INSERT / UPDATE / DELETE from agent prompts.
-- Reconciliation against decisions detects cover-up (failure mode #6
-- of ADR 0004 — Replit-style fabrication of state).

CREATE TABLE IF NOT EXISTS agent_actions_log (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id    TEXT,
  agent         TEXT NOT NULL,
  tool_name     TEXT NOT NULL,
  args_hash     TEXT NOT NULL,
  -- SHA-256 of canonical-JSON args; full args NOT stored
  -- (privacy + size). args_hash + tool_name + agent is the
  -- fingerprint used for reconciliation.
  result_hash   TEXT,
  -- SHA-256 of canonical-JSON result; NULL on failure or in-flight.
  status        TEXT NOT NULL,
  -- 'pending' | 'success' | 'failure' | 'denied'
  deny_reason   TEXT,
  -- non-NULL when status='denied' (Track 2 deny-list match,
  -- per-agent allow-list miss, or other PreToolUse veto).
  started_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
  ended_at      DATETIME
);

CREATE INDEX IF NOT EXISTS idx_actions_log_session
  ON agent_actions_log(session_id, started_at);
CREATE INDEX IF NOT EXISTS idx_actions_log_agent
  ON agent_actions_log(agent, started_at);
CREATE INDEX IF NOT EXISTS idx_actions_log_status
  ON agent_actions_log(status, started_at);

-- Single-row global kill switch. session-start.sh checks at boot
-- and exits if active=1 AND (affected_agents IS NULL OR ROLE in
-- affected_agents JSON array). Set/cleared via
-- helpers/agent-killswitch.sh. Per ADR 0004 Track 4.

CREATE TABLE IF NOT EXISTS agent_kill_switch (
  id                 INTEGER PRIMARY KEY DEFAULT 1
                     CHECK (id = 1),
  -- single-row enforced
  active             INTEGER NOT NULL DEFAULT 0,
  -- 0 = disabled (normal), 1 = active (block sessions)
  set_by             TEXT,
  -- 'ceo' | 'anomaly-detector' | <name>
  set_at             DATETIME,
  reason             TEXT,
  affected_agents    TEXT
  -- JSON array of role names; NULL = all agents.
);

INSERT OR IGNORE INTO agent_kill_switch
  (id, active, set_by, set_at, reason, affected_agents)
VALUES (1, 0, NULL, NULL, NULL, NULL);

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
