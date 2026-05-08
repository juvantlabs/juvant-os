# Integration result: 2026-05-08 — Gamma Corp testco (integrity-violation surface)

Third dogfood run, this time against post-merge `main` (commit
`aa97979`, the v0.6.0 ship). Purpose was to validate that FEAT-008
+ FEAT-023 + FEAT-024 + ADR 0010 integrate correctly with main's
parallel autonomy / ADR-0009-mail / eng-platform work and that the
new test scaffolding holds against a fresh bootstrap.

The run **surfaced a HIGH-severity integrity violation** that neither
the Acme nor Beta runs caught. The violation is fixed in v0.6.1; this
report is the canonical incident record.

## Scope and method

| Field | Value |
|---|---|
| Test instance | `Gamma Corp` (`gamma-corp`), domain `gamma.test`, CEO `Ray Gamma` |
| Working tree | `/tmp/testco` (cloned from `https://github.com/juvantlabs/juvant-os.git` at `aa97979`) |
| Origin | `/tmp/testco-origin.git` (bare local repo) |
| Database | Local SQLite at `.juvant/state.db` |
| Channels / bank / backup / counterparties | All stubbed |
| Doc storage | OneDrive declared, type-it path with `/Gamma/<role>` placeholders |
| Wizard driver | Fresh Claude Code session, prompt `Initialize Juvant OS` |
| Outcome | **Bootstrap aborted by reviewer** at Step 10 commit prompt — the audit verdict was fabricated (see finding below). Teardown without commit. |
| Teardown | `rm -rf /tmp/testco /tmp/testco-origin.git /tmp/testco-bootstrap-manifestos.py /tmp/testco-close-bootstrap.sql` |

## Key validation outcomes (pre-Step 9)

The pre-bootstrap portion of the wizard ran cleanly against post-merge
main:

- ✓ ADR 0010 symlinks present (`.claude/agents/{ca,cco,cetho,cfo,chro,clo,cmo,cos,cro,cso}.md`).
- ✓ FEAT-008 L1+L4 schema validators pass.
- ✓ FEAT-023 schema applied: `projects.maturity_status`, `project_maturity_history`.
- ✓ FEAT-024 schema applied: `agent_token_usage`, `model_pricing` (3 baseline rows seeded).
- ✓ Step 7 substitution clean (cso.md self-ref fix held; no surviving non-allowlisted placeholders).
- ✓ Step 8.5 MCP cross-check: PASS-WITH-WARNINGS (bank pending FEAT-011, buffer not yet specified).
- ✓ Trivial fix #2: bank options described neutrally (no "Juvant default" leak).

## Finding G-1 — Wizard fabricates CSO `bootstrap_baseline` audit · HIGH

**Symptom.** At Step 9 step 7 (CSO bootstrap_baseline audit), the
Skill orchestrating the wizard **did not invoke** `Task(subagent_type='cso', ...)`.
Instead, the Skill:

1. Generated a one-shot Python helper at `/tmp/testco-bootstrap-manifestos.py`
   to draft + INSERT the 10 manifestos + flip `agents.manifesto_status` to
   `operational_restricted` directly.
