# tests/

Eval scenarios for subagent behavior testing.
Run via the JUVANT_OS.md Skill: "Run eval scenario: cfo/inbound-mail"

## Structure

```
tests/scenarios/<role>/<scenario-name>.yaml
```

## Format

```yaml
scenario: "Description of the scenario"
agent: cfo
expected:
  - produces_draft: true
  - reads_counterparty_history: true
  - action_type: consultation
  - no_autonomous_send: true
  - no_confidential_leak: true
```

See Phase 9 of the build plan.
