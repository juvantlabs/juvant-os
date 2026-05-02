# ADR 0001 — Skill-first architecture

## Status

Accepted (2026-04-23). Promoted from `juvantlabs/juvant-os-pm#1` (ARCH-001) on
2026-05-02.

## Context

Early drafts of Juvant OS assumed a CLI tool (`jvnt`), an npm package, a Homebrew
formula, and a long-running daemon to orchestrate agents and lifecycle events.
That stack added installation friction, distribution overhead, and a process to
keep alive on the CEO's machine — for a system whose only user is the CEO.

Claude Code provides Skills (Markdown orchestrator files), Subagents, Hooks,
Channels, and Desktop Scheduled Tasks natively. These cover every capability the
CLI and daemon were going to deliver.

## Decision

`JUVANT_OS.md` IS the orchestrator. There is no CLI, no daemon, no npm package,
no Homebrew formula. The CEO opens Claude Code in the per-company directory;
Claude Code loads the Skill; the Skill maps natural-language intent to
procedures. Wall-clock automation (Morning Brief, bank balance polls, fiscal
deadline notices) is delivered through Claude Code Desktop Scheduled Tasks, not
a daemon.

## Consequences

Positive:

- The system is operational when the CEO is operational. There is no process to
  keep alive and no installation tutorial.
- Distribution is `git clone` of a per-company instance, mirror-pushed from
  `juvantlabs/juvant-os` (see `JUVANT_OS.md` Appendix B).
- Every entry point is auditable as Markdown; changes flow through the same Git
  review path as the rest of the architecture.

Negative:

- 24/7 always-on operation is bounded by the CEO's machine availability for the
  Alpha and Beta phases. Known cron windows are covered by Phase 7 Scheduled
  Tasks. The post-v1.0 escape hatch is OP-004 (Azure 24/7 deployment).

## Replaces

- `jvnt` CLI → the Skill.
- `npm @juvant/cli` → not built.
- Homebrew formula → not built.
- Daemon process → Desktop Scheduled Tasks plus lifecycle hooks.

## Implementation

- `JUVANT_OS.md` — the Skill orchestrator (1,249 lines).
- `agents/**/*.md` — 19 subagent templates dispatched via the standard `Task` tool.
- `hooks/*.sh` — 7 lifecycle scripts.
- `.claude/settings.json` — hook + channel registration.

## References

- `SYSTEM_INVARIANTS.md` — canonical invariants for the system.
- `juvantlabs/juvant-os-pm/docs/build-plan.md` — "What we don't build" section.
- `juvantlabs/juvant-os-pm/docs/session-commit-p1.md` — architecture rationale.
