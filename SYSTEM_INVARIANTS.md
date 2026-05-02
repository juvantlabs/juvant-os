# SYSTEM INVARIANTS

> Canonical source of truth for invariants that span all subagent templates.
>
> The 19 subagent templates in `agents/**/*.md` defer to this document for:
> bootstrap protocol, naming convention, disclosure fallback cascade,
> single-writer invariant, universal CONFIDENTIAL list, spec authorization
> matrix, and architectural principles.
>
> Future modifications to any of these invariants happen here, then propagate
> to subagent files via the standard versioning flow (CHRO proposes → CEO
> approves → CA designs `pr-spec` → COO executes).
>
> All written artifacts in English. No exceptions.

---

## §1 — Bootstrap Protocol

The CSO Manifesto Precondition Gate (cso.md) requires a passing CSO audit
≤30 days on file before any agent can enter Tier 1 manifesto review. This
creates a chicken-and-egg deadlock at day-1 fork initialization: CSO itself
needs an audit before its own manifesto can be approved.

The Bootstrap Protocol resolves this with a one-shot CEO-override mode for
the founding 19 agents.

### Bootstrap entry conditions

A fork enters Bootstrap Mode when ALL of the following hold:

- The fork has just been initialized (`git push --mirror` from
  `juvantlabs/juvant-os` complete).
- `master_context.bootstrap_completed_at IS NULL`.
- `agent_tool_matrix` has been seeded with the v0 default matrix (CA-owned
  template) but no `manifests` rows yet exist.
- The CEO has launched Claude Code in the fork directory and invoked
  `Initialize Juvant OS` (the JUVANT_OS.md skill orchestrator).

### Bootstrap procedure (CEO-only override)

1. The skill compiles all `{{PLACEHOLDER}}` values per the company init
   wizard and writes the compiled subagent files to `agents/**/*.md`.
2. The skill seeds the `manifests` table with one row per agent, each in
   `status='draft'` with the manifesto body authored from a default template.
3. CEO reviews each manifesto draft via the skill's interactive flow.
   The CEO may edit or accept verbatim.
4. For each accepted manifesto, the skill writes:
   - `manifests.tier1_ceo_approved_at = NOW()`,
   - `manifests.tier1_bootstrap = 1`,
   - `manifests.precondition_bypassed = 'bootstrap'`,
   - `manifests.status = 'operational_restricted'`,
   - `manifests.tier1_bootstrap_payload = <single CEO sign-off record>`.
5. The agent transitions to `OPERATIONAL_RESTRICTED` with the standard
   `[MANIFESTO PENDING]` flag visible on outputs.
6. Tier 2 async review (7-day window) follows the standard flow. CEthO,
   CHRO, CA review during Tier 2 even though they themselves are also in
   bootstrap. Tier 2 reviews of bootstrap manifestos record
   `tier2_bootstrap = 1` for traceability.
7. CSO performs the first system audit immediately after all 19 agents
   reach `OPERATIONAL_RESTRICTED`. The audit output goes to `decisions`
   category `system-audit` with `bootstrap_baseline = 1`.
8. When all 19 agents complete Tier 2 AND the first CSO audit returns
   PASS or WARN-WITH-CONDITIONS, the skill writes:
   - `master_context.bootstrap_completed_at = NOW()`,
   - all `manifests.status = 'operational'` (where Tier 2 cleared),
   - all `manifests.restricted = 0`.

### Bootstrap mode is one-shot

- `master_context.bootstrap_completed_at` is set exactly once. It does not
  reset.
- Any subsequent agent addition (e.g. enabling CRO post-bootstrap, or
  introducing a new role via tool-matrix extension) follows the standard
  manifesto lifecycle WITH the CSO precondition gate enforced.
- A corrupted bootstrap (interrupted compilation, partial state, mid-flow
  failure) is recovered by deleting the fork's `.juvant/` directory and
  re-running `Initialize Juvant OS`. There is no partial bootstrap recovery.
- The `precondition_bypassed = 'bootstrap'` flag persists on every founding
  manifesto record forever as audit history. CSO audits explicitly check
  for this flag and treat it as expected ONLY on rows with `tier1_bootstrap = 1`.

### Bootstrap CEO-only override authority

