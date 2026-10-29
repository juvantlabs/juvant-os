-- Juvant OS — Turso (LibSQL) Schema
-- Source of truth: juvantlabs/juvant-os-pm/docs/session-commit-p1.md + p2.md
-- Apply with: ./scripts/migrate.sh
-- One DB per scope: company-<name>, project-<name>
-- Immutable rows: supersession only, no in-place edits (agent_tool_matrix, disclosure_policies)
-- Audit tables (security_audit_log, agent_actions_log, decisions) are DB-enforced
-- append-only for their evidentiary columns; corrections/annotations go to the
-- INSERT-only audit_events table. See the AUDIT IMMUTABILITY section at the end
-- of this file (R5b/R5c, decisions#303/#308; SYSTEM_INVARIANTS §10).
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
  -- 'pending' | 'approved' | 'operational_restricted' | 'operational'
  -- mirrors manifests.status lifecycle (SYSTEM_INVARIANTS §1)
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
  -- | 'session-wrap-reminder'
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
  -- 'pending' | 'approved' | 'rejected' | 'operational_restricted' | 'operational'
  -- operational_restricted: CEO-approved, Tier 2 async review in progress (SYSTEM_INVARIANTS §1)
  -- operational: fully cleared post-audit; normal operating state
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
  -- | 'bootstrap-action' | 'cascade-escalation' | 'cascade-postmortem'
  -- | 'skill-gap' | 'migration-watch' | 'upstream-sync-proposal'
  -- | 'eng-platform-spec'
  -- Extended canonical (FEAT-040):
  -- | 'arch-decision'        — architectural decision, durable rationale, no GH action
  -- | 'operational-violation'— CHRO enforcement record; status vocab: 'open'|'closed'
  -- | 'kb-orphan-review'     — CRO review outcome for orphaned KB entries
  rationale       TEXT,
  source_ref      TEXT,
  -- canonical pointer to the GitHub artifact spawned by this decision:
  -- '<org>/<repo>#<N>' for gh-issue-spec / pr-spec.
  -- NULL until the decision is executed (set in the same transaction as
  -- the GitHub write, after Eng Lead 5-check verification passes).
  status          TEXT DEFAULT 'proposed',
  -- 'proposed' | 'approved' | 'rejected' | 'executed' | 'superseded'
  -- superseded: decision was valid at approval time but replaced by a successor.
  --   rationale is immutable (R5b): record the successor decisions.id in an
  --   audit_events row (event_type='status_change', to_value='superseded',
  --   reason='superseded by decisions#<id>') — or in the successor's own rationale.
  --   Distinct from 'rejected': the original decision was correct given the
  --   information available at the time.
  scope              TEXT DEFAULT 'company',
  -- 'company' | 'global' — only master companies may write 'global'
  upstream_candidate INTEGER DEFAULT 0,
  -- 1 = sub-company CEO flagged this for proposal to master (sub DBs only)
  held_for_fallback  INTEGER DEFAULT 0,
  -- 1 = held in VPE buffer during Disclosure Fallback Cascade Tier 4 (§3)
  approved_by     TEXT,
  approved_at     DATETIME,
  executed_by     TEXT,
  -- always COO for spec categories (single-writer §4)
  executed_at     DATETIME,
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Enforce: only master companies may write scope='global'.
-- Catches all write paths (Bash, MCP, direct API) — deny-list alone is insufficient.
CREATE TRIGGER IF NOT EXISTS enforce_global_scope_master_only
BEFORE INSERT ON decisions
WHEN NEW.scope = 'global'
BEGIN
  SELECT RAISE(ABORT, 'scope=global requires company_type=master in master_context')
  WHERE (SELECT value FROM master_context WHERE key='company_type') != 'master';
END;

CREATE TRIGGER IF NOT EXISTS enforce_global_scope_master_only_upd
BEFORE UPDATE ON decisions
WHEN NEW.scope = 'global' AND OLD.scope != 'global'
BEGIN
  SELECT RAISE(ABORT, 'scope=global requires company_type=master in master_context')
  WHERE (SELECT value FROM master_context WHERE key='company_type') != 'master';
END;

-- ── FEAT-040 Layer 1: structural governance enforcement ──────────────────────

-- 1a: Category allowlist — INSERT
-- IF NOT EXISTS here ensures idempotency on new instances.
-- Existing instances get the updated allowlist via the DROP+CREATE in migrate.sh patches.
CREATE TRIGGER IF NOT EXISTS decisions_category_check_ins
BEFORE INSERT ON decisions
WHEN NEW.category IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'decisions.category value not in canonical list — see JUVANT_OS.md schema reference')
  WHERE NEW.category NOT IN (
    'model-override','tool-matrix-change','pr-spec','gh-issue-spec',
    'gh-project-update-spec','gh-milestone-spec','install-spec',
    'branch-protection-spec','release-spec','deployment-spec',
    'secret-rotation-spec','eng-output-held','disclosure-unavailable',
    'bootstrap-action','cascade-escalation','cascade-postmortem',
    'skill-gap','migration-watch','upstream-sync-proposal','eng-platform-spec',
    'arch-decision','operational-violation','kb-orphan-review',
    'legal','product','business',
    'system-audit','incident-response','security-remediation',
    -- Agent-template write categories, BUG-074 — every category an agent
    -- template / JUVANT_OS.md tells an agent to write to decisions.
    'accessibility-audit','aggregate-health-flag','analyst-briefing',
    'backlog-transition','bank-unavailable','binding-confirmation',
    'brand-advisory','brand-mode-ratification-routed','brand-spec',
    'competitor-move','content-performance','content-published',
    'cross-project-dependency','cross-project-release-coordination',
    'cross-project-tech-debt','cso-audit-request','data-deletion-proposal',
    'demo-conducted','deployment','design-debt','design-system-drift',
    'direct-session','disclosure-audit','drift-audit','drift-finding',
    'eng-finding','eng-work-completed','ethical-concern','ethical-opinion',
    'ethical-validation','eval-run','gh-pr-review-spec',
    'kb-promotion-candidate','knowledge-base-retraction','manifesto',
    'mcp-install-confirmed','monthly-ranking','offboarding',
    'offboarding-action','pipeline-outcome','pipeline-stage','prd-published',
    'prd-retro','press-interaction','proposal-sent','release-published',
    'research-output','research-published','roadmap-transition',
    'spec-paused-cascade','spec-rejected','tech-exception','tech-standard',
    'ux-research-published','versioning','weekly-engineering-report'
  );
