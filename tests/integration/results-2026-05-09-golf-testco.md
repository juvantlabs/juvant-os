# Integration result: 2026-05-09 — Golf Corp testco (post-v0.6.5 validation + F-12 capture)

Sixth dogfood run, against post-merge `main` after v0.6.0 → v0.6.5
shipped (commit `92bf94d` baseline). The run was **instrumented for
F-12 dataset capture** — the wizard was prompted at session start to
write three JSON artifacts at Step 8.5 (`/tmp/golf-matrix-{raw,errors,
corrected}.json`) so the upstream canonical-matrix patches in v0.6.6
have a fixture-grade reference.

The run **completed successfully** with `bootstrap_audit_verdict =
WARN-WITH-CONDITIONS` (1 P1 + 4 P2 conditions, all upstream drift
already known by Step 8.5). All v0.6.x integrity guarantees held.
Two new findings surfaced (F-21 doc/script schema drift,
F-22 hook orphan tracking). The F-12 dataset is captured under
`tests/fixtures/matrix/2026-05-09-golf-*.json` and is the canonical
reference for the v0.6.6 upstream patches.

## Scope and method

| Field | Value |
|---|---|
| Test instance | `Golf Corp` (`golf-corp`), domain `golf.test`, CEO `Olivia Golf` |
| Working tree | `/tmp/testco` (cloned from `https://github.com/juvantlabs/juvant-os.git` at `92bf94d`) |
| Origin | `/tmp/testco-origin.git` (bare local repo) |
| Database | Local SQLite at `.juvant/state.db` |
| Channels / bank / backup | All stubbed (telegram + Other-bank `npm:@golf/bank-mcp-stub`) |
| Doc storage | OneDrive declared, type-it path with `/Golf Corp/<role>` placeholders |
| CRO | Enabled (Lumen) |
| Wizard driver | User-driven in a separate terminal; observation by orchestrator tail of `script -q` log |
| Outcome | **Bootstrap completed**, `master_context.bootstrap_completed_at = 2026-05-09 17:45:28`, verdict `WARN-WITH-CONDITIONS`, commit `20f0155` made on local main |
| Teardown | `rm -rf /tmp/testco /tmp/testco-origin.git /tmp/testco-session.log /tmp/golf-matrix-*.json` after fixtures copied |

## Acceptance matrix — v0.6.5 cumulative validation

