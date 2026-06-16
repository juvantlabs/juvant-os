# ADR 0018 — De-scope FEAT-025 dynamic bash escalation; the self-remediating deny message is the durable design

## Status

Accepted (2026-06-16). Implements the (B) decision of BUG-039
(`juvantlabs/juvant-os-pm#110`). The companion code change — the
self-remediating allow-list deny message in `hooks/pre-tool-use.sh` —
ships on branch `fix/bug-039-deny-message`.

## Context

FEAT-025 (`juvantlabs/juvant-os-pm#41`, closed) designed a **dynamic
bash escalation flow** for the per-agent allow-list-miss path in the
`PreToolUse` hook (Track 2 of handbook ADR 0004):

- a `messages` row of `type='tool_authorization_request'` auto-opened
  to CoS on every allow-list miss,
- a CoS → CEO Teams approval card (one-shot / permanent / deny),
- a `bash_oneshot_grants` table with a 10-minute TTL and a sweeper,
- a hook lookup against that table *before* denying,
- a CSO Layer 5 audit coupling to catch fabricated grant rows.

FEAT-025 was closed as "shipped via PR #1", but investigation in
June 2026 (BUG-039) established two facts:

1. **The hook half never landed.** `git log -S 'deny:allow-list'` and
   `git log -S 'tool_authorization_request'` over `hooks/pre-tool-use.sh`
   are both empty. The allow-list-miss path still emitted the
   *pre-FEAT-025* hard-deny string (`"Escalate to CoS for
   tool-matrix-change"`), which names a remedy the agent cannot perform
   in-session.

2. **The schema half never landed either.** `bash_oneshot_grants` was
   **never created** — `scripts/upgrade-v0.5.sql` only carried a comment
   stating the table was *intentionally deferred to v1.1*. There is no
   `CREATE TABLE`, and no `agent_actions_log.escalation_msg_id` column.
   (An earlier read of that comment mistook it for a live table; it is
   not.)

The real-world failure that motivated the investigation was **not** an
authorization gap. Instance telemetry (project Eng Leads, 3-day window)
showed agents reaching for **shell file-I/O** when the native tools were
available and would have worked:

- `cat > __mocks__/styleMock.js << 'EOF'` (×8),
- `python3 -c "content = '''module.exports…'''"` (×6),
- `gh api …/contents/.github/workflows/preview.yml` (×11, read-only),

each retried up to ~50× because the deny message named a remedy the
agent could not enact. This is a **tool-selection** mistake, not a
missing-binary authorization need.

## Decision

**De-scope the FEAT-025 dynamic bash escalation flow. Do not build it.**

1. The **self-remediating deny message** (BUG-039,
   `hooks/pre-tool-use.sh`) is the durable design for the allow-list-miss
   path. It carries a `deny:allow-list:<binary>` diagnostic prefix, an
   explicit no-retry instruction, the native-tool remedy for file-I/O,
   a read-only-remote carve-out, and routes genuine needs to CoS.

2. The genuinely-novel-binary case (an agent that legitimately needs a
   binary outside a reasonably broad baseline allow-list) routes through
   the **existing `tool-matrix-change` governance** (proposer → CSO
   review → CEO approval). No new mechanism is introduced.

3. `bash_oneshot_grants`, the TTL sweeper, the
   `agent_actions_log.escalation_msg_id` column, and the CoS
   authorization-request card are **not built**. The deferral comment in
   `scripts/upgrade-v0.5.sql` is updated to record this de-scope rather
   than promise a successor migration.

### Rationale

- **The dominant real failure is solved without escalation, and the
  escalation flow would mishandle it.** On a shell-file-I/O deny, the
  escalation flow would auto-open a request asking the CEO to add
  `cat` / `python3` to the agent's allow-list — i.e. it would push
  toward *granting* shell file-I/O, the precise bypass of the Write
  tool's audit and path controls that Track 2 exists to prevent. The
  deny message redirects to the native tool with no human in the loop.

- **The original FEAT-025 bug was already fixed by its other half.**
  FEAT-025 also widened the baseline allow-lists (gh/npx/curl for
  `eng-*`; cloud CLIs for `eng-platform`). That widening — already
  shipped — addressed the "allow-list too narrow" blocker. The
  escalation machinery only ever served the narrow residual case.

- **The machinery is security-sensitive surface for a narrow case.** A
  mechanism that *dynamically grants bash execution* is itself an attack
  surface — FEAT-025 had to add a CSO Layer 5 audit specifically to
  catch fabricated grant rows. Building and maintaining that for a rare
  case is a poor risk/value trade.

### Reopen condition (evidence gate)

This de-scope is reversible on evidence. If telemetry shows **legitimate**
allow-list-miss denies on genuinely-needed new binaries (as distinct from
tool-selection mistakes) at material frequency, reopen this ADR and
reconsider materializing the flow. The `deny:allow-list:<binary>`
diagnostic prefix introduced by BUG-039 makes that measurement cheap.

## Consequences

**Positive**:

- The retry-loop is eliminated for every adopter by a ~7-line message
  change, not a subsystem.
- No dead/misleading schema surface: the deferred-table promise is
  retired rather than left to imply a successor migration is owed.
- Contributors have a cited principle for rejecting a revival of the
  escalation flow absent telemetry ("see ADR 0018").

**Negative**:

- The genuinely-novel-binary case is slightly less ergonomic than an
  automated one-shot grant would be — it routes through
  `tool-matrix-change` governance instead. Accepted: the case is narrow
  and the governance flow already exists.

**Neutral**:

- FEAT-025 #41 stays closed; BUG-039 #110 tracks the message fix to
  merge and records this de-scope as its (B) resolution.
- Reversible by the evidence gate above; this ADR does not foreclose the
  flow permanently, only absent demand.

## Cross-references

- BUG-039 `juvantlabs/juvant-os-pm#110` — the investigation, the (A)
  message fix, and the (B) de-scope decision this ADR records.
- FEAT-025 `juvantlabs/juvant-os-pm#41` — the original (now de-scoped)
  escalation-flow design.
- handbook ADR 0004 Track 2 — the Bash deny-list + per-agent allow-list
  this path belongs to; unchanged by this ADR.
- `hooks/pre-tool-use.sh` — the self-remediating deny message (branch
  `fix/bug-039-deny-message`).
- `scripts/upgrade-v0.5.sql` — deferral comment updated to record the
  de-scope.
