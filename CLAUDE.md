# CLAUDE.md — juvant-os framework development

You are working on the framework itself, on branch `main` (v1 is frozen on `v1`). Every file under `framework/` ships to every company that runs `setup` or `update`.

- Generic only: nothing in this repo names a real company. The example is Morvento (fictional), under `examples/morvento/`.
- Every file under `framework/` is listed in `framework/FILES`, and nothing else is. `bash tests/check-files.sh` checks it.
- Run `bash tests/run.sh` before pushing. CI runs the same script.
- A change to the hooks follows `docs/maintainers/hook-changes.md` before any release: skill-command tests and a replay of real commands, on the final code.
- English for every artifact.
- Design and build plan live in the private PM repo (`docs/v2-design.md`, `docs/v2-build-plan.md`). Weaknesses of guardrails that aren't fixed yet go there, never here: this repo is public.
- Releases are official GitHub releases (adopters install nothing else): stable `v2.x.y`, or pre-releases `-rc.N`. A release is published only with the CEO's ok.
- Adopters send framework fixes as draft PRs labelled `adopter-fix` (the `bugfix` skill). An hourly routine reviews them: `docs/maintainers/adopter-fix-routine.md`.