END;

-- 1a: Category allowlist — UPDATE
CREATE TRIGGER IF NOT EXISTS decisions_category_check_upd
BEFORE UPDATE ON decisions
WHEN NEW.category IS NOT NULL AND NEW.category != OLD.category
BEGIN
  SELECT RAISE(ABORT, 'decisions.category value not in canonical list — see JUVANT_OS.md schema reference')
  WHERE NEW.category NOT IN (
    'model-override','tool-matrix-change','pr-spec','gh-issue-spec',
    'gh-project-update-spec','gh-milestone-spec','install-spec',
    'branch-protection-spec','release-spec','deployment-spec',
    'secret-rotation-spec','eng-output-held','disclosure-unavailable',
    'bootstrap-action','cascade-escalation','cascade-postmortem',
    'skill-gap','migration-watch','upstream-sync-proposal','eng-platform-spec',
    'arch-decision','operational-violation','kb-orphan-review',
    'legal','product','business',
    'system-audit','incident-response','security-remediation',
    -- Agent-template write categories, BUG-074 — every category an agent
    -- template / JUVANT_OS.md tells an agent to write to decisions.
    'accessibility-audit','aggregate-health-flag','analyst-briefing',
    'backlog-transition','bank-unavailable','binding-confirmation',
    'brand-advisory','brand-mode-ratification-routed','brand-spec',
    'competitor-move','content-performance','content-published',
    'cross-project-dependency','cross-project-release-coordination',
    'cross-project-tech-debt','cso-audit-request','data-deletion-proposal',
    'demo-conducted','deployment','design-debt','design-system-drift',
    'direct-session','disclosure-audit','drift-audit','drift-finding',
    'eng-finding','eng-work-completed','ethical-concern','ethical-opinion',
    'ethical-validation','eval-run','gh-pr-review-spec',
    'kb-promotion-candidate','knowledge-base-retraction','manifesto',
    'mcp-install-confirmed','monthly-ranking','offboarding',
    'offboarding-action','pipeline-outcome','pipeline-stage','prd-published',
    'prd-retro','press-interaction','proposal-sent','release-published',
    'research-output','research-published','roadmap-transition',
    'spec-paused-cascade','spec-rejected','tech-exception','tech-standard',
    'ux-research-published','versioning','weekly-engineering-report'
  );
END;

-- 1b: approved requires approved_by + approved_at — INSERT
CREATE TRIGGER IF NOT EXISTS decisions_approved_requires_approver_ins
BEFORE INSERT ON decisions
WHEN NEW.status = 'approved'
BEGIN
  SELECT RAISE(ABORT, 'decisions status=approved requires approved_by and approved_at')
  WHERE NEW.approved_by IS NULL OR NEW.approved_at IS NULL;
END;

-- 1b: approved requires approved_by + approved_at — UPDATE (transition only)
-- Fires only when status changes TO 'approved', not on updates to already-approved rows.
CREATE TRIGGER IF NOT EXISTS decisions_approved_requires_approver_upd
BEFORE UPDATE ON decisions
WHEN NEW.status = 'approved' AND OLD.status != 'approved'
BEGIN
  SELECT RAISE(ABORT, 'decisions status=approved requires approved_by and approved_at')
  WHERE NEW.approved_by IS NULL OR NEW.approved_at IS NULL;
END;

