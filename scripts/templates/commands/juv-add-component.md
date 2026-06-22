Execute the component setup procedure defined in JUVANT_OS.md under
"## Component setup". Follow every step exactly as written there, including the
Wizard rendering rule (HARD-REQUIRED — applies to every step). Do not skip or
reorder steps. Collect all required inputs interactively unless batch mode is
active.

A **component** (ADR 0020) is a single-responsibility juvantlabs repo of type
`library` / `mcp-server` / `toolbox` — NOT a full project. It gets one
`<slug>-maintainer` agent, its state lives on GitHub (Issues/Projects/in-repo
ADRs), and it is registered in `.juvant/config.json` `components[]`. There is no
component DB, no board, and no `-pm` repo. If the repo needs Product/Design/Eng
coordination, it is a project — use `/juv-add-project` instead.
