# ADR 0011 — `<channel>:send-ceo-only` carve-out from the §4 disclosure boundary

## Status

Proposed (2026-05-09). Surfaced by the Golf Corp testco bootstrap
documented in `tests/integration/results-2026-05-09-golf-testco.md`,
finding F-12 layer L2-universal-boundary. Captured in fixture
`tests/fixtures/matrix/2026-05-09-golf-errors.json` row 6 (the
CoS-boundary-collapse P1 elevated by the bootstrap_baseline audit).

## Context

`SYSTEM_INVARIANTS.md` §4 (Single-Writer / Disclosure Boundary)
codifies — and `docs/MCP_INVENTORY.md` lines 60-61 enumerate — that
**a matrix row holding both `state.db` read access AND external-channel
send is forbidden** because the conjunction collapses the disclosure
boundary: an agent that can read `state.db` AND send to an external
channel can leak any internal record to that channel without the human
operator seeing it.

The default v0 matrix shipped in `agents/company/ca.md` § Default
Agent Tool Matrix grants the CoS row `[turso, ms-graph]` MCP servers
(state.db read via turso) AND `telegram (send)` channel — which is, on
the literal reading of §4, a build-fail boundary violation.

The Golf Corp testco run on 2026-05-09 made this explicit. The Step
8.5 cross-check elevated the row to P1 (`agents:cos-boundary-collapse`)
in `security_audit_log`; the in-flight wizard chose to suppress build-
fail for the sandbox/test instance and recorded a self-annotation in
`agent_tool_matrix.notes` mapping the channel to `telegram:send-ceo-only`,
flagging the drift for upstream resolution.

The drift is real but the underlying CoS function is **not** an
external-disclosure surface. CoS Critical alerts go from the operator
back to the operator (CEO → self), via a pre-configured Telegram chat
that only the CEO receives. Three properties of this channel are
materially different from a general external channel:

1. **Recipient identity is fixed at company-init time** — there is no
   recipient enumeration, no per-message addressing. The Telegram
   `chat_id` is bound in `.juvant/config.json` `notifications.telegram.chat_id`
   at the wizard's Step 4 and resolves to the CEO's personal Telegram
   account or a CEO-only chat.
2. **The destination is the human operator**, not an external counterparty
   or a public surface. There is no party to "leak to" — the agent is
   informing the human who already owns the system.
3. **Only one role holds it** — CoS, the orchestrator. The grant is
   scope-narrow: no other agent receives any `:send-ceo-only` channel.

Treating this conjunction as a disclosure-boundary violation flattens
two semantically distinct cases. The §4 boundary is operationally
about "agent reads state, agent sends to a third party that is not
the operator". The CoS Critical alert pattern is "agent reads state,
agent informs the operator about the state". These should be
distinguished in the canonical statement of §4 itself.

## Decision

Introduce a channel-class qualifier `:send-ceo-only` (and, by
extension, `:send-operator-only` as the role-neutral synonym for the
same pattern in non-CEO bootstrap shapes — e.g. cooperatives, multi-
principal companies — see FEAT-022).

A channel binding written as `<channel>:send-ceo-only` (e.g.
`telegram:send-ceo-only`, `slack:send-ceo-only`) is a distinct
**channel class** from the general `<channel>:send` form. The class
carries three contractual guarantees:

1. **Recipient is bound at config time, not message time.** The
   resolved destination lives in `.juvant/config.json`
   `notifications.<channel>.<addr-field>` and is read at `SessionStart`
   into `master_context`. Agents holding the channel cannot pick a
   different recipient at runtime; the address is opaque to them.
2. **The bound recipient must be the operator** — i.e. the CEO at
   single-principal companies or one of the ratified principals at
   multi-principal companies (FEAT-022 multi-principal governance).
   Wizard Step 4 enforces this contract: when the wizard records a
   notification channel, it asks once "Is this address the operator's
   personal channel? [y/N]" and refuses to bind the channel as
   `:send-ceo-only` unless the operator confirms.