During Bootstrap Mode, the CEO holds combined authority that during normal
operation is split among CHRO + CA + CTO + CSO. The override is bounded:

- ONLY for the founding 19 agents.
- ONLY during the bootstrap session(s) before
  `master_context.bootstrap_completed_at` is set.
- ONLY via the JUVANT_OS.md skill flow (no manual `manifests` table writes).
- All bootstrap actions are logged to `decisions` category `bootstrap-action`
  for permanent audit trail.

The CEO cannot bypass:
- The Universal CONFIDENTIAL list (§5) — even at bootstrap.
- The Universal Boundaries (no `github:write` to non-COO; no `bank:write`
  to non-treasury; etc.).
- Plus: the manifesto draft itself, even at bootstrap, must pass structural
  completeness checks (identity, scope, ethical commitments, anti-pattern
  absence) — the skill enforces these checks before recording approval.

### Post-bootstrap state

After `master_context.bootstrap_completed_at` is set:

- The CSO Manifesto Precondition Gate is structural and unbypassable.
- New agents (e.g. portal variants in v1.1, future CRM-integrated roles)
  follow the standard CA → CSO audit → CHRO/CTO Tier 1 → Tier 2 → CEO
  approval flow.
- Bootstrap-marked manifestos remain auditable; CSO Layer 5 audits include
  a check that bootstrap manifestos have not been silently re-classified.

---

## §2 — Default Naming Convention

All subagent templates use `{{PLACEHOLDER}}` syntax. The JUVANT_OS.md skill
substitutes placeholders at company init from the values below.

### Agent name placeholders (defaults)

| Placeholder | Default name | Role | Scope |
|---|---|---|---|
| `{{COS_NAME}}` | Atlas | Chief of Staff | Company |
| `{{CFO_NAME}}` | Theos | Chief Financial Officer | Company |
| `{{CLO_NAME}}` | Lex | Chief Legal Officer | Company |
| `{{CMO_NAME}}` | Mira | Chief Marketing Officer | Company |
| `{{CCO_NAME}}` | Clio | Chief Commercial Officer | Company |
| `{{CHRO_NAME}}` | Sage | Chief Human Resources Officer | Company |
| `{{CSO_NAME}}` | Shield | Chief Security Officer | Company |
| `{{CETHO_NAME}}` | Vera | Chief Ethics Officer | Company |
| `{{CA_NAME}}` | Arch | Chief Architect | Company |
| `{{CRO_NAME}}` | Lumen | Chief Research Officer (optional) | Company |

### Project-scope agent name placeholders

Project-scope agents are instantiated per project. The placeholder resolves
to a project-suffixed default unless the company init flow specifies otherwise.

| Placeholder | Default pattern | Role |
|---|---|---|
| `{{CTO_NAME}}` | `<project_id>-cto` | CTO for the project |
| `{{CPO_NAME}}` | `<project_id>-cpo` | CPO for the project |
| `{{CDO_NAME}}` | `<project_id>-cdo` | Chief Design Officer for the project |
| `{{COO_NAME}}` | `<project_id>-coo` | COO for the project |
| `{{VPE_NAME}}` | `<project_id>-vpe` | VP of Engineering for the project |

