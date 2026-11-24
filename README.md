# juvant-os

A human CEO works with a Chief of Staff in Claude Code, which brings in collaborators as needed. A one-page company manifesto reaches every agent. Three dedicated agents (legal, finance, ethics) advise and never veto. Memory is markdown in the company's private git repo. A few hard limits are enforced by hooks: outbound is draft-only, no writes to banking or invoicing, no secrets in the repo, nothing destructive without the CEO.

The example company used throughout is Morvento, a fictional Italian B2B software and consulting company (`examples/morvento/`). Any resemblance to a real company is unintended.

## Start

juvant-os installs only from an official [release](https://github.com/juvantlabs/juvant-os/releases):

```
git clone --branch <release-tag> https://github.com/juvantlabs/juvant-os.git /tmp/juvant-os
bash /tmp/juvant-os/setup.sh ~/Projects/<company> --company "<Company>" --language English
```

Add `--country it` for the Italian pack. Later updates go through the `update` skill.

The hard limits are guardrails against mistakes, not isolation.

## Coming from v1

v1 is frozen on the [`v1` branch](https://github.com/juvantlabs/juvant-os/tree/v1). Instances on v1.22.2 or later sync from there and aren't affected by v2 on `main`. **On an older v1, don't sync from `main`:** move to v1.22.2 or later from the `v1` branch first. v2 doesn't install over v1; see [moving a company from v1 to v2](docs/migrating-from-v1.md).

## Layout

| Path | What |
|---|---|
| `framework/` | What `setup` and `update` copy into a company repo |
| `examples/morvento/` | The fictional reference company |
| `tools/`, `docs/migrating-from-v1.md` | Moving a v1 company to v2 |
| `tests/` | Lint, the `framework/FILES` check, unit tests (`bash tests/run.sh`) |

## License

MIT, see [LICENSE](LICENSE).