| # | Criterion | Result | Notes |
|---|---|---|---|
| 1 | Step 1 renders fields **one at a time** (v0.6.2 rule, clause 1) | ✅ PASS | Identity-critical fields walked individually. |
| 2 | Step 1.5 / Step 4 / Step 4.5 use collection-collapse (v0.6.4 rule, clause 2) | ✅ PASS | Skill emitted "(collection-collapse menu)" prefix on each grouped step. Echo's F-4 + F-5 fix held. |
| 3 | Step 3 Other branch sub-prompts (F-19) | ✅ PASS | Wizard asked provider name + MCP URL when CEO chose `[5] Other` for bank. |
| 4 | Step 6 wizard reaches CRO toggle (Clause 1, identity-critical) | ✅ PASS | CRO enabled with single Y/N + name override prompt. |
| 5 | F-6 — `compile-templates.sh --scope company` | ✅ PASS | Single allowlisted invocation, no Python improvisation. |
| 6 | F-16 — `compile-templates.sh --rewrite-meta` per-company file rewrite | ✅ PASS | `README.md`, `CHANGELOG.md`, `SECURITY.md`, `docs/adr/README.md` rewritten with Golf Corp content; framework ADRs `0001-*.md … 0010-*.md` removed from per-company `docs/adr/`. |
| 7 | F-7 — Step 8 seeds canonical v0 matrix | ❌ NOT YET | Script `scripts/seed-matrix.sh` not yet shipped at v0.6.5; wizard inlined SQL via doc-derived JSON capture. F-7 is a v0.6.6 deliverable (this run). |
| 8 | F-12 — Step 8.5 cross-check captures matrix drift | ✅ PASS (instrumented) | Three JSON artifacts written; full layered findings recorded. See § F-12 dataset below. |
| 9 | F-8 — `audit-bootstrap-baseline.sh` canonical | ✅ PASS | CSO subagent invoked `bash scripts/audit-bootstrap-baseline.sh --scope=company` once; no inline `sqlite3 << SQL` heredocs; ~5 min audit run produced 20 `security_audit_log` rows. |
| 10 | ADR 0010 — Task subagent canonical spawn | ✅ PASS | `agent_actions_log` row at `2026-05-09 17:40:48` with `tool_name='Agent'` and `status='success'` after ~5 min subagent activity. CSO ran `readlink .claude/agents/cso.md` first to verify the symlink. |
| 11 | F-1 — Layer 5 §11 SQL `tool_name IN ('Task','Agent')` | ✅ PASS | Orphan-check returned 0 rows for the live CSO audit. |
| 12 | F-3 — CSO bash-policy.json allow-list expansion | ✅ PASS | No permission-prompts during CSO audit run. |
| 13 | F-13 — `.mcp.json` first-run UX | ✅ PASS | No "Missing environment variable GITHUB_PERSONAL_ACCESS_TOKEN" warning at start. |
| 14 | F-17 — incremental `init_state` tracking | ✅ PASS | Wizard resumed past Step 7 boundary without re-prompting. |
| 15 | F-20 — `file:` prefix strip in `db.sh` / `migrate.sh` | ✅ PASS | `agent_actions_log` populated with 100 rows by run end; `state.db` schema applied without error. |
| 16 | Bootstrap protocol writes 10 manifestos + 11 decisions | ✅ PASS | `manifests` count = 10, `decisions` count = 11 (1 CA matrix seed + 10 manifesto approvals — one per founding agent). |
| 17 | `bootstrap_audit_verdict` recorded in `master_context` | ✅ PASS | `bootstrap_audit_verdict = WARN-WITH-CONDITIONS`, `bootstrap_completed_at = 2026-05-09 17:45:28`. |
| 18 | Step 10 initial commit | ✅ PASS | Commit `20f0155 init(golf-corp): bootstrap company-scope agents` on local main; clean working tree post-bootstrap. |
| 19 | `agent_tool_matrix` populated post-correction | ✅ PASS | 20 rows; corrected per Step 8.5 cross-check (raw was 19; eng-platform added; cos channel → `:send-ceo-only`; m365-graph added to 7 rows; fattura_elettronica added to CFO row). |
| 20 | F-21 — `JUVANT_OS.md` §1.6 example matches script schema | ❌ FAIL | Drift between doc example (uppercase `CEO_GITHUB`) and `scripts/compile-templates.sh:99` (lowercase role-slug `.github_user_map[<role>]`). Wizard caught the mismatch and chose to satisfy the script. v0.6.6 fix. |
| 21 | F-22 — `AskUserQuestion` rows close in `agent_actions_log` | ❌ FAIL | Two `AskUserQuestion` rows left in `pending` state after wizard moved past the prompts. Hook coverage gap. v0.6.6 fix. |

## F-12 dataset — Step 8.5 cross-check capture

The headline deliverable of this run. Three artifacts captured under
`tests/fixtures/matrix/2026-05-09-golf-*.json`:

| File | Bytes | Content |
|---|---|---|
| `2026-05-09-golf-raw.json` | 5284 | Canonical v0 matrix as derived from `agents/company/ca.md` § Default Agent Tool Matrix + `agents/projects/coo.md` (19 rows). |
| `2026-05-09-golf-errors.json` | 5458 | 16 layered findings — 5 L1-server-inventory, 4 L2-universal-boundary, 3 L3-status-warnings, 4 L4-registration-completeness. |
| `2026-05-09-golf-corrected.json` | 8390 | Post-correction matrix actually written to the DB (20 rows). Includes `corrections_applied` (5 entries) and `deltas_vs_raw` (1 added row, 7 modified rows, 12 unchanged rows). |

The five corrections applied at runtime by the wizard:

1. **L4-eng-platform**: ADD row for `eng-platform` (turso, github:read).
   Resolves F-13 founding-vs-deferred ambiguity by promoting to founding
   company-scope cross-project infra agent.
