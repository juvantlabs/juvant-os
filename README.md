# juvant-os v2 (work in progress)

This branch holds juvant-os v2, a lighter rewrite. It is not ready for use.

- **v1** is frozen on the [`v1` branch](https://github.com/juvantlabs/juvant-os/tree/v1). Instances on v1.22.2 or later sync from there.
- **v2** replaces `main` when it ships as v2.0.0.

v2 in one paragraph: a human CEO works with a Chief of Staff in Claude Code, which brings in collaborators as needed. A one-page company manifesto reaches every agent. Three dedicated agents (legal, finance, ethics) advise and never veto. Memory is markdown in the company's private git repo. A few hard limits are enforced by hooks: outbound is draft-only, no writes to banking or invoicing, no secrets in the repo, nothing destructive without the CEO.

The example company used throughout is Morvento, a fictional Italian B2B software and consulting company (`examples/morvento/`). Any resemblance to a real company is unintended.

## Layout

| Path | What |
|---|---|
| `framework/` | What `setup` and `update` copy into a company repo |
| `examples/morvento/` | The fictional reference company |
| `tests/` | Lint, the `framework/FILES` check, unit tests (`bash tests/run.sh`) |

## License

MIT, see [LICENSE](LICENSE).