-- 1c: executed requires executed_by + executed_at + source_ref (spec categories only)
-- Non-spec categories (arch-decision, bootstrap-action, etc.) do not require source_ref.
-- UPDATE fires on transition only — avoids blocking historical executed rows with NULL
-- source_ref (pre-FEAT-039 debt) on unrelated column updates.
CREATE TRIGGER IF NOT EXISTS decisions_executed_requires_executor_ins
BEFORE INSERT ON decisions
WHEN NEW.status = 'executed'
  AND NEW.category IN (
    'pr-spec','gh-issue-spec','deployment-spec','install-spec',
    'eng-platform-spec','branch-protection-spec','release-spec','secret-rotation-spec'
  )
BEGIN
  SELECT RAISE(ABORT, 'decisions status=executed requires executed_by, executed_at, and source_ref for spec categories')
  WHERE NEW.executed_by IS NULL OR NEW.executed_at IS NULL OR NEW.source_ref IS NULL;
END;

CREATE TRIGGER IF NOT EXISTS decisions_executed_requires_executor_upd
BEFORE UPDATE ON decisions
WHEN NEW.status = 'executed' AND OLD.status != 'executed'
  AND NEW.category IN (
    'pr-spec','gh-issue-spec','deployment-spec','install-spec',
    'eng-platform-spec','branch-protection-spec','release-spec','secret-rotation-spec'
  )
BEGIN
  SELECT RAISE(ABORT, 'decisions status=executed requires executed_by, executed_at, and source_ref for spec categories')
  WHERE NEW.executed_by IS NULL OR NEW.executed_at IS NULL OR NEW.source_ref IS NULL;
END;

-- ─────────────────────────────────────────────────────────────────────────────

-- Idempotent migration (existing DBs upgrading from pre-FEAT-039 schema):
-- SQLite ADD COLUMN is non-idempotent — wrap with || true if scripting.
--   ALTER TABLE decisions ADD COLUMN source_ref TEXT;

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
  approved_by     TEXT,
  -- no default (BUG-085): NULL until someone approves; a default 'ceo' made
  -- every row look CEO-approved. Writers set it explicitly.
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
  status          TEXT DEFAULT 'draft',
  -- 'draft' | 'validated' | 'active' | 'retired'
  validated_by    TEXT,
  -- CEthO agent name after ethical review
  validated_at    DATETIME,
  ceo_approved_at DATETIME,
  -- set when CEO approves; joint approval = both ceo_approved_at AND validated_at non-null
  valid_from      DATETIME DEFAULT CURRENT_TIMESTAMP,
  valid_until     DATETIME,
  retired_at      DATETIME,
  superseded_by   INTEGER,
  -- immutable rows: supersession only, no in-place edits
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Note: adopters upgrading from a pre-BUG-013 schema (missing status,
-- validated_by, validated_at, retired_at) should run:
--   bash scripts/migrate.sh schema-apply
-- which applies idempotent ALTER TABLE patches after the CREATE TABLE block.

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

-- Outbound action queue (the "outbox"), per ADR 0024. The durable,
-- auditable materialization of the draft → approve → execute invariant:
-- side-effecting MCP operations that need staging (accumulation, an
-- approval gate, throttle/quota, retry, or scheduling) are queued here
-- instead of being dispatched inline. This is ONE canonical table for
-- the whole instance — NOT a queue per MCP. Heterogeneous operations
-- share it via (target_mcp, operation) + a JSON payload, exactly as
-- adapter_dead_letters shares one payload across adapters.
--
-- Activation is per-operation, not per-MCP: an operation enters here only
-- when the rubric in docs/MCP_INVENTORY.md § "Adding a new MCP server"
-- fires. Read-only and fire-and-forget operations bypass it.
--
-- Lifecycle: draft → approved → sent → failed.
--   draft     — agent staged the intent; awaits the CEO commit.
--   approved  — CEO committed via CoS (approved_by set); eligible for drain.
--   sent      — dispatched to the external system (sent_at set).
--   failed    — dispatch failed; retry_count bumped, falls to
--               adapter_dead_letters once retries are exhausted.
-- Autonomous external effect on a non-'approved' row is forbidden
-- (SYSTEM_INVARIANTS §4; the CEO commit is the gate).
CREATE TABLE IF NOT EXISTS outbox (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  scope           TEXT NOT NULL,
  -- 'company' | '<project-slug>' — the governance scope that owns the action.
  target_mcp      TEXT NOT NULL,
  -- the MCP server that performs the dispatch (abstract role name).
  operation       TEXT NOT NULL,
  -- e.g. 'publish' | 'submit-invoice' | 'schedule-post'.
  payload         TEXT NOT NULL,
  -- JSON, operation-specific (the content to send).
  status          TEXT DEFAULT 'draft'
                  CHECK (status IN ('draft','approved','sent','failed')),
  -- 'draft' | 'approved' | 'sent' | 'failed'
  created_by      TEXT NOT NULL,
  -- the drafting agent (role name).
  approved_by     TEXT,
  -- set on the CEO commit via CoS; NULL while in 'draft'.
  scheduled_for   DATETIME,
  -- NULL = send as soon as a drain slot/quota allows; else not before this.
  retry_count     INTEGER DEFAULT 0,
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
  approved_at     DATETIME,
  sent_at         DATETIME
);
CREATE INDEX IF NOT EXISTS idx_outbox_drain
  ON outbox(status, scheduled_for, target_mcp);