2. **L1-m365-graph**: ADD `m365-graph` to mcp_servers for
   CFO/CLO/CMO/CCO/CDO/CoS/CRO. Closes coverage gap between
   `MCP_INVENTORY.md` ownership claim and matrix grants.
3. **L1-fattura_elettronica**: ADD `fattura_elettronica` to CFO
   mcp_servers (status `pending FEAT-012`).
4. **L1-bank-concrete**: ANNOTATE CFO `bank:read` with concrete provider
   binding `golfbank → npm:@golf/bank-mcp-stub` in rationale; abstract
   role `bank` remains the matrix entry per ca.md § abstraction note.
5. **L2-cos-boundary**: ANNOTATE CoS row with disclosure-boundary scope
   refinement — `telegram:send` is restricted to CEO-only Critical
   alerts (per `cos.md` § Notification rules), not general external
   broadcast. Recorded as `v0-known-drift` for upstream resolution
   (proposed CA decision: `tool-matrix-change` to formally exempt
   CEO-direct notifications from the §4 external-channel-send clause).
   **Build-fail SUPPRESSED** at sandbox/test instance per F-12
   instrumentation; production company init would BUILD-FAIL here
   pending upstream remediation.

The `bootstrap_baseline=1` audit run by the CSO subagent elevated the
Step 8.5 findings to 1 P1 + 4 P2 entries in `security_audit_log` (rows
14–18). Counts by layer in the audit log: 3 access-info, 2
secrets-info, 2 network-info, 3 code-info, 10 agents (3 info, 1 P1, 4
P2, 2 info). Matches the Step 8.5 elevation exactly — no new findings
introduced in the Layer-5 audit beyond what Step 8.5 already surfaced.

The full audit verdict is `WARN-WITH-CONDITIONS` because the P1 and
P2 conditions are upstream drift that the runtime cannot resolve. v0.6.6
ships the upstream patches; the next testco run should produce a
near-empty `errors.json` and a `PASS` verdict.

## Findings — v0.6.6 backlog

### F-21 — `JUVANT_OS.md` §1.6 doc/script schema drift (MEDIUM)

`scripts/compile-templates.sh:99` reads
`.github_user_map[<role-slug>]` where `<role-slug>` is the lowercase
role identifier (`ceo`, `cos`, `cfo`, …, `eng-platform`). The doc
example in `JUVANT_OS.md` § Step 1.6 (~line 733) writes the JSON shape
with uppercase keys (`CEO_GITHUB`, `COS_GITHUB`, `CFO_GITHUB`), which
matches the bash variable convention but does not match what the
script reads. If the wizard followed the doc literally, every
`github_handle <role>` lookup would return empty and `.github/CODEOWNERS`
would render with no `@<user>` annotations.

The wizard caught the divergence at Step 7.5, cited the script as the
runtime-true source, and wrote the config in the form the script
accepts (lowercase role slugs). Behavior is correct; the doc is wrong.

Fix: rewrite the example in `JUVANT_OS.md` § Step 1.6 with lowercase
role-slug keys plus an explicit note that the script reads
`.github_user_map[<role-slug>]` and the slug list is the canonical
agent identifier set (`ceo, cos, cfo, clo, cmo, cco, chro, cso, cetho,
ca, cro, eng-platform`).

### F-22 — `AskUserQuestion` orphan rows in `agent_actions_log` (LOW)

The post-tool-use hook records `started_at` for every tool invocation
but only writes `ended_at` for tool families it explicitly tracks. The
Golf run left two `AskUserQuestion` rows in `pending` state after the
wizard moved past the prompts (id=53 at `17:38:36`, id=91 at
`17:46:05`).

The orphans do not block the wizard — every other action between them
completes normally — but they pollute `WHERE status='pending'` queries
that downstream agents (CSO Layer 5, CoS health checks) run as
freshness signals. Layer 5 §11 orphan-audit detection currently
predicates only on `tool_name IN ('Task','Agent')` so the
`AskUserQuestion` orphans are not flagged as audit cover-ups; but
operational health queries see ghost work-in-flight.