Eng/* agents (eng-api, eng-backend, eng-frontend, eng-ai) do not have a
human-name placeholder; they are referenced by their role identifier.

### System placeholders

| Placeholder | Default value | Used in |
|---|---|---|
| `{{COMPANY_NAME}}` | (set at company init) | All templates |
| `{{COMPANY_DOMAIN}}` | (set at company init) | CMO, CCO, CFO, CLO press/legal/sales mailbox routing |
| `{{CEO_NAME}}` | (set at company init) | All templates — the human authority |
| `{{ACTIVE_PROJECT}}` | (set at session boot per Boot Mode) | CoS Teams card channels |
| `{{PROJECT_NAME}}` | (set at project init) | All project-scope templates |
| `{{AGENT_NAME}}` | resolved per agent (above) | All templates |
| `{{AGENT_DESCRIPTION}}` | resolved per company init | All templates — short 1-line elaboration |

### Per-template tunables (defaults shipped in templates)

| Placeholder | Default | Used by |
|---|---|---|
| `{{HIGH_VALUE_THRESHOLD}}` | €10,000 | CFO Security Rule #7 |
| `{{SPRINT_LENGTH}}` | 2 weeks | VPE Sprint Coordination Protocol |
| `{{ACCESSIBILITY_FLOOR}}` | WCAG 2.2 AA | CDO Accessibility Protocol |
| `{{RUNBOOK_DRILL_CADENCE}}` | 90 days | COO Runbook drill cadence |
| `{{POSTS_PER_CHANNEL_PER_WEEK}}` | 3 | CMO Buffer cadence |
| `{{TIER_STRATEGIC}}` | Strategic | CCO Partnership tiers |
| `{{TIER_COMMERCIAL}}` | Commercial | CCO Partnership tiers |
| `{{TIER_TECHNICAL}}` | Technical | CCO Partnership tiers |
| `{{VOICE_LONGFORM}}` | considered, evidence-led | CMO voice modes |
| `{{VOICE_TWITTER}}` | concise, builder, no hype | CMO voice modes |
| `{{VOICE_LINKEDIN}}` | professional, grounded, no slogans | CMO voice modes |
| `{{VOICE_PRESS}}` | factual, attributable, AP-style | CMO voice modes |
| `{{VOICE_BLOG}}` | conversational expert, examples-first | CMO voice modes |
| `{{VOICE_CRISIS}}` | calm, factual, accountable, no hedging | CMO voice modes |
| `{{W_COMPLETION}}` | 0.30 | CHRO ranking weight |
| `{{W_EFFICIENCY}}` | 0.20 | CHRO ranking weight |
| `{{W_ESCALATION}}` | 0.30 | CHRO ranking weight |
| `{{W_QUALITY}}` | 0.20 | CHRO ranking weight |
| `{{BACKEND_LANG}}` | Python | CA tech standards |
| `{{BACKEND_FRAMEWORK}}` | FastAPI | CA tech standards |
| `{{FRONTEND_PLATFORM}}` | React Native + Expo | CA tech standards |
| `{{WEB_FRAMEWORK}}` | Next.js | CA tech standards |
| `{{MONOREPO_TOOL}}` | Turborepo | CA tech standards |
| `{{STATE_SERVER}}` | TanStack Query | CA tech standards |
| `{{STATE_CLIENT}}` | Zustand | CA tech standards |
| `{{FORMS_LIB}}` | React Hook Form + Zod | CA tech standards |
| `{{DATABASE}}` | LibSQL via Turso | CA tech standards |
| `{{OBSERVABILITY}}` | OpenTelemetry | CA tech standards (mandatory) |
| `{{CICD}}` | GitHub Actions | CA tech standards |

### Substitution rules

- The skill performs whole-token substitution (no partial matches).
- Substitution happens at company init for company-scope agents and at
  project init for project-scope agents.
- Re-substitution after init requires the standard tool-matrix change flow
  (CA proposes → CEO approves → CA `pr-spec` → COO executes).
- The placeholder syntax `{{...}}` is reserved. Any `{{...}}` that appears
  in committed agent output is a substitution failure and triggers a
  CSO Layer 5 audit finding, **with the explicit exception of the runtime-
  bound allowlist below.**

#### Runtime-bound allowlist (exempt from the substitution-failure rule)

The following placeholders are bound at runtime, not at compile time, and are
expected to survive in compiled agent files:

| Placeholder | Bound when | By |
|---|---|---|
| `{{ACTIVE_PROJECT}}` | SessionStart | CoS Boot Mode resolution (see CoS Session Start Protocol step 4) |

CSO Layer 5 audits skip these placeholders during the substitution check.
Any other surviving `{{...}}` token remains a `FAIL`. Adding a new entry to
this allowlist requires a SYSTEM_INVARIANTS.md amendment per Appendix B
governance — it is not a routine matrix change.

---

## §3 — Unified Disclosure Fallback Cascade

When any agent detects that `disclosure_policies` is unreachable or returns
zero active rows, it applies a unified four-tier cascade. Per-agent extensions
(documented in CoS, COO, Eng/*) build on top of this baseline; they do not
replace it.

### Tier 1 — Universal (every agent)

Apply ALL of the following:

1. Treat ALL information in the current session as CONFIDENTIAL.
2. Refuse to draft any external-facing artifact.
3. Insert a row into `inbound_queue` with `agent_owner='cos'`, `priority='High'`,
   `source='internal-handoff'`, content describing the fallback condition
   (which policy table query failed, when, on which DB).
4. Insert a row into `security_audit_log` with category
   `disclosure-unavailable`, severity `medium`, agent identifier, and a
   pointer to the inbound_queue row.
5. Continue internal work that does not require disclosure classification
   (read-only operations, internal drafts, schema lookups).

The Tier 1 cascade is mandatory for every agent that reads
`disclosure_policies`. There is no exemption.

### Tier 2 — CoS-side aggregation

CoS, in addition to applying Tier 1, performs aggregation:

1. On every `inbound_queue` row with category `disclosure-unavailable`,
   start a `T+5min` timer (recorded in the row's `escalation_due_at`).
2. If at `T+5min` the policies are still unreachable (verified by re-query),
   escalate:
   - Send `Telegram` Critical to `{{CEO_NAME}}` with content:
     "Disclosure policies unreachable for >5min. N agents in fallback.
     Sources: [list of agent identifiers]."
   - Apply `[DISCLOSURE FALLBACK ACTIVE]` prefix to all CoS outputs to
     CEO until the cascade clears.
   - Insert a `decisions` row category `cascade-escalation` with the
     timeline.
3. If policies recover (re-query returns ≥1 active row) before T+5min,
   close the inbound_queue rows with status `resolved-self-clearing`,
   record the recovery timestamp in `security_audit_log`, and notify
   CSO via `inbound_queue` priority `High` for post-incident audit.
4. CoS does not lift the cascade; recovery is structural, not declarative.

### Tier 3 — COO single-writer extension

COO, in addition to applying Tier 1, halts ALL spec execution while the
cascade is active:

1. Reject every spec in `inbound_queue WHERE agent_owner='coo' AND status='pending'`
   with reason `cascade-active`. The author re-submits after recovery.
2. Refuse new GitHub writes of any kind. The single-writer property
   inverts to single-reader-only during cascade.
3. Active-but-uncompleted multi-step specs (e.g. a release-spec mid-execution)
   pause at the next step boundary; the partial state is recorded in a
   `decisions` row category `spec-paused-cascade`.
4. Resume happens automatically when CoS records cascade recovery.

### Tier 4 — Eng/* VPE-routing extension

Eng/* agents, in addition to applying Tier 1, route their fallback notification
to VPE INSTEAD of CoS:

1. The `inbound_queue` Tier 1 insert uses `agent_owner='vpe'` rather than
   `agent_owner='cos'`.
2. VPE aggregates Eng/* fallbacks and forwards to CoS as a single
   `inbound_queue` row priority `High` with content
   "Eng/* fallback cascade: <count> agents, project <project_name>".
3. CoS treats this as a single Tier 1 trigger from Eng/* (not <count>
   triggers), which simplifies the cascade aggregation.

### CSO post-incident audit

After cascade recovery, CSO automatically opens an investigation:

1. Read `security_audit_log WHERE category='disclosure-unavailable'` for
   the cascade window.
2. Determine root cause: Turso outage, query bug, network partition,
   credential lapse, etc.
3. Author a `decisions` row category `cascade-postmortem` with: trigger,
   duration, agents affected, recovery mechanism, structural recommendations.
4. If the root cause is reproducible structural (e.g. credential expiration
   without rotation runbook), generate `branch-protection-spec` or
   `secret-rotation-spec` for COO.

### What the cascade does NOT do

- It does not stop internal work (read-only operations, internal drafts).
- It does not pause CHRO ranking computation, CSO scheduled audits, CRO
  research synthesis (these are internal artifacts).
- It does not affect agents whose tool matrix does not include disclosure-
  policy access (e.g. eng-* during purely internal refactors).

---

## §4 — Single-Writer Invariant

> Authoritative reference: `agents/projects/coo.md` and
> `agents/company/ca.md` (Architectural Principle #4).

Summary:

- **COO is the sole agent in the system that writes to GitHub repositories.**
  Commits, PRs, Issues, project boards, milestones, labels, branch protection
  — all originate from COO.
- All other agents that need a GitHub write produce a spec (one of nine spec
  classes — see §6) in the `decisions` table. COO reads, verifies (5-check
  protocol), and executes.
- This single-writer property is a security invariant, not a preference.
  CA cannot grant `github:write` to any other agent under any rationale.

---

## §5 — Universal CONFIDENTIAL List

These items are CONFIDENTIAL by construction. No `disclosure_policies` row
can relax them. No manifesto can opt out of them. CLO drafts, CEthO validates,
and CEO approves disclosure policies — but the universal list is outside
the lifecycle.

The following may NEVER appear in any external-facing artifact:

1. The existence of Juvant OS or any AI infrastructure.
2. The names, roles, count, or existence of other agents.
3. The internal decision log, architecture, or Turso schema.
4. `state.db` contents or structure.
5. Any session_id, agent session_path, or telemetry payload.
6. The `agent_tool_matrix` or any of its history.
7. The content of any `manifests` row (template versioning OR agent manifesto).
8. The internal model assignment (which model an agent uses; even at the
   coarse level Opus/Sonnet/Haiku).
9. The contents of `.claude/settings.json`, even sanitized.
10. The structure of the spec system (pr-spec, gh-issue-spec, etc.)

If a draft would expose any of the above, the agent MUST refuse and log a
`security_audit_log` entry with category `universal-confidential-attempt`,
severity `high`, with notification to CSO and CLO via CoS.

This list is amendable only by CEO + CSO + CLO + CEthO joint approval, and
amendment requires a system-wide manifesto re-validation pass (treated as
a structural change requiring full re-audit).

---

## §6 — Spec Authorization Matrix

> Authoritative reference: `agents/projects/coo.md`.

Summary:

| Spec category | Authorized authors |
|---|---|
| `pr-spec` | CA, CTO, CDO, CSO |
| `gh-issue-spec` | CPO, CTO, CDO, CSO, VPE |
| `gh-project-update-spec` | CPO, CTO, CDO, VPE |
| `gh-milestone-spec` | CPO, CTO |
| `install-spec` | CA |
| `branch-protection-spec` | CSO, CTO |
| `release-spec` | VPE, CTO |
| `deployment-spec` | VPE, CTO |
| `secret-rotation-spec` | CSO |
| `gh-pr-review-spec` | VPE (delegated by CTO when architectural) |

COO performs 5-check verification on every spec (author authorization,
approval state, format completeness, universal-CONFIDENTIAL invariant,
linked artifact integrity). Failed verification = REJECT. No partial
execution.

---

## §7 — Architectural Principles

> Authoritative reference: `agents/company/ca.md`.

Summary (cited when CA APPROVE/REJECT/DEFER any change):

1. Composition over modification.
2. Boundary enforcement.
3. Read-before-write.
4. Single-writer where possible.
5. Schema as source of truth.
6. Versioning everything.
7. Observability mandate (OpenTelemetry).
8. Locality of authority.
9. Reversibility favoritism.
10. Boring tech wins.
11. English everywhere.

---

## Appendix A — Cross-references in subagent files

Subagent files reference this document at their identity section via a
standard pointer:

```
> Refer to `SYSTEM_INVARIANTS.md` for: Bootstrap Protocol (§1),
> Default Naming Convention (§2), Unified Disclosure Fallback Cascade (§3),
> Single-Writer Invariant (§4), Universal CONFIDENTIAL List (§5),
> Spec Authorization Matrix (§6), Architectural Principles (§7).
> This template defers to those invariants where applicable.
```

Per-template extensions to invariants (e.g. CoS's Tier-2 aggregation logic,
COO's Tier-3 single-writer halt, Eng/*'s Tier-4 VPE routing) remain in the
respective subagent files as they encode role-specific behavior on top of
the canonical baseline.

---

## Appendix B — Modification governance

Changes to this document follow the standard versioning flow:

1. Proposer drafts a change (CHRO if discovered via drift; CA if discovered
   via tool-matrix interaction; any agent in principle).
2. CoS routes the proposal to CEO.
3. CEO approves.
4. CA designs `pr-spec` for SYSTEM_INVARIANTS.md update.
5. COO opens PR; review involves CHRO + CA + CSO + CEthO.
6. After merge, CHRO triggers a system-wide manifesto re-validation pass
   if the change touches §1, §3, §4, §5, or §6. Changes touching only §2
   (naming) or §7 (principles citation) are non-structural and do not
   require re-validation.

---

End of SYSTEM_INVARIANTS.md.