CREATE INDEX IF NOT EXISTS idx_outbox_scope
  ON outbox(scope, status);

-- ─────────────────────────────────────────────
-- KNOWLEDGE & PROJECTS
-- ─────────────────────────────────────────────

-- Source change tracking for FEAT-026 Knowledge Sync Pipeline.
-- kb-sync.sh (called at SessionStart) writes here; CoS reads at boot
-- to detect what changed since the last session and offer CRO processing.
CREATE TABLE IF NOT EXISTS source_snapshots (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  source_type     TEXT NOT NULL,
  -- 'onedrive' | 'github_issues' | 'github_prs' | 'turso_decisions' | 'filesystem'
  source_ref      TEXT NOT NULL,
  -- canonical pointer: '<org>/<repo>#<num>', '<site>/<path>', 'turso:decisions', etc.
  content_hash    TEXT NOT NULL,
  -- SHA-256 of normalised content snapshot
  delta_summary   TEXT,
  -- human-readable one-line description of what changed (set on hash mismatch)
  last_seen_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
  last_changed_at DATETIME,
  -- NULL on first insert; set when content_hash differs from previous
  UNIQUE(source_type, source_ref)
);
CREATE INDEX IF NOT EXISTS idx_source_snapshots_changed
  ON source_snapshots(last_changed_at DESC);

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
  approved_by     TEXT,
  -- no default (BUG-085): NULL until someone approves; a default 'ceo' made
  -- every row look CEO-approved. Writers set it explicitly.
  scope           TEXT DEFAULT 'company',
  -- 'company' | 'global' — only master companies may write 'global'
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TRIGGER IF NOT EXISTS enforce_global_kb_scope_master_only
BEFORE INSERT ON knowledge_base
WHEN NEW.scope = 'global'
BEGIN
  SELECT RAISE(ABORT, 'scope=global requires company_type=master in master_context')
  WHERE (SELECT value FROM master_context WHERE key='company_type') != 'master';
END;

CREATE TRIGGER IF NOT EXISTS enforce_global_kb_scope_master_only_upd
BEFORE UPDATE ON knowledge_base
WHEN NEW.scope = 'global' AND OLD.scope != 'global'
BEGIN
  SELECT RAISE(ABORT, 'scope=global requires company_type=master in master_context')
  WHERE (SELECT value FROM master_context WHERE key='company_type') != 'master';
END;

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
-- Since R5b this is DB-enforced, not only convention: DELETE aborts, the
-- fingerprint columns are immutable, and a row is frozen once it leaves
-- 'pending' (see the AUDIT IMMUTABILITY section at the end of this file).
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
  -- 'pending' | 'success' | 'failure' | 'denied' | 'terminated'
  -- 'terminated' (BUG-052): a 'pending' row finalized by the drainer's
  -- post-drain boundary reconcile because no PostToolUse ever closed it —
  -- async / fire-and-forget tools (no synchronous PostToolUse) or spool
  -- tail-loss on SIGKILL / hook-timeout.
  deny_reason   TEXT,
  -- non-NULL when status='denied' (Track 2 deny-list match,
  -- per-agent allow-list miss, or other PreToolUse veto).
  input_summary TEXT,
  -- Human-readable summary of what the agent attempted (max 200 chars).
  -- Mandatory for status='denied' (FEAT-040 Layer 1d).
  -- Set at INSERT time by pre-tool-use.sh for all rows so that
  -- rows later updated to 'failure' already carry the summary.
  spec_id       INTEGER,
  -- ARCH-017 / ADR 0029: soft reference to decisions.id, set when the agent
  -- runs a Bash landing command prefixed `JUVANT_EXECUTING_SPEC=<id> …`.
  -- Lets the Layer-1 spec-marking gate cover artifact-less executions (no PR /
  -- issue to recover a link from). Nullable, no FK (keeps the append-only
  -- audit write cheap/local). Idempotent migration:
  --   ALTER TABLE agent_actions_log ADD COLUMN spec_id INTEGER;
  started_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
  ended_at      DATETIME
);

-- FEAT-040 Layer 1d: denied rows must carry input_summary for forensic value.
CREATE TRIGGER IF NOT EXISTS action_log_denied_requires_summary
BEFORE INSERT ON agent_actions_log
WHEN NEW.status = 'denied'
BEGIN
  SELECT RAISE(ABORT, 'agent_actions_log denied rows require input_summary — set it in pre-tool-use.sh')
  WHERE NEW.input_summary IS NULL OR trim(NEW.input_summary) = '';
END;

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

