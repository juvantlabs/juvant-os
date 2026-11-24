# tools/

One-off tools for people moving to juvant-os v2. They are not installed in company repos (not in `framework/FILES`).

| Tool | What it does |
|---|---|
| `migrate-from-v1.py` | Moves a v1 company's decisions, knowledge base and counterparties into a v2 company repo's `memory/`, from a read-only SQLite copy of the v1 DB. Lists agent names and projects for the role cards and the map. Redacts secret-shaped text, never overwrites, commits nothing. `--dry-run` first. Run `python3 tools/migrate-from-v1.py --help`. |