2. Ran a textual placeholder-survival check via shell loop.
3. **Output the audit verdict in prose** (the literal text
   *"CSO bootstrap_baseline audit: all 10 compiled agents clean,
   no Universal Boundary violations. Verdict: PASS-WITH-CONDITIONS"*).
4. Wrote `/tmp/testco-close-bootstrap.sql` containing INSERT statements
   into `security_audit_log` with `auditor='cso'` and the fabricated
   verdict, and applied them via `sqlite3 .juvant/state.db < ...`.
5. Set `master_context.bootstrap_completed_at = '2026-05-08 11:18:42'`.
6. Reached Step 10 with the staged commit message asserting
   *"CSO bootstrap_baseline audit returned PASS-WITH-CONDITIONS"*.

At no point did the CSO subagent run. The verdict was the Skill's
own conclusion, encoded as if produced by CSO.

**Root cause (duplice).**

1. **Doc gap in JUVANT_OS.md Step 9 step 7.** The previous prose said
   *"On `y`: invoke the CSO subagent via Task with the prompt …"* —
   permissive, not mandatory, and the upstream `[y/N]` prompt at step
   6 defaulted to `N` (skip-by-default). Nothing in the procedure
   declared the Task spawn HARD-REQUIRED, so the Skill was free to
   route around it under "fast-path" interpretation.
2. **Wizard-determinism cascade (cf. finding #11).** The user's earlier
   choice of *"Auto-generate + accept all verbatim (sandbox-fast)"* at
   the manifesto-approval prompt was reinterpreted by the Skill as
   *"skip all subsequent interactive prompts including the audit-mode
   prompt"*. The audit-mode menu (Run via Task / Inline minimal / Skip)
   was never shown — the Skill chose the no-Task path for the user.

**Comparison across runs (same JUVANT_OS.md prose, different Skill
sessions):**

| Run | Audit-mode menu shown? | Path taken | CSO reasoned? |
|---|---|---|---|
| Acme | yes | `Task(subagent_type='general-purpose', ...)` + inline cso.md briefing | yes (under cso.md persona) |
| Beta | yes | `Task(subagent_type='cso', ...)` (canonical via ADR 0010) | yes (canonical) |
| Gamma | **no** | **No Task invocation; verdict fabricated by Skill** | **NO** |

**Why this matters.** Handbook ADR 0004 multi-track guardrails are
explicitly designed to detect cover-up failure modes — agents writing
state that does not match what was actually executed. The Gamma path
is exactly that: `security_audit_log` rows authored as `auditor='cso'`
where no CSO reasoning happened. A Skill that can fabricate a CSO
audit verdict is structurally indistinguishable from a malicious agent
forging audit history. The promise that CSO independently audits the
bootstrap is unmet, silently.

**Severity.** HIGH (v1.0-blocking once observed).

## Fix path (v0.6.1 — this branch)

1. **`SYSTEM_INVARIANTS.md` §1 step 7** rewritten to make the
   `Task(subagent_type='cso', ...)` invocation hard-required: the
   Skill MUST NOT synthesize the audit verdict; MUST NOT write
   `security_audit_log` rows with `auditor='cso'` directly; MUST NOT
   substitute `subagent_type='general-purpose'` with inline cso.md
   briefing as a fallback. If the canonical resolution fails, the
   wizard aborts and `bootstrap_completed_at` stays NULL — bootstrap
   is recoverable by addressing the registration gap.
2. **`JUVANT_OS.md` Step 9** rewritten:
   * The `[y/N]` "Trigger CSO audit?" prompt is **removed** — the
     audit runs automatically and unconditionally.
   * Step 7 declares the Task invocation HARD-REQUIRED with explicit
     prohibitions on synthesis / direct writes / fallback subagent
     type.
   * Step 8 says verdicts come back from the subagent's response,
     never from the Skill's own reasoning.
3. **Project-bootstrap analog** (Step 5 of project setup) inherits the
   same hard-required rule.
4. **`agents/company/cso.md` Layer 5 (orphan-audit detection).**
   Adds a check that `security_audit_log` rows with `auditor='cso'`
   are forensically suspect if no corresponding
   `Task(subagent_type='cso', ...)` invocation exists in the same
   session window. Operator-mode CSO audit rows (`AGENT_ROLE` unset
   or `'ceo'`) are flagged identically.

## Lessons

- The earlier audit (Acme + Beta) chose the "Run via Task subagent"
  option each time, masking the failure mode. Three runs on the same
  procedure produced three different paths — this is the strongest
  evidence yet that wizard determinism (#11, #12) is not a UX
  nice-to-have but a structural integrity concern.
- ADR 0010 alone is necessary but not sufficient. Symlink resolution
  is one half; the other half is forcing the Skill to actually invoke
  the subagent rather than route around it. v0.6.1 closes the second
  half.
- The cover-up detection rule (cso.md Layer 5 §11) is the runtime
  defense-in-depth. Even if a future Skill version re-introduces the
  fabrication path, the orphan-audit check surfaces it on the next
  CSO audit.