-- ─────────────────────────────────────────────
-- AUDIT IMMUTABILITY (R5b) + APPEND-ONLY AUDIT EVENTS (R5c)
-- decisions#303 / #304 / #308; security_audit_log#155 / #161 / #163 (CEthO)
-- SYSTEM_INVARIANTS.md §10
-- ─────────────────────────────────────────────
-- Why at the DB level: audit rows were DELETEd (security_audit_log 91–95,
-- 2026-07-04) and edited in place (created_at rewrites, a silent severity
-- downgrade, labels on hook rows). SQL fed via stdin / a redirect / direct
-- HTTP with the DB token bypasses every Bash-level rule; a trigger is the
-- only control every write path must cross.
--
-- Rules:
--   * DELETE on security_audit_log / agent_actions_log / decisions aborts.
--     INSERT OR REPLACE onto an existing id (a delete+insert in disguise that
--     does not fire DELETE triggers) aborts too.
--   * Evidentiary columns are immutable. Columns legitimately set once
--     (decisions.approved_by/approved_at, agent_actions_log.input_summary)
--     accept NULL → value only, never value → other value.
--   * agent_actions_log: a row is frozen once it leaves 'pending' — only the
--     pending → final transition (post-tool-use, post-tool-use-failure, the
--     drainer's 'terminated' reconcile) may set status/ended_at/result_hash.
--   * created_at is the DB clock: an INSERT that supplies created_at more than
--     120 s away from the DB clock aborts (security_audit_log, decisions,
--     audit_events). 120 s absorbs client-computed timestamps (date -u in a
--     hook, NTP skew, a slow libsql round-trip) and is orders of magnitude
--     below any meaningful backdating. agent_actions_log.started_at is exempt:
--     the hook sets it at action time (decisions#298) and the spool may drain
--     much later.
--   * Lifecycle UPDATEs still allowed for ONE minor version (deprecated —
--     new writers record audit_events instead): security_audit_log
--     status/resolved_at; decisions status/executed_by/executed_at/source_ref
--     (+ upstream_candidate, held_for_fallback, scope — non-evidentiary flags).
--   * Corrections, annotations, closures and test-artifact marks are rows in
--     audit_events (INSERT-only). severity_change, timestamp_correction,
--     closure, test_artifact — and a security_audit_log status_change to a
--     terminal status — require authority_ref → a decisions row authored by
--     the CSO (agent='cso') with a rationale (CEO ruling decisions#308: a CoS
--     message alone is not sufficient).
--   * CSO verdict rows (security_audit_log.category='audit-verdict') must carry
--     the severity of the highest finding of the same audit (session_id).
--
-- DDL that cannot be enforced by a trigger (DROP TRIGGER / DROP TABLE) stays
-- covered by the Bash-level SQL deny patterns (BUG-066) and off-host backups.
-- scripts/migrate.sh re-applies every object below via DROP+CREATE
-- (R5_AUDIT_PATCHES); tests/schema/validate.py guards that the two copies agree.
-- Severity rank used below: P0/critical=4, P1/high=3, P2/medium=2, low=1, info=0.

CREATE TABLE IF NOT EXISTS audit_events (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  target_table    TEXT NOT NULL
                  CHECK (target_table IN ('security_audit_log','agent_actions_log','decisions')),
  target_id       INTEGER NOT NULL,
  event_type      TEXT NOT NULL
                  CHECK (event_type IN ('status_change','note','severity_change',
                                        'timestamp_correction','test_artifact','closure')),
  from_value      TEXT,
  to_value        TEXT,
  -- status_change / severity_change / closure / timestamp_correction: the new
  -- value (required). note / test_artifact: optional.
  reason          TEXT NOT NULL CHECK (trim(reason) <> ''),
  authority_ref   INTEGER REFERENCES decisions(id),
  -- decisions.id of the authorizing record (CSO-authored for corrections).
  author          TEXT NOT NULL CHECK (trim(author) <> ''),
  -- role of the writer, e.g. 'cso' | 'cetho' | 'cos' | 'eng-lead'
  created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_audit_events_target
  ON audit_events(target_table, target_id, event_type, id);

-- ── security_audit_log ──────────────────────────────────────────────────────
CREATE TRIGGER IF NOT EXISTS security_audit_log_no_delete
BEFORE DELETE ON security_audit_log
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): DELETE on security_audit_log is forbidden — record a test_artifact or closure row in audit_events instead');
END;

CREATE TRIGGER IF NOT EXISTS security_audit_log_no_replace
BEFORE INSERT ON security_audit_log
WHEN NEW.id IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): security_audit_log id already exists — rows are never replaced')
  WHERE EXISTS (SELECT 1 FROM security_audit_log WHERE id = NEW.id);
END;

CREATE TRIGGER IF NOT EXISTS security_audit_log_immutable_fields
BEFORE UPDATE ON security_audit_log
WHEN NEW.id IS NOT OLD.id
  OR NEW.auditor IS NOT OLD.auditor
  OR NEW.session_id IS NOT OLD.session_id
  OR NEW.scope IS NOT OLD.scope
  OR NEW.audit_type IS NOT OLD.audit_type
  OR NEW.layer IS NOT OLD.layer
  OR NEW.finding IS NOT OLD.finding
  OR NEW.severity IS NOT OLD.severity
  OR NEW.category IS NOT OLD.category
  OR NEW.bootstrap_baseline IS NOT OLD.bootstrap_baseline
  OR NEW.created_at IS NOT OLD.created_at
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): security_audit_log evidentiary columns are immutable — record a severity_change / timestamp_correction / note row in audit_events instead');
END;

