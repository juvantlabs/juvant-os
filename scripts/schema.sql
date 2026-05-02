-- Juvant OS — Turso (LibSQL) Schema
-- Source of truth: juvantlabs/juvant-os-pm/docs/session-commit-p1.md + p2.md
-- Apply with: ./scripts/migrate.sh
-- One DB per scope: company-<name>, project-<name>
-- Immutable rows: supersession only, no in-place edits (agent_tool_matrix, disclosure_policies)

PRAGMA journal_mode=WAL;

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
  id          TEXT PRIMARY KEY,
  -- project slug e.g. 'hardys'
  name        TEXT NOT NULL,
  db_url      TEXT NOT NULL,
  -- Turso URL for this project's DB
  status      TEXT DEFAULT 'active',
  created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
);

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
