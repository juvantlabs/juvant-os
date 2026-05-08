# Manual integration scenarios (FEAT-008 Layer 3)

These three scenarios exercise the framework end-to-end. v1.0 ships them
as **manual procedures** — a checklist a developer runs against a freshly
initialized company to confirm the moving parts cooperate. v1.1 will
automate them via the Claude Agent SDK.

| Scenario | Touches |
|---|---|
| [mail-inbound-cfo-draft.md](mail-inbound-cfo-draft.md) | inbound mail → CFO draft → Teams approval card → reply |
| [context-compaction.md](context-compaction.md) | PreCompact → snapshot → PostCompact → continuity |
| [offline-restart.md](offline-restart.md) | agent goes offline → `portal_offline_messages` queued → restart → processed |

## Prerequisites for all three

- A bootstrapped company per `JUVANT_OS.md` § Company setup (all 11
  company-scope manifestos in `operational_restricted` or `operational`).
- `.juvant/config.json` populated with valid Turso credentials and at
  least one configured channel (Teams webhook OR Telegram bot).
- The 9 lifecycle hooks registered in `.claude/settings.json` (template
  default).

## Running one scenario

Open the scenario file. Walk top to bottom, performing each step. A step
either:

- **Asserts** state the system should already hold (read-only check).
- **Triggers** an action the developer must perform.
- **Verifies** an outcome the system should produce.

Mark each line `✓` (pass) or `✗` (fail) in your local copy. At the end,
write the result to `decisions` category `integration-test` with the
scenario name and the date. A scenario fails as a whole if any single
line is `✗`.

## Why manual in v1.0

Each scenario crosses the LLM boundary at least twice (initial agent
turn + reply / re-execution after restart). Reliable end-to-end automation
needs (a) a deterministic prompt fixture per agent, (b) an LLM-judge
to score the output, and (c) a cost ceiling so a flaky run does not
burn through budget. All three depend on the Claude Agent SDK pipeline
slated for v1.1; they are not in v1.0 scope.