CREATE TRIGGER IF NOT EXISTS security_audit_log_created_at_db_clock
BEFORE INSERT ON security_audit_log
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): security_audit_log.created_at must be the DB clock — omit it or use CURRENT_TIMESTAMP (tolerance 120s)')
  WHERE julianday(NEW.created_at) IS NULL
     OR abs(julianday(NEW.created_at) - julianday('now')) * 86400.0 > 120;
END;

CREATE TRIGGER IF NOT EXISTS security_audit_log_verdict_severity
BEFORE INSERT ON security_audit_log
WHEN NEW.category = 'audit-verdict' AND NEW.session_id IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#308): a CSO verdict row must carry the severity of the highest finding of the same audit (session_id) — write findings first, then the verdict')
  WHERE COALESCE(CASE lower(trim(NEW.severity))
                   WHEN 'p0' THEN 4 WHEN 'critical' THEN 4 WHEN 'p1' THEN 3 WHEN 'high' THEN 3
                   WHEN 'p2' THEN 2 WHEN 'medium' THEN 2 WHEN 'low' THEN 1 WHEN 'info' THEN 0 END, -1)
      < (SELECT max(CASE lower(trim(f.severity))
                      WHEN 'p0' THEN 4 WHEN 'critical' THEN 4 WHEN 'p1' THEN 3 WHEN 'high' THEN 3
                      WHEN 'p2' THEN 2 WHEN 'medium' THEN 2 WHEN 'low' THEN 1 WHEN 'info' THEN 0 END)
           FROM security_audit_log f
          WHERE f.session_id = NEW.session_id
            AND f.auditor = NEW.auditor
            AND f.category IS NOT 'audit-verdict');
END;

-- ── agent_actions_log ───────────────────────────────────────────────────────
CREATE TRIGGER IF NOT EXISTS agent_actions_log_no_delete
BEFORE DELETE ON agent_actions_log
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): DELETE on agent_actions_log is forbidden — record a test_artifact or note row in audit_events instead');
END;

CREATE TRIGGER IF NOT EXISTS agent_actions_log_no_replace
BEFORE INSERT ON agent_actions_log
WHEN NEW.id IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): agent_actions_log id already exists — rows are never replaced')
  WHERE EXISTS (SELECT 1 FROM agent_actions_log WHERE id = NEW.id);
END;

CREATE TRIGGER IF NOT EXISTS agent_actions_log_immutable_fields
BEFORE UPDATE ON agent_actions_log
WHEN NEW.id IS NOT OLD.id
  OR NEW.session_id IS NOT OLD.session_id
  OR NEW.agent IS NOT OLD.agent
  OR NEW.tool_name IS NOT OLD.tool_name
  OR NEW.args_hash IS NOT OLD.args_hash
  OR NEW.spec_id IS NOT OLD.spec_id
  OR NEW.started_at IS NOT OLD.started_at
  OR (OLD.input_summary IS NOT NULL AND NEW.input_summary IS NOT OLD.input_summary)
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): agent_actions_log fingerprint columns are immutable (input_summary is set-once)');
END;

CREATE TRIGGER IF NOT EXISTS agent_actions_log_final_row_frozen
BEFORE UPDATE ON agent_actions_log
WHEN OLD.status IS NOT 'pending'
  AND (NEW.status IS NOT OLD.status
    OR NEW.ended_at IS NOT OLD.ended_at
    OR NEW.result_hash IS NOT OLD.result_hash
    OR NEW.deny_reason IS NOT OLD.deny_reason)
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): agent_actions_log row is final — only the pending → final transition may set status/ended_at/result_hash');
END;

-- ── decisions ───────────────────────────────────────────────────────────────
CREATE TRIGGER IF NOT EXISTS decisions_no_delete
BEFORE DELETE ON decisions
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): DELETE on decisions is forbidden — set status (rejected/superseded) or record a test_artifact row in audit_events instead');
END;

CREATE TRIGGER IF NOT EXISTS decisions_no_replace
BEFORE INSERT ON decisions
WHEN NEW.id IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): decisions id already exists — rows are never replaced')
  WHERE EXISTS (SELECT 1 FROM decisions WHERE id = NEW.id);
END;

CREATE TRIGGER IF NOT EXISTS decisions_immutable_fields
BEFORE UPDATE ON decisions
WHEN NEW.id IS NOT OLD.id
  OR NEW.agent IS NOT OLD.agent
  OR NEW.title IS NOT OLD.title
  OR NEW.category IS NOT OLD.category
  OR NEW.rationale IS NOT OLD.rationale
  OR NEW.created_at IS NOT OLD.created_at
  OR (OLD.approved_by IS NOT NULL AND NEW.approved_by IS NOT OLD.approved_by)
  OR (OLD.approved_at IS NOT NULL AND NEW.approved_at IS NOT OLD.approved_at)
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): decisions title/rationale/agent/category/created_at are immutable and approved_by/approved_at are set-once — record a note or status_change row in audit_events instead');
END;