3. **The grant remains audit-recordable.** Every `:send-ceo-only`
   send is logged in `agent_actions_log` with `tool_name` set to the
   sending tool plus a `:send-ceo-only` tag, and the `args_hash`
   covers the rendered message body. Track 3 of handbook ADR 0004
   (append-only audit log) applies unchanged.

The §4 boundary is then refined to read:

> **`state.db` read AND external-channel send in the same matrix row**
> — collapses the disclosure boundary. **Exception**: channels of
> class `<channel>:send-ceo-only` are not external-channel sends for
> the purposes of this clause; they are operator-direct notifications
> bound to a config-resolved recipient that is the human principal
> already in the trust loop. CoS holding `[turso, telegram:send-ceo-only]`
> does not violate this boundary.

The amendment is normative in `SYSTEM_INVARIANTS.md` §4, with the
operational definition cross-referenced from `docs/MCP_INVENTORY.md`
§ Universal boundary violations (the inventory loses the bullet for
the un-qualified case and gains the carve-out).

The default v0 matrix is patched at the same time:

- `cos` channels column changes from `telegram (send)` to
  `telegram:send-ceo-only`.
- A footnote in `agents/company/ca.md` § Default Agent Tool Matrix
  cross-references this ADR.

## Consequences

**Positive**:

- The default v0 matrix passes Step 8.5 cross-check at company init
  without sandbox-suppression — production adopters no longer hit a
  WARN-WITH-CONDITIONS verdict on bootstrap baseline for the CoS row.
- The boundary clause now distinguishes the two semantically distinct
  cases. Future channel grants are evaluated against the right
  invariant: external channels go through the §4 ban; operator-direct
  channels go through the §4 carve-out and the Step 4 confirmation
  gate.
- The `:send-ceo-only` class is composable with multi-principal
  governance (FEAT-022). Cooperatives that ratify a multi-CEO bootstrap
  resolve `:send-ceo-only` to the channel of the principal who owns
  the alert lane — no framework change required when FEAT-022 lands.

**Negative**:

- Adopters who upgrade across this ADR see a one-time matrix change
  (cos channel rename). The wizard handles the rename idempotently;
  pre-v0.6.6 instances need a one-line migration:
  `UPDATE agent_tool_matrix SET channels='["telegram:send-ceo-only"]' WHERE role='cos'`.
- The Step 4 confirmation gate adds one prompt to the wizard's
  notification collection. Mitigated by the v0.6.4 collection-collapse
  pattern: the confirmation is a single Y/N at the end of the
  collection, not a per-channel prompt.

**Neutral**:

- Other channels never bound as `:send-ceo-only` are unaffected. The
  general `<channel>:send` form continues to be a §4-blocked grant
  for any agent holding `state.db` read in the same row.
- CSO subagent Layer 5 §11 orphan-audit detection is unchanged: it
  audits the *audit* trail, not the channel-class taxonomy. The
  per-channel send log entries flow through `agent_actions_log` as
  before.

## Cross-references

- `SYSTEM_INVARIANTS.md` §4 — primary reference, amended at this ADR
  acceptance.
- `docs/MCP_INVENTORY.md` § Universal boundary violations — operational
  enumeration, amended.
- `agents/company/ca.md` § Default Agent Tool Matrix — `cos` row
  channels column patched; footnote added.
- `agents/company/cos.md` § Notification rules — pre-existing reference
  for the CEO-only Critical alert pattern; ratified here by the channel
  class.
- `docs/MCP_INVENTORY.md` § Wizard Step 8.5 cross-check — gains an
  explicit note that `:send-ceo-only` channels do not trigger the
  Universal Boundary failure mode.
- handbook ADR 0004 Track 3 (append-only audit log) — the channel-
  class qualifier is recorded in `tool_name`; audit trail invariant
  preserved.
- FEAT-022 multi-principal governance — composability note.
- F-12 finding capture: `tests/fixtures/matrix/2026-05-09-golf-errors.json`
  row 6.
- F-12 corrected reference: `tests/fixtures/matrix/2026-05-09-golf-corrected.json`
  `corrections_applied[4]` (L2-cos-boundary annotation).
