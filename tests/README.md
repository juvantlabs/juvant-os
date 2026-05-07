# tests/

Four-layer test suite per FEAT-008. Layers 2 and 4 are fully automated
and run in CI. Layer 1 ships with a scaffold + scenario lint + 4 seed
scenarios; the LLM-judge runner is v1.1. Layer 3 ships as documented
manual procedures; full automation is v1.1.

## Layout

```
tests/
├── hooks/                      ← Layer 2 (automated)
│   ├── run-tests.sh
│   ├── fake-turso.sh
│   └── fixtures/
├── schema/                     ← Layer 4 (automated)
│   └── validate.py
├── scenarios/                  ← Layer 1 (lint + seed; LLM run is v1.1)
│   ├── SCHEMA.md
│   ├── lint.sh
│   ├── cfo/inbound-mail.yaml
│   ├── clo/contract-review.yaml
│   ├── cos/boot-summary.yaml
│   └── cso/system-audit.yaml
└── integration/                ← Layer 3 (manual procedures)
    ├── README.md
    ├── mail-inbound-cfo-draft.md
    ├── context-compaction.md
    └── offline-restart.md
```

## Running locally

### Hook tests (Layer 2)

```bash
bash tests/hooks/run-tests.sh
```

Uses local SQLite (no Turso). Covers idempotency, fail-soft on missing
credentials, and the FEAT-018/019/024/025 paths (deny-list,
allow-list miss → escalation, one-shot grant consumption, audit log
linkage, token-usage UPSERT).

### Schema validators (Layer 4)

```bash
python3 tests/schema/validate.py
```

Asserts that all expected tables and indexes exist, CHECK constraints
reject known-invalid values, baseline `model_pricing` rows are seeded,
default values resolve correctly on plain INSERTs, and
`scripts/upgrade-v0.5.sql` applies cleanly to a v0.4-shape DB.

### Eval scenario lint (Layer 1)

```bash
# One-time setup if your Python is PEP 668 protected (macOS default):
python3 -m venv .venv && .venv/bin/pip install pyyaml

bash tests/scenarios/lint.sh
```

Validates each `tests/scenarios/<role>/*.yaml` against the v1.0 schema
(see `tests/scenarios/SCHEMA.md`): allowlist of `expected.*` keys,
required fields, role exists in `agents/`. Does NOT execute the LLM
run — that's the JUVANT_OS.md Skill operation
*"Run eval scenario: <role>/<name>"*.

### Manual integration scenarios (Layer 3)

```bash
open tests/integration/README.md
```

Three end-to-end checklists exercised manually against a freshly
bootstrapped company. Each scenario is `mail-inbound-cfo-draft`,
`context-compaction`, `offline-restart`. Pass / fail recorded in
`decisions` category `integration-test`.

## CI

`.github/workflows/lint.yml` runs Layer 2, Layer 4, and Layer 1 lint
on every PR + push. Layer 3 is not executed in CI (LLM-in-the-loop;
v1.1 SDK pipeline scope).

## v1.0 vs v1.1 scope

| | v1.0 (today) | v1.1 |
|---|---|---|
| L1 — eval format | ✓ | unchanged |
| L1 — scenario lint | ✓ | unchanged |
| L1 — LLM-judge runner | manual via Skill | automated |
| L2 — hook tests | ✓ | unchanged |
| L3 — scenarios doc'd | ✓ | unchanged |
| L3 — automated end-to-end | manual | automated via SDK |
| L4 — schema validation | ✓ | extended (FK consistency, perf indexes) |
