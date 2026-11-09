# Contributing

juvant-os is maintained by Juvant Srls. Fixes from companies that run it are welcome.

**From a company running juvant-os:** ask your Chief of Staff to use the `bugfix` skill. It fixes the defect in a clean clone, runs the tests, checks that nothing about your company is in the change, and, with your ok, opens a draft pull request labelled `adopter-fix` from your fork.

**By hand:** fork, branch from `v2` (from `main` once v2 is released), change `framework/` and add a test, run `bash tests/run.sh`, and open a draft PR. Put `adopter-fix` in the first line of the description if you can't set the label.

- **Generic only.** This repository is public. Describe the defect and its effect, never your company, people, clients or data.
- **Security issues** (a hard limit that can be bypassed, a leak) go through private vulnerability reporting (Security tab → Report a vulnerability), never a public issue or PR.
- **What happens next.** An automated review comments on the PR. A maintainer merges, and the fix ships in the next GitHub release. Companies get it with `update`.

By contributing you agree that your contribution is licensed under the repository's license.