Fix: extend `hooks/post-tool-use.sh` to close `AskUserQuestion` rows
on completion (the tool fires its post-event reliably; the gap is
purely in the hook's `case` arm).

## Recommendation for v0.6.6 — cumulative plan

This is the cumulative plan for the v0.6.6 minor release. Six bundled
deliverables, ordered from smallest blast-radius to largest:

1. **F-22** — `hooks/post-tool-use.sh` extension to close
   `AskUserQuestion` rows. One-line `case` arm addition. No schema
   change. Validation: re-run a testco; expect 0 rows in
   `agent_actions_log WHERE status='pending' AND tool_name='AskUserQuestion'
   AND id < (last id)`.

2. **F-21** — `JUVANT_OS.md` § Step 1.6 example rewrite (lowercase
   role-slug keys + canonical slug list note). Doc-only.

3. **ADR 0011** — `<channel>:send-ceo-only` channel-class carve-out
   from §4 disclosure boundary. Already authored at
   `docs/adr/0011-ceo-direct-channel-class.md`. Status flips from
   Proposed to Accepted at v0.6.6 release. Companion edits already
   landed: `docs/MCP_INVENTORY.md` § Universal Boundaries amended,
   `SYSTEM_INVARIANTS.md` §4 disclosure-boundary corollary added.

4. **F-12 — `agents/company/ca.md` § Default Agent Tool Matrix patch**
   — already landed: 20-row matrix table with `eng-platform` row,
   `cos` channel `telegram:send-ceo-only`, `m365-graph` added to 7
   rows, `fattura_elettronica` added to CFO row, `cdo` project-scope
   `m365-graph` added, footnote 3 (telegram carve-out) and footnote 4
   (eng-platform founding-vs-manifesto distinction) added.

5. **F-7 — `scripts/seed-matrix.sh`** — already shipped (this branch).
   Companion: `scripts/templates/v0-agent-tool-matrix.json` is the
   canonical runtime source (20 rows, drift-corrected). Step 8 of
   `JUVANT_OS.md` should be updated to invoke this script as a single
   allowlistable bash call (replacing the inline-SQL pattern).
   Validation: testco run shows `agent_tool_matrix` populated with 20
   rows from a single `bash scripts/seed-matrix.sh` invocation; Step
   8.5 cross-check returns ≤ 4 informational findings (status-warnings
   only — no boundary violations, no coverage gaps, no registration
   ambiguities).

6. **`JUVANT_OS.md` Step 8 + Step 8.5 doc update** — replace the
   inline-SQL pattern with `bash scripts/seed-matrix.sh`; document
   that Step 8.5 cross-checks the seeded matrix against
   `docs/MCP_INVENTORY.md` and may capture instrumented fixtures to
   `tests/fixtures/matrix/<date>-<company>-{raw,errors,corrected}.json`
   if the run is opted in.

The v0.6.5 deliverables (F-3, F-6, F-13, F-16, F-17, F-19, F-20, F-1,
F-8, ADR 0010) are validated end-to-end by this run. v0.6.6 closes the
upstream-drift class of findings (F-12, F-21, F-22, ADR 0011)
surfaced by the Echo and Golf testco runs. The remaining v0.6.x
backlog (F-2 / F-10 subagent env propagation, F-9 settings policy
review, F-11 schema-correctness audit) is Claude-Code-side or
quality-of-life and lands in v0.6.7 or v0.7.0.

## Conclusion

v0.6.5 is end-to-end validated on every load-bearing integrity
guarantee:

- ADR 0010 (subagent canonical spawn) holds — `tool_name='Agent'`
  observed in `agent_actions_log`.
- v0.6.1 hard-required CSO audit holds — verdict from subagent, not
  fabricated by Skill.
- v0.6.2 wizard determinism rule clause 1 holds — identity-critical
  fields walked one at a time.
- v0.6.4 wizard rendering rule clause 2 holds — collections rendered
  with the collapse menu.
- v0.6.3 Local SQLite hooks fix holds — 100 audit log rows over the
  full bootstrap.
- v0.6.5 F-8 audit-script + F-16 per-company rewrites + F-17
  incremental tracking + F-19 Step 3 Other + F-20 file: prefix all
  hold operationally.

The F-12 dataset captured in `tests/fixtures/matrix/` is the
canonical reference for upstream matrix correctness. v0.6.6 closes
the four findings (F-12, F-21, F-22, ADR 0011) surfaced by this run.