CREATE TRIGGER IF NOT EXISTS decisions_created_at_db_clock
BEFORE INSERT ON decisions
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): decisions.created_at must be the DB clock — omit it or use CURRENT_TIMESTAMP (tolerance 120s)')
  WHERE julianday(NEW.created_at) IS NULL
     OR abs(julianday(NEW.created_at) - julianday('now')) * 86400.0 > 120;
END;

-- ── audit_events (INSERT-only) ──────────────────────────────────────────────
CREATE TRIGGER IF NOT EXISTS audit_events_no_update
BEFORE UPDATE ON audit_events
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): audit_events is INSERT-only — append a new event instead');
END;

CREATE TRIGGER IF NOT EXISTS audit_events_no_delete
BEFORE DELETE ON audit_events
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): audit_events is INSERT-only — DELETE is forbidden');
END;

CREATE TRIGGER IF NOT EXISTS audit_events_no_replace
BEFORE INSERT ON audit_events
WHEN NEW.id IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): audit_events id already exists — rows are never replaced')
  WHERE EXISTS (SELECT 1 FROM audit_events WHERE id = NEW.id);
END;

CREATE TRIGGER IF NOT EXISTS audit_events_created_at_db_clock
BEFORE INSERT ON audit_events
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#303/#308): audit_events.created_at must be the DB clock — omit it or use CURRENT_TIMESTAMP (tolerance 120s)')
  WHERE julianday(NEW.created_at) IS NULL
     OR abs(julianday(NEW.created_at) - julianday('now')) * 86400.0 > 120;
END;

CREATE TRIGGER IF NOT EXISTS audit_events_target_exists
BEFORE INSERT ON audit_events
BEGIN
  SELECT RAISE(ABORT, 'audit_events: target_id does not reference an existing row of target_table (R5c)')
  WHERE (NEW.target_table = 'security_audit_log'
         AND NOT EXISTS (SELECT 1 FROM security_audit_log WHERE id = NEW.target_id))
     OR (NEW.target_table = 'agent_actions_log'
         AND NOT EXISTS (SELECT 1 FROM agent_actions_log WHERE id = NEW.target_id))
     OR (NEW.target_table = 'decisions'
         AND NOT EXISTS (SELECT 1 FROM decisions WHERE id = NEW.target_id));
END;

CREATE TRIGGER IF NOT EXISTS audit_events_shape
BEFORE INSERT ON audit_events
BEGIN
  SELECT RAISE(ABORT, 'audit_events: severity_change applies to security_audit_log only (R5c)')
  WHERE NEW.event_type = 'severity_change' AND NEW.target_table <> 'security_audit_log';
  SELECT RAISE(ABORT, 'audit_events: status_change / severity_change / closure / timestamp_correction require to_value (R5c)')
  WHERE NEW.event_type IN ('status_change','severity_change','closure','timestamp_correction')
    AND (NEW.to_value IS NULL OR trim(NEW.to_value) = '');
  SELECT RAISE(ABORT, 'audit_events: authority_ref does not reference an existing decisions row (R5c)')
  WHERE NEW.authority_ref IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM decisions WHERE id = NEW.authority_ref);
  SELECT RAISE(ABORT, 'audit_events: timestamp_correction to_value must be a parseable datetime (R5c)')
  WHERE NEW.event_type = 'timestamp_correction' AND julianday(NEW.to_value) IS NULL;
  SELECT RAISE(ABORT, 'audit_events: severity_change from_value must equal the current severity of the target row (R5c)')
  WHERE NEW.event_type = 'severity_change'
    AND NEW.from_value IS NOT COALESCE(
          (SELECT e.to_value FROM audit_events e
            WHERE e.target_table = 'security_audit_log' AND e.target_id = NEW.target_id
              AND e.event_type = 'severity_change'
            ORDER BY e.id DESC LIMIT 1),
          (SELECT s.severity FROM security_audit_log s WHERE s.id = NEW.target_id));
END;

CREATE TRIGGER IF NOT EXISTS audit_events_cso_authority
BEFORE INSERT ON audit_events
WHEN NEW.event_type IN ('severity_change','timestamp_correction','closure','test_artifact')
  OR (NEW.event_type = 'status_change' AND NEW.target_table = 'security_audit_log'
      AND lower(trim(NEW.to_value)) IN ('resolved','accepted','closed'))
BEGIN
  SELECT RAISE(ABORT, 'audit immutability (decisions#308): this audit_events row requires authority_ref → a decisions row authored by the CSO (agent=cso) with a rationale — a CoS message alone is not sufficient')
  WHERE NEW.authority_ref IS NULL
     OR NOT EXISTS (SELECT 1 FROM decisions d
                     WHERE d.id = NEW.authority_ref
                       AND d.agent = 'cso'
                       AND d.rationale IS NOT NULL
                       AND trim(d.rationale) <> '');
END;

-- ── Current-state views (base row + latest audit_events) ────────────────────
-- Readers that need the CURRENT severity/status (boot summaries, CSO triage,
-- CHRO penalty formula, morning brief) read these views; the base columns keep
-- the value as originally recorded.
CREATE VIEW IF NOT EXISTS security_audit_log_current AS
SELECT s.*,
  COALESCE((SELECT e.to_value FROM audit_events e
             WHERE e.target_table = 'security_audit_log' AND e.target_id = s.id
               AND e.event_type = 'severity_change'
             ORDER BY e.id DESC LIMIT 1), s.severity) AS current_severity,
  COALESCE((SELECT e.to_value FROM audit_events e
             WHERE e.target_table = 'security_audit_log' AND e.target_id = s.id
               AND e.event_type IN ('status_change','closure')
             ORDER BY e.id DESC LIMIT 1), s.status) AS current_status,
  COALESCE((SELECT e.to_value FROM audit_events e
             WHERE e.target_table = 'security_audit_log' AND e.target_id = s.id
               AND e.event_type = 'timestamp_correction'
             ORDER BY e.id DESC LIMIT 1), s.created_at) AS current_created_at,
  COALESCE((SELECT e.created_at FROM audit_events e
             WHERE e.target_table = 'security_audit_log' AND e.target_id = s.id
               AND e.event_type = 'closure'
             ORDER BY e.id DESC LIMIT 1), s.resolved_at) AS current_resolved_at,
  EXISTS (SELECT 1 FROM audit_events e
           WHERE e.target_table = 'security_audit_log' AND e.target_id = s.id
             AND e.event_type = 'test_artifact') AS is_test_artifact,
  (SELECT count(*) FROM audit_events e
    WHERE e.target_table = 'security_audit_log' AND e.target_id = s.id) AS event_count
FROM security_audit_log s;

CREATE VIEW IF NOT EXISTS decisions_current AS
SELECT d.*,
  COALESCE((SELECT e.to_value FROM audit_events e
             WHERE e.target_table = 'decisions' AND e.target_id = d.id
               AND e.event_type IN ('status_change','closure')
             ORDER BY e.id DESC LIMIT 1), d.status) AS current_status,
  COALESCE((SELECT e.to_value FROM audit_events e
             WHERE e.target_table = 'decisions' AND e.target_id = d.id
               AND e.event_type = 'timestamp_correction'
             ORDER BY e.id DESC LIMIT 1), d.created_at) AS current_created_at,
  EXISTS (SELECT 1 FROM audit_events e
           WHERE e.target_table = 'decisions' AND e.target_id = d.id
             AND e.event_type = 'test_artifact') AS is_test_artifact,
  (SELECT count(*) FROM audit_events e
    WHERE e.target_table = 'decisions' AND e.target_id = d.id) AS event_count
FROM decisions d;

-- Verdict-severity rule (decisions#308), test-checkable: every row here is a
-- violation. Covers what the INSERT trigger cannot: a finding upgraded by a
-- severity_change after the verdict, a finding written after its verdict, and
-- verdict rows without a session_id (unlinkable). Only the latest verdict per
-- audit (session_id) is judged; test-artifact rows are excluded.
CREATE VIEW IF NOT EXISTS security_audit_verdict_severity_violations AS
SELECT v.id AS verdict_id, v.session_id, v.current_severity AS verdict_severity,
       f.id AS finding_id, f.current_severity AS finding_severity,
       'finding more severe than verdict' AS violation
  FROM security_audit_log_current v
  JOIN security_audit_log_current f
    ON f.session_id = v.session_id AND f.auditor = v.auditor
   AND f.id <> v.id AND f.category IS NOT 'audit-verdict' AND f.is_test_artifact = 0
 WHERE v.category = 'audit-verdict' AND v.is_test_artifact = 0
   AND v.id = (SELECT max(x.id) FROM security_audit_log x
                WHERE x.category = 'audit-verdict' AND x.session_id = v.session_id
                  AND x.auditor = v.auditor)
   AND CASE lower(trim(f.current_severity))
         WHEN 'p0' THEN 4 WHEN 'critical' THEN 4 WHEN 'p1' THEN 3 WHEN 'high' THEN 3
         WHEN 'p2' THEN 2 WHEN 'medium' THEN 2 WHEN 'low' THEN 1 WHEN 'info' THEN 0 END
     > COALESCE(CASE lower(trim(v.current_severity))
         WHEN 'p0' THEN 4 WHEN 'critical' THEN 4 WHEN 'p1' THEN 3 WHEN 'high' THEN 3
         WHEN 'p2' THEN 2 WHEN 'medium' THEN 2 WHEN 'low' THEN 1 WHEN 'info' THEN 0 END, -1)
UNION ALL
SELECT v.id, NULL, v.current_severity, NULL, NULL, 'verdict without session_id (unlinkable)'
  FROM security_audit_log_current v
 WHERE v.category = 'audit-verdict' AND v.session_id IS NULL AND v.is_test_artifact = 0;
