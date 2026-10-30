# Changelog

All notable changes to Juvant OS will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

All written artifacts in English. No exceptions.

---

## [Unreleased]

### Removed

- **Shared-mailbox rules are no longer read from `.juvant/config.json`**
  (BUG-083, juvant-os-pm#185). The fallback announced in v1.14.3 for one
  minor version is gone: Track 2g takes `shared_mailboxes` only from
  `security/policy.json` on `origin/main`, so own-mailbox gating
  (`own_mailbox`) always applies. A block left in config.json while the
  policy has none means the rules were never migrated. The gate does not fall
  back to "off": it denies every call under the block's `tool_prefix`
  (default `mcp__m365-mail__`), with a high audit row and a CEO alert, and
  SessionStart prints a SECURITY WARNING. Once the policy has the key, the
  config copy is dead and can be deleted. **Adopter action, before the
  sync:** if `.juvant/config.json` still has `shared_mailboxes`, move it into
  `security/policy.json` via a reviewed PR to main (validate with
  `scripts/validate-security-policy.sh`). Declare `own_mailbox` explicitly if
  a subagent must write as the mailbox owner (default `agents: "read"`).

## [1.15.3] — 2026-10-30 — Alert and guardrail-job residuals

Adopter actions after the sync:
- Make sure every notification destination is in the gated secrets file
  (`bash scripts/migrate-secrets.sh`): once that file exists, a webhook or
  chat id left only in `.juvant/config.json` is ignored.
- The CEO re-runs `bash helpers/install-schedules.sh` from their own terminal
  (helpers/ and hooks/ changed). From then on SessionStart raises a high row
  and an alert if a guardrail job is not loaded or its plist differs.

### Fixed

- **Alert / secret plumbing residuals after BUG-087/088** (#172, low;
  adopter finding security_audit_log #172).
  - The Track 2e connector deny path wrote its high row without `alert=<id>`,
    so its receipt could not be joined to the row. It now threads
    `juvant_alert_id` like the space-access, mailbox and policy-fail-closed
    paths.
  - `juvant_secret_get` fell back to agent-writable `config.json` for any
    path missing from the gated file, so a per-project webhook
    (`.projects.<slug>.notifications.teams_webhooks.*`) could be redirected.
    Once the gated secrets file exists, notification destinations
    (`.notifications.*`, `.projects.<slug>.notifications.*`) are read from it
    only, with an `IGNORED` notice on stderr for a config-only copy. The
    fallback stays before migration and for other secrets.
  - `hooks/notification.sh` put the Telegram bot token (in the URL) and the
    Teams webhook URL on curl's argv, visible to `ps`. Both now go on stdin
    (`--config -`), as in `hooks/lib/alert.sh`.
- **Guardrail launchd jobs: guard gaps after BUG-089** (#173, low; adopter
  finding security_audit_log #173).
  - Track 2f denied `launchctl` only when the command named an `io.juvant.*`
    label or a LaunchAgents path, so `launchctl bootout gui/<uid>` or a label
    built from variables passed. Now every `launchctl` call in command
    position is denied unless its subcommand is read-only (`list`, `print`,
    `print-disabled`, `blame`, …), whatever the target.
  - A booted-out job went unnoticed: its plist still matched. The SessionStart
    integrity check now runs `launchctl print gui/<uid>/<label>` for every
    guardrail job the installer generates (`job-not-loaded`) and reports a
    generated plist that is missing (`plist-missing`).
  - The plist comparison covered only ProgramArguments and the schedule. It
    now compares every top-level key (an added WorkingDirectory, KeepAlive or
    log path is a finding). EnvironmentVariables must be exactly HOME (this
    user's) + PATH, with every PATH entry absolute and outside the instance
    tree and temp dirs, so a BASH_ENV or PATH injection is caught.
  - Any of these findings at SessionStart writes a high `guardrail-jobs`
    security_audit_log row and sends a CEO alert, linked by `alert=<id>`.
- JUVANT_OS.md sync step 8 documents that `.juvant/pinned-main/` is kept out
  of `git status` via `.git/info/exclude`, and that the `.juvant` symlink is
  the pinned tree's one untracked entry by design.

## [1.15.2] — 2026-10-30 — No false direct-reader warning in migrate-secrets

No adopter action. After the sync, `migrate-secrets.sh` no longer warns
about `hooks/lib/alert.sh`.

### Fixed

- **`migrate-secrets.sh` flagged `hooks/lib/alert.sh` as a direct
  config.json reader** (H24). The direct-reader scan matched the path string
  only, so alert.sh's reads of `.notifications.telegram_*` /
  `.teams_webhooks.approvals` through `_juvant_alert_gated` (secrets file
  only) were reported as "will get NOTHING after the move". Lines that go
  through a framework gated accessor (`juvant_secret_get`,
  `_juvant_alert_gated`) are no longer flagged; a test asserts the framework
  tree itself produces no warning.

## [1.15.1] — 2026-10-29 — Atomic default rebuild on turso

No adopter action unless a `--rebuild-defaults` run is still pending: it is
now one transaction on turso too.

### Fixed

- **`migrate.sh --rebuild-defaults` was not atomic on turso** (H23, BUG-091,
  juvant-os-pm#194; adopter finding #171). v1.14.4 piped the rebuild script to
  `turso db shell`, which runs each statement on its own: `BEGIN` had no
  effect, the final `COMMIT` failed with "cannot commit - no transaction is
  active", the error did not stop migrate, and the row count was checked only
  after the original table was dropped. **The v1.14.4 entry's "one
  transaction" claim did not hold on turso** (it did on local SQLite). On the
  adopter every DB ended correct, but a failed copy would have needed a
  point-in-time restore.
  - On turso the rebuild is now ONE libsql `/v2/pipeline` request carrying a
    Hrana batch: `BEGIN`, each step conditioned on the previous one, `COMMIT`,
    and a `ROLLBACK` that runs unless `COMMIT` did. Locally it is one sqlite3
    process with `.bail on`. Any failure rolls back, leaves the table
    untouched, and makes migrate exit non-zero.
  - A row-count guard now runs **before** the drop and fails the transaction
    when the copy is short.
  - The `sqlite_sequence` (AUTOINCREMENT) high-water mark is carried over, so
    a deleted top id is never reused.
  - `tests/migrate/test-rebuild-defaults.sh` gains a turso-path case (fake
    libsql transport, now batch-aware): a forced failure between the copy and
    the rename leaves the original table with all rows; a normal run has no
    "cannot commit"; the sequence is unchanged.

## [1.15.0] — 2026-10-29 — Alerts with receipts and gated destinations; guardrail jobs pinned to main

Minor version: two defaults change. The scheduled guardrail jobs run a pinned
checkout of `origin/main`, and a required alert channel counts only when its
full destination is in the gated secrets file.

**Adopter actions** after syncing:
1. `bash scripts/migrate-secrets.sh` — moves `telegram_chat_id` into the gated
   file; with `alert_routing.required` set, sensitive-space ops are denied
   until it is there.
2. The CEO runs `bash helpers/install-schedules.sh` from their own terminal
   (needs `refs/remotes/origin/main`), and again after every merged sync that
   changes `helpers/`, `hooks/` or `scripts/`.
3. Add `.juvant/pinned-main/` to the instance `.gitignore`.

### Security

- **Security alerts now leave a delivery receipt** (BUG-087, juvant-os-pm#190;
  adopter finding #158). Every alert sender (Track 2e, Track 2g, the policy
  fail-closed alert, the drainer's spool-injection alert) goes through one
  library, `hooks/lib/alert.sh`. Each channel attempt appends a receipt to
  `.juvant/alert-receipts.jsonl` (Track 2f-protected, mode 600): time,
  channel, `delivered` / `failed`, HTTP status, curl exit code, and the alert
  id — never the text, the URL or the token. The alert id is also written into
  the audit row's finding (`alert=<id>`), linking the two. A failed attempt
  additionally writes a high `alert-delivery-failed` row. Sends stay off the
  gating path, and the Telegram token no longer appears in a curl argv.
- **Alert destinations come from the gated secrets file** (BUG-088,
  juvant-os-pm#191; adopter finding #159). `notifications.telegram_chat_id`
  was read from the agent-writable `.juvant/config.json`, so an agent could
  silently redirect the CEO's alerts. It is now a secret path
  (`migrate-secrets.sh` moves it), and the `alert_routing.required` gate
  accepts a channel only when its FULL destination — the teams `approvals`
  webhook; telegram bot token **and** chat id — is in the gated file: a value
  still in config.json does not count, so a sensitive-space op fails closed.
  **Adopter action:** run `bash scripts/migrate-secrets.sh` after syncing —
  with `alert_routing.required` set, sensitive-space ops are denied until the
  chat id is in the gated file.
- **The scheduled guardrail jobs could be rewritten by agents and ran
  whatever the working tree held** (BUG-089, juvant-os-pm#192; adopter
  finding #160).
  - **Denied for every role (Track 2f):** Write/Edit and Bash writes to
    `~/Library/LaunchAgents/io.juvant.*` (and globs over them); `launchctl`
    load / unload / bootstrap / bootout / enable / disable / kickstart / kill /
    remove on an `io.juvant` job; any `crontab` write (only `crontab -l`
    reads); `install-schedules.sh --uninstall`; writes to the pinned
    checkout. Reads (`ls`, `cat`, `launchctl list|print`) stay allowed.
    Previously a rewritten plist was only caught at the next SessionStart.
  - **Jobs run a pinned, read-only checkout of `origin/main`**:
    `helpers/install-schedules.sh` creates `.juvant/pinned-main` (a detached
    git worktree of `refs/remotes/origin/main`, read with
    `GIT_NO_REPLACE_OBJECTS=1`, `chmod a-w`, its `.juvant` a symlink to the
    instance's state) and points every launchd plist / cron entry there, so a
    branch checkout or an uncommitted edit no longer changes the code the
    jobs execute. Each install refreshes the pin; SessionStart says when it is
    behind `origin/main`; the integrity check regenerates plists without
    touching git (`JUVANT_SCHED_GENERATE_ONLY=1`). `JUVANT_SCHED_PINNED=0`
    keeps the old working-tree mode.
  - **Adopter action:** after syncing, the CEO runs
    `bash helpers/install-schedules.sh` from their own terminal (it needs
    `refs/remotes/origin/main`), and again after every merged sync that
    changes `helpers/`, `hooks/` or `scripts/` (the Upstream sync procedure
    now says so). Add `.juvant/pinned-main/` to the instance `.gitignore` (the
    installer also adds it to `.git/info/exclude`).

## [1.14.4] — 2026-10-29 — Audit views protected; stale approval defaults rebuilt

**Adopter actions** after syncing: rehearse on a DB copy, then
`bash scripts/migrate.sh --rebuild-defaults` (+ `--project=<slug>`) to drop
the `approved_by` 'ceo' default from existing DBs.

### Security

- **`DROP VIEW` was not denied** (H18, BUG-090, juvant-os-pm#193). The SQL gate
  already denied `DROP TRIGGER` (v1.14.0, R5a), but `DROP VIEW` could remove
  the §10 audit views (`*_current`, the verdict-violations view). Both are now
  denied for every role on both DB CLIs (turso, sqlite3) — in the
  per-statement SQL gate (`TEMP` forms included) and `sql_deny_patterns`.
  Prose inside SQL literals, commit messages and PR titles still pass: the
  rule is deliberately not in the universal full-command `deny_patterns`.
  Residual: SQL executed through an interpreter (e.g. python's sqlite3
  module) is not statement-scanned.

### Fixed

- **Secrets-gate false positives in SQL prose** (H20, BUG-090): the BUG-084
  literal normalisation now applies to every Track 2h matcher, not only the
  secrets file — an INSERT whose rationale mentions a dotenv file or the
  `.juvant/` directory passes; `readfile('<dotenv>')` and redirects still
  deny.
- **`tests/hooks/test-space-access-policy.sh` tested the instance's own policy**
  (H21, BUG-090): the hook read `security/policy.json` from `origin/main`, so
  on an instance with a policy the canary failed 13 cases. It now pins its
  synthetic policy (`JUVANT_POLICY_TEST=1` + `JUVANT_POLICY_FILE`).
- Documented (H14): the CEO's `!` shell-mode input and MCP server launches are
  outside the PreToolUse perimeter (verified on an adopter).
- **BUG-085 did not reach existing DBs** (H19, BUG-090, juvant-os-pm#193):
  `CREATE TABLE IF NOT EXISTS` never alters a live table, so on DBs created
  before v1.14.3 `knowledge_base.approved_by` / `agent_tool_matrix.approved_by`
  still defaulted to `'ceo'`. `migrate.sh` now reports the stale default, and
  `migrate.sh --rebuild-defaults` rebuilds each affected table from
  `schema.sql`'s canonical DDL in one transaction (copy → drop → rename; row
  count and default verified; triggers and indexes re-created by schema.sql),
  refusing when the live table has a column the canonical DDL lacks.
  **Adopter action:** rehearse on a DB copy, then
  `bash scripts/migrate.sh --rebuild-defaults` (+ `--project=<slug>`).
  Covered by `tests/migrate/test-rebuild-defaults.sh` (CI, sync whitelist).

## [1.14.3] — 2026-10-29 — Mailbox rules and secrets behind the reviewed policy; tests reach adopters

**Adopter actions** after syncing:
1. Move the `shared_mailboxes` block from `.juvant/config.json` into
   `security/policy.json` via a PR to main (add `own_mailbox` if the defaults
   don't fit); validate with `bash scripts/validate-security-policy.sh`.
2. Switch an existing `scripts/run-m365-graph-mcp.sh` to `juvant_secret_get`,
   then run `bash scripts/migrate-secrets.sh` (it now moves credential-shaped
   keys such as `m365_oauth.client_secret` and lists direct readers).
3. Optionally list extra secret paths (`*.pem`, `credentials.json`) in
   `security/policy.json` `secrets_paths`.

### Security

- **The shared-mailbox gate (Track 2g) read its rules from an agent-writable
  file** (BUG-083 T1, juvant-os-pm#185). `shared_mailboxes` lived in
  `.juvant/config.json`: any agent with Write/Edit could empty `by_agent` and
  switch the gate off without a trace — the pattern ADR 0034 removed from
  Track 2e. The rules now come from `security/policy.json` on `origin/main`
  (validated by `juvant_policy_validate` / `validate-security-policy.sh`;
  invalid → every `mcp__` call fails closed; every change raises the
  SessionStart change alert). Once the policy has `shared_mailboxes`,
  config.json is ignored for it. **Adopter action:** move the
  `shared_mailboxes` block from `.juvant/config.json` into
  `security/policy.json` via a PR to main. Until then the config block is
  honoured with a deprecation warning (one minor version) and SessionStart
  says so.
- **Own-mailbox calls are now gated** (BUG-083 T2): with the rules in the
  policy file, `shared_mailboxes.own_mailbox` governs `m365-mail` calls
  without `shared_user` — `main_thread` (default `readwrite`) and `agents`
  (default `read`: a subagent can no longer send / move / delete as the
  mailbox owner). Denies and writes are audited. The legacy config source
  keeps the old behaviour (own mailbox untouched).
- **Secrets coverage gaps** (BUG-084, juvant-os-pm#186):
  - **Credential-shaped config keys now count as secrets.** On an adopter the
    M365 `client_secret` stayed in `.juvant/config.json` (agent-readable, in
    git history) because `juvant_secret_paths_in` knew only named paths.
    Any key named `client_secret`, `secret`, `token`, `password`, `api_key`,
    `private_key` or ending `_secret` / `_token` / `_password` / `_api_key` /
    `_private_key` (non-empty string) is now detected by the SessionStart
    notice and moved by `migrate-secrets.sh` (`max_tokens`, `token_budget`
    stay put). `migrate-secrets.sh` also lists every script that reads a
    moved path straight from config.json (e.g. a generated
    `run-m365-graph-mcp.sh`) with the `juvant_secret_get` fix.
  - **The M365 wizard no longer writes the client secret to config.json**:
    the CEO stores it with `set-secret.sh` from their own terminal, and the
    generated wrapper reads it with `juvant_secret_get`. **Adopter action:**
    an existing `scripts/run-m365-graph-mcp.sh` that reads
    `.m365_oauth.client_secret` with `jq` must switch to `juvant_secret_get`
    before (or right after) running `migrate-secrets.sh`.
  - **Track 2h now gates dotenv files** (`.env`, `.env.<anything>`, `.envrc`;
    adopter finding H13, security_audit_log#166) for Read / Grep / Edit /
    Write and Bash — by path token, by glob (`.env*`, `*.env`), `source` /
    `.` / `export $(cat …)`, and Grep `glob` targeting them — like the
    secrets file, for every role. Templates (`.env.example` / `.sample` /
    `.template` / `.dist`) stay readable; a bare unchained `ls` / `cd` /
    `mkdir` stays allowed (a CSO `ls -l .env.local` mode check); words that
    merely contain `.env` (`process.env.HOME`) are not paths and pass.
    MCP servers launched through `dotenv-cli -e .env.local` are process
    spawns by Claude Code, not tool calls, so they are unaffected.
  - **Configurable extra secret paths**: `secrets_paths` in
    `security/policy.json` (e.g. `["*.pem", "credentials.json"]`) adds path
    globs to the gate, matched on the repo-relative path, the basename and as
    Bash tokens; a catch-all (`*`) is rejected by the validator.
    `.envrc` added to the template `.gitignore`.
  - **No more false positive on SQL prose**: a DB-CLI command whose SQL prose
    literal mentions the secrets-file path (a rationale, a finding) is
    allowed — matched with the SQL gate's literal normalisation (decisions#303
    E-bis). A path in a one-word literal (`readfile('…')`) or outside the SQL
    still denies.

### Fixed

- **The schema and migrate tests never reached adopters** (BUG-086,
  juvant-os-pm#189). The upstream-sync whitelist synced `scripts/schema.sql`
  and `scripts/migrate.sh` but not the tests that guard them. It now lists
  `tests/schema/{validate.py,test-audit-immutability.sh,test-category-allowlist.py}`,
  `tests/migrate/test-*.sh` and `scripts/upgrade-v0.5.sql` (read by
  `validate.py`); the sync smoke-test step runs them when `schema.sql` or
  `migrate.sh` changed; `tests/sync/test-sync-compile.sh` now also enforces
  that every framework file under `tests/schema/` and `tests/migrate/` is
  whitelisted.
- **A freshly inserted `knowledge_base` / `agent_tool_matrix` row looked
  CEO-approved** (BUG-085, juvant-os-pm#187): `approved_by` defaulted to
  `'ceo'`. New DBs get no default (NULL until someone approves);
  `governance-backfill.sh` now writes `approved_by` NULL explicitly; the
  `JUVANT_OS.md` schema reference tells writers to set it explicitly.
  `validate.py` fails on any `approved_by` column with a default. Existing DBs
  keep the old default (SQLite cannot drop a column default without a table
  rebuild, not worth the risk on a live DB for a column no gate reads): on
  those, a row that omits `approved_by` still reads `'ceo'` — set it
  explicitly.

## [1.14.2] — 2026-10-29 — Prescribed decisions writes land; migrate.sh fails loud

**Adopter action:** run `bash scripts/migrate.sh`, plus `--project=<slug>` for
each project DB (DROP + CREATE of the category triggers; no row is rewritten).

### Fixed

- **Agent writes to `decisions` were aborted for 56 of the categories the
  templates prescribe** (BUG-074, juvant-os-pm#161). The
  `decisions_category_check_*` allowlist held 29 values; agent templates and
  `JUVANT_OS.md` tell agents to write 85, mostly in the Memory Commit step, so
  the row never landed. The allowlist now holds all 85, in `scripts/schema.sql`,
  both `scripts/migrate.sh` patch sets, `scripts/governance-backfill.sh` and both
  `JUVANT_OS.md` enumerations. Existing instances pick it up with
  `bash scripts/migrate.sh` (DROP + CREATE of the two triggers; no row is
  rewritten). This is Option A of the issue; reconciling each template's boot
  reads with what it writes (Option B) follows separately.
- **CHRO's CSO-precondition gate read a category nobody writes.** It waited for
  `decisions` category `cso-audit` with `outcome='pass'`; CSO writes
  `system-audit`, and `decisions` has no `outcome` column. The gate now reads
  the `system-audit` row and its `audit-verdict` row in `security_audit_log`.
- **`migrate.sh`: two `BEFORE INSERT` trigger patches referenced `OLD.status`**
  (BUG-079 nit, juvant-os-pm#181), which an INSERT trigger does not have. Masked
  because `schema.sql` creates the correct trigger first; fixed anyway.
- `governance-backfill.sh` phase 0a no longer remaps categories that are now
  canonical (`system-audit`, `deployment`, `versioning`, `manifesto`, …).
- **`migrate.sh` could leave `security_audit_log` unwritable** (BUG-080 #1,
  juvant-os-pm#182). On a DB without `security_audit_log.session_id`,
  `schema.sql` created the R5 triggers that name it before the ADD COLUMN patch
  ran; until then every write failed with `no such column`, and a run that
  aborted in between left it that way. The ADD COLUMN patches now also run
  before `schema.sql` (a fresh DB's "no such table" is benign there).
- **`migrate.sh` reported success after a silent no-op** (BUG-080 #2). With
  expired turso auth the CLI exits 0 having applied nothing. The run now reads
  back every table, trigger and view `schema.sql` and the patches create, and
  every patched column, and exits 1 with the missing objects and a
  `turso auth` hint instead of "Schema applied successfully".
- `migrate.sh` keeps one copy of the patch lists for both the local and the
  turso branch (they were duplicated, identical), and the DB CLI no longer
  inherits the patch loop's stdin.

### Added

- **`tests/schema/test-category-allowlist.py`** (CI): every copy of the
  allowlist must agree, every category a template tells an agent to write to
  `decisions` must be in it, and no `migrate.sh` INSERT trigger may reference
  `OLD`. The class had bitten four times (BUG-055, BUG-063, BUG-074).
- **`tests/migrate/test-schema-apply-order.sh`** (CI): an interrupted
  migration of an old-shape DB leaves `security_audit_log` writable; a DB CLI
  that exits 0 without applying makes `migrate.sh` fail.

## [1.14.1] — 2026-10-29 — Security policy validator checks the right repo

### Fixed

- **`validate-security-policy.sh --ref` checked the wrong repo when run from a
  framework checkout (decisions#305).** `--ref` read `security/policy.json` from
  the repo the *script* lives in, so validating an instance's `origin/main` from
  a juvant-os checkout looked at juvant-os. `--ref` now resolves against
  `--repo <dir>`, else the git repo of the current directory, else the script's
  repo; and like the hook it reads `origin/…` as `refs/remotes/origin/…`, so a
  local branch named `origin/main` can't shadow it. Reported by the adopter
  instance while staging its policy.

## [1.14.0] — 2026-10-29 — Audit integrity, policy as a reviewed file, gated secrets (decisions#301–#306, #308)

### Security

- **Secrets move to a gated `.juvant/secrets.json`; least-privilege read token;
  DB token off the curl command line (decisions#305 B1b).** DB tokens, webhook
  URLs and bot tokens sat in `.juvant/config.json`, which every agent can `Read`.
  CEO ruling (2026-10-29): a separate secrets file behind the hook gate — not
  the OS keychain (portable, no OS coupling, no unlock prompts for launchd).
  - New `hooks/lib/secrets.sh` (`juvant_secret_get`): every hook, helper and
    script reads secrets through it — `.juvant/secrets.json` first (same key
    paths as config.json), legacy config.json for one minor version with a
    deprecation warning.
  - New PreToolUse **Track 2h**: Read / Grep / Edit / Write on the secrets file,
    any Bash command that names it, and Bash commands that take `.juvant/`
    wholesale are denied for every role, main thread included.
  - `scripts/migrate-secrets.sh` moves the secrets (0600, verified before they
    leave config.json, never prints a value); `scripts/set-secret.sh` adds one
    from stdin, **add-only** (an agent can't redirect alerts or swap a token).
    SessionStart tells the main thread when secrets are still in config.json.
  - `hooks/lib/db.sh` uses a **read-only token** (`.db.read_token`, from `turso
    db tokens create <db> --read-only`) for every read and the write token only
    for writes, and passes the bearer token to curl on **stdin** (`--config -`)
    instead of argv, where any process of the user could read it (`ps`).
  - R2 template denies `Read/Edit/Write(.juvant/secrets.json)`; `.gitignore`
    covers it.
- **Connector document surface denied (decisions#306, security_audit_log#156).**
  The claude.ai Microsoft 365 connector reached the legal-ip space with no Track
  2e coverage: `sharepoint_search` / `sharepoint_folder_search` take only free
  text and `read_resource` one opaque URI, so no sensitive identifier is visible
  in the arguments. Ruling: deny, not extend. The policy's
  `connector_tool_allowlist` (security/policy.json) names the only connector tools
  allowed — `outlook_email_search`, `outlook_calendar_search`, `get_me`, and
  `read_resource` for `mail://` URIs — for every role, main thread included;
  every other tool, including any the vendor adds later, is denied. A denied
  call that names a sensitive space writes a high row synchronously and alerts.
  The R2 template also denies the two SharePoint search tools. New canary
  `tests/hooks/test-connector-gate.sh`, re-run on every adopter sync (also
  against the instance's own policy). The connector's effective scope narrows to
  mail + calendar; document search goes through `m365-graph`.
- **Instance security policy moves to a committed `security/policy.json` read
  from `origin/main` (decisions#305 B1a, ADR 0034, security_audit_log#159).**
  Track 2e rules lived in gitignored `.juvant/config.json`, where any agent could
  empty `.security.space_access` and silently disable the perimeter. New
  `hooks/lib/security-policy.sh` reads the policy with
  `GIT_NO_REPLACE_OBJECTS=1 git cat-file -p refs/remotes/origin/main:security/policy.json`
  — working-tree edits, local commits, branch switches, a shadowing local
  `origin/main` branch/tag and `git replace` have no effect. Invalid or deleted
  (after it existed) → **fail closed**: every `mcp__` call denied + high row +
  alert. `alert_routing.required` channels without a secret deny ops that would
  raise a sensitive-space row. SessionStart raises a high row + CEO alert when
  the policy blob changes, and the integrity check flags `JUVANT_*` overrides in
  `.claude/settings*.json` `env`. Track 2f protects `security/policy.json`,
  `.git/**` and the git operations that move or redefine remote refs.
  `JUVANT_CONFIG` never selects the policy (tests: `JUVANT_POLICY_TEST=1`).
  Legacy config rules are honoured for one minor version with a deprecation
  warning. New `scripts/validate-security-policy.sh` +
  `docs/schemas/security-policy.schema.json`. ADR 0034 supersedes ADR 0025
  clause 5 only; `security/policy.json` joins the never-touched list.
  **Adopters: commit `security/policy.json` to `main` before syncing this.**
- **SQL content gate: every DB-CLI input route scanned, prose literals are data,
  audit tables immutable at the Bash level (decisions#303 E / E-bis / R5a,
  security_audit_log#155, #161, #164).** SQL fed to `turso db shell` / `sqlite3`
  via a redirect, pipe, here-string or heredoc was never scanned, so every
  Bash-level SQL rule was bypassable; and the universal deny-list still matched
  `DROP … TABLE` / the pause keyword inside SQL string literals, blocking
  legitimate audit INSERTs. A new gate collects the SQL of every DB-CLI segment
  (quoted/unquoted arguments, a `<` redirect FILE — read and scanned —, a
  here-string, a heredoc body) and checks it per statement, case-insensitively,
  after removing comments and emptying prose literals. Routes whose content
  can't be read statically are denied: piped SQL, `<(…)`, an SQL argument that is
  a shell expansion, a here-string/heredoc with live expansions, an unreadable or
  >1 MiB redirect file, `.read`/`.import`/… dot-commands, direct libsql HTTP
  (`/v2/pipeline`). **R5a** (`bash-policy.json` `.sql_protected`): no DELETE /
  REPLACE / ALTER RENAME|DROP on `security_audit_log`, `agent_actions_log`,
  `decisions`, `audit_events`; no UPDATE whose SET clause assigns an evidentiary
  column (the WHERE is not read as a write); `decisions.approved_by/approved_at`
  only with an `approved_by IS NULL` guard (the documented approval UPDATE now
  carries it); no typed `created_at`; no `DROP TRIGGER`. The schema triggers
  (R5b) stay the backstop for routes a Bash gate can't see.
- **Track 2e sensitive-space audit rows are written synchronously again
  (decisions#303 R4, security_audit_log#154).** A legal-ip row that waited in the
  agent-writable spool until the next drain could be deleted or rewritten before
  it landed. The row now goes through `juvant_db_exec` inline (bounded by
  `JUVANT_DB_TIMEOUT`), falling back to the spool only on a transport failure
  (the decisions#276 pattern), so a DB outage still never loses it. The allow/deny
  decision is computed first and does not depend on the write; the same-turn
  alert is unchanged. `agent_actions_log` (Track 3) stays async.
- **One protected-path set for the tamper floor and the integrity check;
  audit spool, backups, helpers and scripts covered (decisions#303 R1/R2 + B2,
  security_audit_log#154, #160).** The audit spool (`.juvant/audit-spool.sql`
  and every `.draining.*` / `.merge.*` / `.reclaim.*` sibling, plus the
  quarantine file) is an agent-writable SQL replay channel, and
  `.juvant/backups/`, `helpers/*.sh` (including the drain, `install-schedules.sh`
  and `kb-sync.sh`, which runs at every SessionStart) and `scripts/*.sh` (including
  `governance-backfill.sh`) sat outside Track 2f and the SessionStart check. New
  `hooks/lib/guardrail-paths.sh` defines the set once; Track 2f applies every
  write form it already covered (redirect, `tee`, `sed -i`, `cp`/`mv`/`rm`/`ln`/
  `chmod`/`truncate`, `find -delete`, git checkout/restore/rm/mv, interpreters,
  heredocs, `cd <dir> && …`) to all of it. Reads and running a hook or helper
  (`bash helpers/drain-audit-spool.sh`) stay allowed. The SessionStart integrity
  check now also verifies `helpers/*.sh` / `scripts/*.sh` against upstream
  history, and every installed `io.juvant.guardrails.*` launchd plist against a
  fresh `install-schedules.sh` generation (ProgramArguments + schedule keys).
  **R2:** `scripts/templates/hooks-registration.json` carries `permissions_deny`
  (Edit/Write on the spool family, backups, the drain helper and
  `security/policy.json`); `sync-hooks.sh` merges them into an instance's
  `.claude/settings.json` without removing instance entries (skipped in the
  framework repo, where an absolute deny would block framework development), and
  corrects the stale comment that claimed `.juvant/config.json` was denied.
- **Per-agent shared-mailbox gate for `m365-mail` (decisions#301 K2).** The
  server's single allowlist (`M365_MAIL_ALLOWED_SHARED_USERS`) is the union of
  every shared mailbox, so any agent that loaded it could read all of them (R1),
  and its write-class tools were bounded only by the matrix and the prompt (R2).
  New PreToolUse **Track 2g** gates every `mcp__m365-mail__*` call that carries a
  `shared_user` against the instance-only `.shared_mailboxes.by_agent` policy:
  the agent must be allowlisted for that mailbox (case-insensitive `upn`);
  `scope: "read"` allows list/get/search/download only, `"readwrite"` adds
  create/update/mark/move/delete; unknown verbs are denied. The CEO-present main
  thread is governed by `.shared_mailboxes.main_thread`: `explicit` (default,
  needs `by_agent.cos`), `ceo_present_read` (read any allowlisted mailbox) or
  `deny`. Every gated call is written to `security_audit_log` (`high` on deny,
  `info` on allow) and a deny notifies. No `by_agent` key ⇒ no-op; calls without
  `shared_user` are untouched. Schema documented in JUVANT_OS.md and
  `.juvant/config.example.json`.
- **Audit-spool drain statement allowlist (decisions#303 R3, security_audit_log#154).**
  `helpers/drain-audit-spool.sh` used to execute every line of the agent-writable
  `.juvant/audit-spool.sql` (and of stranded `.draining.<pid>` / `.merge.<pid>`
  batches) verbatim with the hook's DB credentials — an SQL injection channel
  (e.g. a planted `INSERT INTO decisions (… approved_by='ceo')`). Each line is now
  matched strictly against the closed set of statement shapes the framework
  writes (Track-3 `agent_actions_log` INSERT/UPDATEs, `security_audit_log`
  incident rows, `agents` status UPDATEs, `session_snapshots`, the two `messages`
  writers, `agent_token_usage`): statement type, table, exact column list, the
  UPDATE SET/WHERE skeleton, and literal-only values (quoted string, number,
  `NULL`, or the writer's constant) — no subquery, function call, operator or
  stacked statement. A non-matching line is not executed: it goes to
  `.juvant/audit-spool.quarantine` (next to the spool; follows `JUVANT_SPOOL`),
  and the run writes one `high` `security_audit_log` row (category
  `spool-injection`, synchronous, never via the spool) and sends a
  fire-and-forget alert on the Track 2e notification path with only a
  sanitised excerpt. If the quarantine file cannot be written, the line is kept
  unexecuted in the spool and still reported. `audit-reconcile.sh` no longer
  spools its `UPDATE decisions` on a transport failure (it retries on its next
  run), so no write to `decisions` is ever accepted from the spool. Drain test
  fixtures that used non-production statement shapes now use the real ones; new
  `tests/helpers/test-drain-statement-allowlist.sh`.
- **Audit immutability at the DB level + append-only `audit_events` (R5b/R5c;
  decisions#303/#304/#308, security_audit_log#155/#161/#163).** Audit rows had
  been DELETEd (security_audit_log 91–95, evidence lost) and edited in place
  (`created_at` rewrites, a silent severity downgrade, labels on hook rows); SQL
  fed via stdin, a redirect or direct HTTP bypasses every Bash-level rule, so the
  control now lives in `scripts/schema.sql` triggers:
  - `security_audit_log`, `agent_actions_log`, `decisions`: `DELETE` aborts, and
    `INSERT OR REPLACE` onto an existing id aborts. Evidentiary columns are
    immutable; `decisions.approved_by/approved_at` and
    `agent_actions_log.input_summary` are set-once (NULL → value); an
    `agent_actions_log` row is frozen once it leaves `pending`.
  - `created_at` must be the DB clock (±120 s) on INSERT into
    `security_audit_log`, `decisions`, `audit_events`
    (`agent_actions_log.started_at` stays hook-set, decisions#298).
  - New INSERT-only `audit_events` table (`status_change` / `note` /
    `severity_change` / `timestamp_correction` / `test_artifact` / `closure`).
    Corrections, closures and test-artifact marks require `authority_ref` → a
    CSO-authored decisions row with a rationale (CEO ruling decisions#308). Views
    `security_audit_log_current`, `decisions_current` expose current state;
    `security_audit_verdict_severity_violations` lists CSO verdict rows
    (`category='audit-verdict'`) below their audit's highest finding (also
    enforced at INSERT).
  - New invariant SYSTEM_INVARIANTS §10; cso.md / cetho.md / cos.md / eng-lead.md
    / JUVANT_OS.md now annotate and close via `audit_events`.
  - **Deprecated (accepted for one minor version):** lifecycle UPDATEs of
    `security_audit_log.status/resolved_at` and
    `decisions.status/executed_by/executed_at/source_ref` — new writers record
    events. All current writers (approval, execution, audit-reconcile,
    post-tool-use/-failure, the drainer's `terminated` reconcile,
    governance-backfill 0b/0d) keep working; governance-backfill `--apply`
    phase 0a (category remap) and the rationale-suffix appends are now rejected
    by design.
  - **Adopter migration: run `bash scripts/migrate.sh` (and
    `bash scripts/migrate.sh --project=<slug>` for each project DB).** Idempotent;
    it also adds any column the guards reference that an old DB lacks. Existing
    rows are preserved as written and become protected. Tests that truncate
    these tables in a fixture DB must lift the guard explicitly (see
    `t_purge` in `tests/hooks/run-tests.sh`).
  - Tests: `tests/schema/test-audit-immutability.sh` (fresh, migrated-from-pre-R5
    and old-shape project DBs; wired into lint.yml "Schema validators");
    `tests/schema/validate.py` asserts the schema.sql and migrate.sh copies of
    every R5 trigger/view are identical.

### Fixed

- **An Edit whose `old_string` has a multi-byte character at byte 80 was
  blocked.** The Track 3 summary cut `old_string` with `head -c 80` (bytes),
  splitting the character; the SQL escape (`sed`) then aborted with "illegal
  byte sequence" and, under FEAT-061 `onFailure:"block"`, the hook failure
  blocked the tool call. Truncation is now character-safe and every SQL escape
  in the hooks runs under `LC_ALL=C`, so a stray byte can't fail it again.
  Regression test in `run-tests.sh`.
- **Tests that fake the DB fake both transports (decisions#303 G6).** Since
  decisions#276 the cloud DB layer writes over libsql HTTP (curl), but seven
  helper tests still faked only the turso CLI, so their writes went down the
  real network path, failed and spooled — passing for the wrong reason. They now
  also install `tests/hooks/fake-libsql-curl.sh`. Two guards keep it that way:
  `tests/sync/test-fake-db-pairing.sh` (every test that installs `fake-turso`
  must install `fake-libsql-curl`; in CI) and a final "spool empty after a full
  drain" assertion in `tests/hooks/run-tests.sh` and the space-access canary.
- **Test suites pass on adopters, not only upstream (decisions#302; found syncing
  v1.12.0-9 into an instance, CSO verdict security_audit_log#154).**
  - `tests/sync/test-sync-compile.sh`: `cd "$REPO" || exit 1` (ShellCheck SC2164
    failed every adopter shellcheck job). Test-whitelist completeness now counts
    a file as framework-owned only if it exists in the framework tree (HEAD in
    the framework repo, `upstream/main` in an adopter; skipped with neither), so
    instance-local tests are no longer flagged.
  - `tests/hooks/run-tests.sh` is isolated from the instance config: it exports a
    non-instance `JUVANT_CONFIG`, and the main-thread role fallback in
    `pre-tool-use.sh` / `post-tool-use.sh` / `post-tool-use-failure.sh` now
    honours `JUVANT_CONFIG` (BUG-056 consistency; unchanged in production). On an
    adopter the main thread resolved to `cos`, whose allow-list pre-empted 9
    Track 2f verdicts, and Track 2d read the instance's github scope.
  - `tests/hooks/track2b/run-tests.sh` repaired (ported from the adopter copy):
    reads `hookSpecificOutput`, passes `JUVANT_CONFIG`, no `((PASS++))` abort
    under `set -e`, project `url` key; now in CI (closes juvant-os-pm#180).
  - `t_seed_agent` is an upsert (no more "UNIQUE constraint failed: agents.role").
  - Allow-list FIRST_TOKEN drops a glued control operator (`ls; …` reported the
    binary as `ls;`).

## [1.13.0] — 2026-10-28 — Guardrail hardening from the CSO 5-layer audit (decisions#298 / #300)

### Security

- **PreToolUse wrapper fails closed when the gate script is missing (decisions#298,
  CSO audit 2026-10-28 L5-F1a, SECURITY).** The registration wrapper was
  `[[ -f pre-tool-use.sh ]] && exec ...; exit 0`: with the script deleted or renamed
  it returned 0 (allow), so FEAT-061 `onFailure:"block"` never engaged and all gates
  went dark. It now prints to stderr and `exit 2`s. Observational hooks are
  unchanged (a missing session hook must not wedge a session). `lint.yml` asserts the
  PreToolUse wrapper ends in `exit 2`, and the behavioural test
  `tests/hooks/test-pretooluse-wrapper.sh` (decisions#300 item 6) runs the wrapper
  exactly as Claude Code does, from both the template and `.claude/settings.json`:
  script missing → exit 2 (blocked) with a stderr reason; present script's verdict
  passed through; observational wrappers still exit 0 on a missing script.
- **Track 2f tamper floor covers every write path it missed (decisions#300 items
  4 + 9, security_audit_log#148b).** The floor matched only a redirect / `tee` /
  `sed -i` naming a guardrail file, so `git checkout|restore|rm|mv`, `cp`/`ln`
  onto a hook, `rm -rf hooks/lib`, `find hooks … -delete`, `cd hooks && rm …`,
  compound commands and interpreter writes (`python3 -c "open('hooks/…','w')"`,
  `node -e`, `perl -pi`, heredoc-fed interpreters, `bash -c`, `$(…)`) all passed
  — the interpreter route was exercised for real on 2026-10-28. The Bash check is
  now a quote-aware per-segment scan: a segment that references a guardrail path
  (file, `hooks/`/`hooks/lib/` directory or glob) is allowed only for a
  recognised read-only verb (`cat`/`grep`/`diff`/`shellcheck`, `git
  diff|log|show|status|add|commit`, running a hook…), any redirect onto one is
  denied, and an interpreter / inline code / substitution / heredoc in a command
  that mentions one is denied outright. The single sanctioned write is the
  Upstream sync apply step, `git checkout upstream/main -- <file>` (or `git
  restore --source=upstream/main`), and only while `upstream` is the canonical
  `juvantlabs/juvant-os` remote. **Item 9:** `tests/hooks/` is no longer matched
  (the old `(^|/)hooks/` regex blocked a 2-line test fix on the adopter repo).
- **SessionStart guardrail integrity check (decisions#300 item 13 — the
  detection half of security_audit_log#148).** New `hooks/lib/hooks-integrity.sh`,
  called from `session-start.sh`: every `hooks/*.sh`, `hooks/lib/*.sh` and
  `hooks/bash-policy.json` must be a blob that `hooks/` has held somewhere in
  `upstream/main` history (canonical upstream remote), so an instance behind
  upstream passes while any byte upstream never shipped — committed or not —
  fails; a deleted guardrail file fails too. No recorded baseline to re-record.
  Without a canonical `upstream/main` ref it falls back to working-tree-vs-HEAD.
  Findings go to SessionStart stdout (session context, for CoS to surface) and an
  `agent_actions_log` row (`tool_name='HooksIntegrity'`); never blocks. Skipped in
  framework dev (same tri-state as Track 2f). Added to the sync whitelist.

### Changed

- **Upstream sync lands through a PR, never a direct push to `main`**
  (decisions#300 item 11). `JUVANT_OS.md` "## Upstream sync" now applies the
  approved files on a `sync/upstream-<tag>` branch, pushes the branch and opens a
  PR against `main` (`gh` wrapped with `helpers/with-timeout.sh`) so CI runs
  before merge. The CEO merges, and the Skill never falls back to
  `git push origin main`. Smoke tests run on the branch, and the decisions row is
  marked `executed` only after the merge. Trigger: security_audit_log#146 found 9
  sync pushes that reached `main` without CI. The `juv-upstream-sync` command
  stubs now describe the same flow.

### Fixed

- **Audit-trail integrity (decisions#298, CSO audit 2026-10-28 L1-F1/L1-F2).**
  - `helpers/drain-audit-spool.sh` now re-claims batches stranded by a drain that
    was killed mid-loop (`audit-spool.sql.draining.<pid>` / `.merge.<pid>`). A file
    is stale when its owner pid is gone or it is older than
    `DRAIN_STALE_MAX_AGE_MIN` (default 60); a live drain's file is never touched.
    Stale batches are applied before the live spool with an idempotence guard
    (session + agent + tool + args_hash, plus `started_at` when present) so a
    partially-applied batch does not duplicate rows. Originals are preserved as
    `backups/audit-stale.*` (newest 20 kept); a WARN names every reclaimed batch.
  - `hooks/pre-tool-use.sh` stamps an explicit `started_at` (hook clock, UTC) on the
    spooled `agent_actions_log` INSERT, so rows carry the action time instead of the
    drain time. Fixes skew in orphan checks, continuity-gap and halt-window
    attribution.
- **Gate read precision — reads stop being denied as writes (decisions#300 items 5
  + 12, security_audit_log#150).** Three false-deny classes with one root cause
  (scanning quoted text as if it were shell code / a SQL statement head):
  - **Track 2b (§4b/§4c)** treated `replace(` and any write verb anywhere in the
    command as a write, so a read-only `turso db shell project-x "SELECT
    replace(a,'b','c') FROM t"` from a company agent was denied. SQL writes are now
    detected per statement, after stripping SQL string literals and comments, with
    the verb anchored at statement start (`INSERT` incl. `INSERT OR REPLACE`,
    `UPDATE`, `DELETE`, `REPLACE INTO`, `CREATE/ALTER/DROP TABLE`, or a `WITH …`
    CTE leading into one). `REPLACE` alone is the string function. Heredoc SQL and
    stacked statements are still caught.
  - **Universal deny-list / Track 2d** matched prose inside quoted arguments of
    non-simple commands (a decisions INSERT whose rationale mentioned a pause
    window hit the `halt` rule). They now scan a prose-free view: quoted literals
    containing whitespace are emptied, single-word literals only unwrapped (so
    `rm -rf "/"` is still denied). Any command that evaluates text as code (`bash
    -c`, `| sh`, `eval`, interpreters, `$(…)`, backticks, `$'…'`) keeps the full
    view, and the SQL-content rules (DROP/TRUNCATE/`scope='global'`) always do.
  - **Allow-list** resolved a one-line `for …; do cmd; done` to an EMPTY first
    token (and skipped `do cmd` lines). Shell keywords now resolve to the command
    they introduce on the same line.
- **decisions#300 (item 7) — spec-marking gate Path 1 is actor-scoped, and
  partial progress is expressible.** The ADR 0029 stamped-`spec_id` path of
  `hooks/lib/spec-marking-gate.sh` had no agent filter on the main-thread `Stop`
  hook, so a *subagent's* `JUVANT_EXECUTING_SPEC=<id>` stamp blocked the CoS turn
  — on 2026-10-28 it looped ~10 times on a partially-executed spec until the spec
  was split. A stop now considers only the stopping agent's own stamps: a
  subagent's `SubagentStop` its own role's rows; the main-thread `Stop` only
  main-thread rows (`agent` = `$AGENT_ROLE` / `cos` / `unknown`, as
  `pre-tool-use.sh` records them). New **`JUVANT_SPEC_PARTIAL=<id>`** Bash
  prefix acknowledges a multi-step spec as in progress: the same agent's marker,
  at or after its latest execution stamp, clears the gate while the decision
  stays `approved` (never falsely `executed`); a later stamp re-arms it, and a
  denied command never counts. Read from the existing `input_summary` — no
  schema change, no `pre-tool-use.sh` change. The block message now offers the
  marker; documented in `JUVANT_OS.md` (spec 5-check, item 3). Residual: `agent_id` is not
  persisted, so two concurrent same-type subagents in one session share the role
  key. Path 2 (PR-merge recovery) is unchanged.
- **Declared pause windows are now honoured by every audit surface
  (decisions#300 item 15; closes decisions#269 / decisions#270).** Only the CSO
  bootstrap audit consulted `master_context.halt_windows`; `cso-weekly-audit.sh`
  merely named the key in its alert text and `audit-reconcile.sh` ignored it,
  so a declared 17-day closure raised a CRITICAL cadence alert. The window logic
  now lives in one shared lib, `hooks/lib/pause-windows.sh` (added to the
  framework whitelist), used by `scripts/audit-bootstrap-baseline.sh`,
  `helpers/cso-weekly-audit.sh` and `helpers/audit-reconcile.sh` with identical
  semantics: a gap fully covered by declared window(s) raises no alert; a
  partially covered gap is judged on its **uncovered** portion only (this also
  fixes the old rule that a window had to run through *today*, so a closure that
  ended yesterday no longer alerts); activity dated *inside* a window (e.g. rows
  replayed from a stranded spool) is reported as INFO, never as an alarm; with
  no windows key, behaviour is unchanged. A malformed declaration suppresses
  nothing. The key is `halt_windows` (the BUG-070 note in 1.12.0 said
  `pause_windows`; corrected — nothing ever read or wrote that name).
- **macOS "every N minutes" schedules now actually fire (decisions#300 item 14).**
  `helpers/install-schedules.sh` emitted `drain-audit-spool` (5 min),
  `anomaly-check` and `drain-outbox` (15 min) as launchd `StartInterval` jobs,
  which never ran on their own on a live install (runs=0 after bootstrap; no
  scheduled run after a manual kickstart), while the `StartCalendarInterval`
  jobs on the same machine ran on time. Root cause (verified live): macOS **Low
  Power Mode** puts the `gui/<uid>` launchd domain in *on-demand-only mode*
  (launchd log: "pending spawn, domain in on-demand-only mode";
  `launchctl print`: "pended nondemand spawn = interval"). `StartInterval` is a
  non-demand spawn and is held indefinitely; calendar-interval events and
  `kickstart` are demand spawns, so they kept working. They are now emitted as
  `StartCalendarInterval` arrays of `{Minute}` slots (same semantics as the Linux
  cron `*/N` entries, and a firing missed during sleep runs on wake). The loader
  now waits for the asynchronous `bootout` to finish before `bootstrap`, and runs
  `launchctl enable` to clear any persisted disabled override. A new
  **post-install self-check** kickstarts each interval job once and fails the
  installer (non-zero exit, clear stderr) if its launchd `runs` counter does not
  advance within a bounded timeout, if the job is disabled, or if launchd shows a
  pended non-demand spawn for it (the Low Power Mode state a kickstart alone can't reveal)
  (`JUVANT_SCHED_SELFCHECK=0` to skip; skipped by default when `CI=true`;
  `JUVANT_SCHED_SELFCHECK_MODE=scheduled` waits for an unprompted scheduled run
  instead). Linux/cron path unchanged. Regression test:
  `tests/helpers/test-install-schedules-interval.sh`.
- **Adopter tests no longer drift from the hooks they test** (decisions#300 item
  10). `tests/` was on the sync "NEVER touched" list while `hooks/` synced. When
  `hooks/lib/db.sh` moved to libsql HTTP `/v2/pipeline`, instance test fakes
  kept mocking the old transport, and about 20 hook tests failed on an adopter.
  The framework-owned test files (`tests/hooks/` runners, fakes and fixture,
  `tests/helpers/test-*.sh`, `tests/sync/test-sync-compile.sh`) now join the
  framework whitelist as an **explicit file list, never a glob**. Instance-local
  tests (for example `tests/hooks/test-<instance>-*.sh`), `tests/fixtures/` and
  `tests/integration/` remain untouched. Sync warns when `hooks/` or `helpers/`
  are approved without their tests. `tests/sync/test-sync-compile.sh` now
  enforces three rules: every framework test file is whitelisted by full path,
  no `tests/` glob is allowed, and the PR-only sync flow is in place.

## [1.12.0] — 2026-10-28 — Claude 5.5 agents, fail-closed guardrails, spec-execution marking

### Added

- **ADR 0028 + ARCH-017 — spec-execution marking is enforced, not remembered.**
  The ARCH-013 "mark executed immediately" protocol is now mechanically enforced
  in two layers. **Layer 2** (`helpers/audit-reconcile.sh`) auto-closes the
  *verifiable* subset of stale specs — `pr-spec` / `gh-issue-spec`, company scope,
  `approved → executed` only, when **exactly one** merged PR / issue references
  `decisions#<id>` — writing only the close-set (`executed_by='audit-reconcile'`),
  never INSERTing; ambiguous cases stay alert-only (bounded §4c maintenance
  carve-out). **Layer 1** (`hooks/lib/spec-marking-gate.sh`, shared by
  `subagent-stop.sh` and `stop.sh`) blocks a stop when a PR merged this session
  references an approved, still-unmarked spec, with a self-remediating
  instruction; it fails open on any missing link, so it cannot deadlock. CC's
  honoring of the block was confirmed live (2026-07-14). The `pr-spec` /
  `gh-issue-spec` authoring contract now **requires** `decisions#<id>` in the
  PR/issue body.
- **ADR 0029 — spec-marking for artifact-less Bash executions.** A landing Bash
  command prefixed `JUVANT_EXECUTING_SPEC=<id> <cmd>` is stamped by
  `pre-tool-use.sh` onto the new nullable `agent_actions_log.spec_id` column
  (idempotent `migrate.sh` ALTER), and the Layer-1 gate blocks while that spec is
  still `approved` — pure-DB, works without `gh`. Bash-landing only (Edit/Write
  have no per-call channel); the 5-check rejects an artifact-less plan without the
  prefix.
- **ADR 0030 (Proposed) — scope-aware spec-marking**, with the interim guard
  shipped (see BUG-060 below).
- **ADRs 0031 / 0032 / 0033 (Accepted)** — package Juvant OS as a plugin for
  distribution, hybrid with `compile-templates` (agents stay filesystem-compiled,
  since plugin subagents ignore per-agent `mcpServers`/hooks); agent memory stays
  on Turso (the client-side memory tool isn't adoptable in the Claude-Code-hosted
  harness); Claude Mods are **not** adopted (unsandboxed, expand the threat model).
- **Canon coherence verifier** (`tests/verify-canon.py`,
  `.github/workflows/canon-coherence.yml`) — a 9-class identifier guard that fails
  CI when the canon prescribes an identifier the schema/GitHub/agent inventory
  rejects (trigger case: the `gh-execution-confirmed` category); 18-fixture
  self-test wired into `lint.yml`. Adds `.juvant/config.example.json`.
- **`drain-audit-spool.sh` pre-drain backup** — timestamped backup before the
  spool rename (fail-closed: drain deferred if the backup can't be made),
  line-count integrity check, retention prune (`DRAIN_BACKUP_RETAIN`, default 7;
  `JUVANT_BACKUP_DIR` override).
- **Schema category drift guard** (`tests/schema/validate.py`) — fails CI if the
  `decisions.category` allowlist drifts between `schema.sql` triggers and the
  `migrate.sh` patch strings.

### Changed

- **FEAT-059 — Model refresh to the Claude 5.5 line + per-agent `effort`.** All 21
  agent manifests (12 company, 8 project, 1 component) move off the 4.x generation
  to current, verified model IDs (confirmed against platform.claude.com/models;
  all 1M-context, dateless pinned snapshots), preserving each role's existing
  capability tier (generational bump, no re-tiering):
  - **`claude-opus-5-5`** (effort `high`) — governance tier: `cos`, `cso`, `clo`,
    `cetho`, `cto`, and the component `maintainer`.
  - **`claude-sonnet-5-5`** (effort `medium`) — drafting/exec + project leads:
    `cco`, `cfo`, `chro`, `cmo`, `cro`, `eng-platform`, `vpe`, `pca`, `eng-lead`,
    `design-lead`, `product-lead`.
  - **`claude-haiku-5-5`** (effort `medium`) — high-volume project engineers:
    `eng-ai`, `eng-api`, `eng-backend`, `eng-frontend`.
  Adds the new `effort:` frontmatter field (CHRO may tune it against ranking data).
  The runtime CoS model-override mechanism is unchanged.

- **FEAT-061 (SECURITY) — PreToolUse gate is now fail-closed (`onFailure:"block"`).**
  The `PreToolUse` hook registration (`scripts/templates/hooks-registration.json`,
  synced into `.claude/settings.json`) sets `"onFailure": "block"`, so a
  `pre-tool-use.sh` that can't start, times out, or exits non-0/non-2 now **blocks**
  the tool call instead of failing open ("no decision → tool runs" — the BUG-053 /
  BUG-073 class). Third layer behind the existing `hookSpecificOutput` deny + exit-2.
  Requires Claude Code v2.1.295+ (silently inert on older clients). A `lint.yml`
  check enforces the field on PreToolUse, its absence on observational hooks (where
  Claude Code ignores it), and settings↔template hook-block parity. See `hooks/README.md`.

- **FEAT-064 (SECURITY) — guardrail-config tamper floor.** `pre-tool-use.sh`
  Track 2f denies `Write`/`Edit` and Bash writes (redirect / `tee` / in-place
  `sed`) targeting the structural-safety files — the hook gate scripts
  (`hooks/*.sh`, `hooks/lib/*.sh`) and the universal deny-list
  (`hooks/bash-policy.json`) — so an agent cannot weaken its own guardrails
  mid-session (closes e.g. `echo … > hooks/bash-policy.json`, which the per-agent
  allow-list alone passes via `FIRST_TOKEN=echo`). The deny is audit-logged
  (Track 3) and inherits the FEAT-061 fail-closed posture. `.claude/settings.json`
  is intentionally excluded (the Skill edits its `permissions.allow` /
  `additionalDirectories` legitimately; its changes are recorded by the
  ConfigChange hook — FEAT-062). Adopter-scoped via tri-state
  `JUVANT_FRAMEWORK_DEV` (1 exempt / 0 enforce / unset auto-detect `origin`).
  Hook suite 208/208.

- **FEAT-062 — ConfigChange forensic logging.** New `hooks/config-change.sh`
  (registered via the canonical hook template) records a row in `agent_actions_log`
  for every configuration/skill change during a session (`source` + `file_path`;
  event schema verified live on CC 2.1.312). Log-only / non-blocking: a ConfigChange
  `decision:"block"` only stops the running session from hot-reloading the change,
  it does **not** revert the on-disk write — so this hook is the **detection** half;
  tamper **prevention** (a PreToolUse write-deny on the guardrail files) is tracked
  separately (FEAT-064). Scope note: `PreModelSwitch` and `PermissionRequest`/
  `PermissionDenied` from the original FEAT-062 bundle were dropped as inert in this
  architecture (the CoS model-override is already logged in `decisions`; `acceptEdits`
  mode + hook-based deny mean those permission events don't fire). Hook suite 197/197.

- **FEAT-063 — `headersHelper` for remote MCP auth.** README §3 now recommends a
  dynamic `headersHelper` (fresh header map per connection) over static headers /
  baked tokens for remote (`type: http`) MCP servers, plus a scoping note: an MCP
  `permissions.allow` rule reaches only the named server and MCP requests no longer
  follow redirects — scope servers per agent via `mcpServers:` frontmatter
  (ADR 0003). Nothing in-repo needed changing (OP-010).

- **Execution confirmation is a status transition on the spec row**
  (decisions#274). The `eng-lead` / `product-lead` templates prescribed a
  follow-up `decisions` row with category `gh-execution-confirmed`, which the
  schema allowlist rejects. Confirmation is now the originating spec row reaching
  `status='executed'` with `executed_by` / `executed_at` / `source_ref` — already
  enforced by the schema triggers.

### Fixed

- **BUG-073 (SECURITY) — universal `rm`/`kill` deny rules didn't match the
  operative forms.** Two `deny_patterns` used PCRE `\s`, which bash ERE reads as
  a literal `s`, so `rm -rf / --no-preserve-root`, `rm -rf /` inside `$(…)` and
  `kill -9 1 -s KILL` were **allowed** by the universal floor. Rules are now
  anchored to a real token boundary.
- **BUG-072 (SECURITY) — turso SQL mode disarmed the universal deny-list for
  compound commands.** The BUG-066 SQL mode activated on any command whose first
  token was `turso`, so `turso db shell db "SELECT 1" && <anything>` bypassed all
  25 universal patterns and the Track 2d single-writer gate — reachable by every
  role. SQL mode is now scoped to a single simple command.
- **BUG-066 — false denials on SQL payloads.** Universal `deny_patterns` and
  Track 2d matched prose inside SQL string literals (e.g. a rationale mentioning
  `shutdown` or `git commit`). Turso SQL payloads are now checked against a
  dedicated, statement-anchored `sql_deny_patterns` list.
- **BUG-065 / BUG-065-write / BUG-071 (SECURITY) — the cloud DB layer silently
  failed.** `juvant_db_query_csv` passed a `--output csv` flag the turso CLI never
  had (errors swallowed by `2>/dev/null`; the test shim accepted the invented flag),
  so `anomaly-check` never ran and `morning-brief` sent false all-clears.
  `juvant_db_exec` hid lapsed auth behind `>/dev/null 2>&1`, so helper writes never
  landed. `juvant_db_query` returned the column header as data, treated an empty
  result as non-empty and stripped spaces inside text columns. All three cloud paths
  now go through the libsql HTTP `/v2/pipeline` API with output byte-identical to
  local `sqlite3`; errors are surfaced and empty ≠ failure. Transport failures on
  writes spool to `.juvant/audit-spool.sql` for retry; DB errors fail loud.
- **BUG-070 — false continuity findings in the bootstrap audit.** The Layer 5
  continuity check fired on any empty table. It now measures a windowed gap
  across `agent_actions_log` / `messages` / `session_snapshots`
  (`CONTINUITY_WARN_DAYS=14`, `CONTINUITY_FAIL_DAYS=30`), honours a non-empty
  spool, and suppresses declared `halt_windows`.
- **BUG-064 (SAFETY) — `migrate.sh --dry-run` wrote the database.** In the
  default schema-apply mode `--dry-run` was ignored: the schema and trigger
  DROP/CREATE were applied and "success" printed. Dry-run now writes nothing.
- **BUG-063 — every CSO audit `decisions` INSERT was rejected.** The CSO
  categories `system-audit`, `incident-response`, `security-remediation` were
  missing from the schema allowlist; added to `schema.sql` and the `migrate.sh`
  patches (with a CI drift guard, see Added).
- **BUG-062 — scheduled helper logs went headers-only after the 8th run.** The
  log prune replaced the file via `mv`, orphaning launchd's stdout fd; it now
  truncates in place (same inode) in all four helpers.
- **BUG-061** — the sync reminder told adopters to run
  `bash scripts/migrate.sh schema-apply` (exit 1); corrected to the bare command.
- **BUG-060 — cross-scope false-block in the spec-marking gate.** Project specs
  live in project DBs with colliding ids, so a project session could be blocked
  on an unrelated company decision. Interim guard (ADR 0030 step 1): the gate acts
  only on company-scope sessions and company-repo merges; otherwise it fails open.
- **BUG-059 — company-init `notifications` block written at the config root.**
  Shipped code reads `.notifications.*`, so every Telegram/Teams send silently
  skipped. The template now wraps the block in `"notifications": { … }`.
- **BUG-056 / BUG-057 / BUG-058 — spec-marking hardening from live adoption.**
  Track 2b now honours `$JUVANT_CONFIG` like Tracks 2c–2e; `github_repos` is
  documented in the company-init config (both layers failed open silently
  without it) and a WARN is emitted when the repo is unresolved; the Layer-1 gate
  drains the audit spool before querying, so just-happened merges aren't missed.
- **BUG-055 — `turso` missing from the allow-list for `cto`, `design-lead`,
  `eng-frontend`** despite the tool matrix granting it; added, plus an invariant
  test that every matrix turso grant is in the allow-list.
- **BUG-054 — `VAR=<url> binary` falsely denied.** `pre-tool-use.sh` stripped
  paths before recognising an inline env-prefix; it now skips all leading
  assignments to the real binary, and bare URL tokens get a distinct
  `deny:parse:` reason. Fail-closed before, so no bypass.
- **BUG-077 — synced agent-template changes weren't recompiled.** The upstream
  sync recompiled only when `compile-templates.sh` itself changed, so a template
  change left projects/components running stale compiled agents (or reintroduced
  `{{PLACEHOLDER}}`s at company scope). It now recompiles at the matching scope
  whenever a template changes. `compile-templates.sh --help` now documents
  `--scope component --component=<slug>`.
- **BUG-053 (SECURITY) — PreToolUse deny was silently unenforced (legacy output
  format).** `hooks/pre-tool-use.sh` emitted the decision in the legacy
  top-level form `{"permissionDecision":"deny",…}`. Claude Code 2.x honors a
  deny only in the `hookSpecificOutput` wrapper
  (`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",…}}`);
  the top-level form is **silently ignored for MCP (`mcp__*`) tools** — the hook
  fired and logged `status='denied'`, but the tool executed anyway. Since this
  is the single shared emission path, the same gap applies to the Bash
  single-writer / deny-list gate. Live-caught by an instance smoke test: a
  non-allowlisted agent created a folder in a Universal-CONFIDENTIAL space
  (Track-2e / ADR 0025) despite a correct deny being computed and logged. The
  existing hook tests asserted the *script's* stdout, not Claude Code's
  enforcement, so a static "coverage confirmed" review missed it. Migrated allow
  and deny to the `hookSpecificOutput` wrapper; added a regression asserting the
  wrapper shape (`hookEventName=PreToolUse`) and the absence of the legacy
  top-level key; migrated all decision-reading tests to the new JSON path.
  End-to-end enforcement must still be verified live per instance (a unit test
  cannot prove Claude Code honors the decision). **Defense-in-depth:** a deny now
  ALSO hard-blocks via **exit code 2** (reason on stderr) — the mechanism Claude
  Code honors uniformly for built-in and MCP tools, independent of any stdout
  JSON-schema evolution — so the security deny no longer rides on schema-honoring
  alone. A live instance retest confirmed the whole PreToolUse gate (not just
  MCP) was advisory-only on CC 2.1.201 before this fix.
- **BUG-052 — `agent_actions_log` rows leak as `pending` forever (audit
  under-reporting).** Async / fire-and-forget tools (`SendMessage`,
  `ExitPlanMode`) get no synchronous `PostToolUse`, so the finalizing UPDATE in
  `post-tool-use.sh` never matches their `pending` row (empirically:
  `SendMessage` 0 finalized across all history); spool tail-loss on
  SIGKILL/hook-timeout leaks a further ~5-10% of sync-tool rows. The work always
  completed — only the audit close-out was lost — but Layer-5 agent-action
  telemetry and cost/ranking inputs under-reported, and `audit-reconcile` kept
  alarming on the backlog. Added a boundary reconcile in
  `helpers/drain-audit-spool.sh`: after a successful drain — the one point where
  every spooled INSERT/UPDATE is in the DB — it finalizes `pending` rows older
  than 1h to a new terminal status `terminated`. Deliberately placed in the
  drainer, **not** in `session-end.sh` / `subagent-stop.sh`, where the current
  session's audit rows are still in the spool (drained only at the next
  session-start) and a DB sweep would miss exactly the rows it must close.
  Regression test covers the sweep, the 1h in-flight grace, and non-mutation of
  finalized rows.
- **BUG-051 — `session-end.sh` could be cancelled at exit ("Hook cancelled").**
  The SessionEnd hook issued the three FEAT-035 wrap-up `COUNT(*)` queries as
  three *serial* Turso round-trips. Each is bounded per-call by the db.sh
  hard-timeout (BUG-046), but nothing bounded their sum — on a slow/stalled
  cloud provider the serial total could exceed the window Claude Code grants
  shutdown hooks, so the runtime cancelled the hook mid-flight. No data was ever
  at risk (agent-status, token-usage finalization, and the wrap-up reminder are
  all best-effort; the underlying queue/decisions/messages persist
  independently), but the finalization was skipped. Collapsed the three counts
  into **one** query returning a single `|`-delimited cell — one network
  round-trip — with a regression test asserting a single wrap-up round-trip and
  correct per-source reminder counts.
- **ADR-0026 anti-deadlock clause was missing from 14 of 17 agent templates.**
  The invariant — authorization is a verifiable *record* (`approved` `decisions`
  row / ratified `juvant:decision` / Track-1 token), there is no direct CEO→agent
  channel and an agent must never demand one, and the CoS relay of CEO
  authorization is trusted — lived in SYSTEM_INVARIANTS §4 but was restated in
  only 3 templates (cetho, eng-platform, maintainer). At runtime, an agent
  without the clause in its own manifesto fell back to demanding the CEO's
  "direct"/"non-relay" message — a channel that does not exist — and **deadlocked
  on every CEO-gated action** (a relayed approval was refused as carrying no
  authority, with no way to obtain an "authoritative" one). Added the clause to
  all 18 remaining templates (cco, cfo, chro, clo, cmo, cos, cro, cso, cto, vpe;
  pca, product-lead, design-lead, eng-lead, eng-ai, eng-api, eng-backend,
  eng-frontend). The clause also closes the relayer side: an agent that relays a
  CEO approval onward must materialize it as the verifiable record. 21/21 agent
  templates now carry it. (A reference invariant in a shared doc
  is necessary but not sufficient — the rule must be in each agent's own
  manifesto to resolve the runtime "relayed ⇒ no authority" annotation.)
  Follow-up (decisions#284): `cetho` and the component `maintainer` only
  referenced the invariant; they now carry the standalone clause byte-identical
  to the other templates, which ends the recurring adopter-sync diff.

## [1.11.1] — 2026-06-29 — Session lifecycle hooks capture stdin (redirect fix)

### Fixed

- **Session lifecycle hooks never captured stdin** (#69) — the 6 hooks
  (session-start/end, stop, subagent-start/stop, pre-compact) gated their read
  on `[ -p /dev/stdin ]` (named-pipe only), but Claude Code delivers the event
  as a redirect, so `session_id` was never captured and the hooks silently
  no-op'd ("SessionStart does nothing"). Now read on any non-terminal stdin
  (`[ ! -t 0 ]`), bounded by a 2s `read -t` (no `timeout(1)` dependency). A
  redirect-delivered regression test guards it (the prior pipe-based test
  passed even with the bug).

## [1.11.0] — 2026-06-29 — Document spaces + outbox + sensitive-space perimeter; guardrail hardening

### Added

- **ADR 0023** — provider-neutral document **spaces** (= §4 scopes). Default
  stays soft (personal drive); a space is promoted to an org-owned container
  (SharePoint site / Shared Drive) only when shared with an external third
  party, surgically. New `spaces.<role>` config block + `resolve_space()`;
  adopter guide `docs/DOCUMENT_SPACES.md`. Tracker ARCH-013.
- **ADR 0024** — outbound action queue: one canonical Turso `outbox` table for
  side-effecting MCP operations (approval inside the queue; per-operation
  activation via rubric, not per-MCP). New `helpers/drain-outbox.sh` (readiness
  surfacer; dispatch agent-mediated). Tracker ARCH-014.
- **ADR 0025 + Track 2e (ARCH-015)** — document-space access control: MCP-scope
  is a sequenced prerequisite of promotion, access-aware `resolve_space`, and a
  hook-enforced perimeter for sensitive (Universal-CONFIDENTIAL) spaces. The
  per-operation deny-list was proven in an instance then harvested into the
  framework hook as `pre-tool-use.sh` **Track 2e** (policy-driven from
  instance-local `.security.space_access[]`), with the standing canary
  `tests/hooks/test-space-access-policy.sh` wired into CI.
- **ADR 0026** — authorization is a verifiable record, not a message: closes the
  direct-CEO approval deadlock.
- **ADR 0027** — separate the framework agent **template** from compiled output
  (canon via INCLUDE + instance overlay).
- **ADR 0021 / ADR 0022** — branch protection admins-exempt for single-identity
  repos; remote authenticated MCP servers via `mcp-remote` + `dotenv-cli` stdio
  bridge.

### Changed

- **Renamed the abstract `buffer` MCP role to `social`** (FEAT-056) — the role
  name no longer leaks a provider (`buffer` was misleading, like naming `bank`
  "UniCredit"). `social` is an abstract role bound per instance to a provider
  (Buffer.com / Hootsuite / Sprout); the framework ships no canonical server.
  CMO Content Scheduling Protocol now stages through the `outbox` (justified by
  the CEO-approval-before-publish invariant; any plan cap / rotating queue is
  instance config, not framework).
- **Scheduled helpers route through `hooks/lib/db.sh`** (#65) — `anomaly-check`,
  `audit-reconcile`, `morning-brief`, `cso-weekly-audit`, `activity-digest` are
  now provider-agnostic (turso/cloud **or** local sqlite), timeout-bounded, and
  read the canonical `.db.url` key (with `.turso_url` fallback + legacy-config
  provider inference). They previously read the legacy `.turso_url` key only and
  FATAL-exited on v0.8 configs / silently no-op'd on local-sqlite adopters. Add
  a provider-aware CLI-presence guard so a missing CLI fails loud instead of
  shipping an empty Teams brief as "success".
- **upstream-sync hygiene** (#67) — whitelist gaps closed
  (`hooks/lib/track-tokens.sh`, `scripts/deadlines.json`, `agents/components/*/`
  never-touched); `compile-templates.sh --check-only` refuses to combine with
  the file-mutating `--rewrite-meta`; matrix/doc-drift corrections.
- Single-identity branch-protection rule is `required_approving_review_count=0`,
  not 1-with-admin-exempt (#55).

### Fixed

- **Hook audit-trail plumbing** (#66) — `post-tool-use-failure.sh` derived ROLE
  differently from the pre/post pair, so failed subagent tool-calls stayed
  `pending` forever; `post-compact.sh` truncated multi-line session snapshots
  (`tail -n 1` + turso whitespace-strip) — now base64 round-tripped;
  `drain-audit-spool.sh` re-queued the whole batch on a partial failure,
  duplicating audit rows — now drains one statement at a time.
- **`turso-backup.sh`** (#63) — the spec-class `ARCHIVAL-` retention grep matched
  nothing (`.dump` is positional; no bare `spec` category), so spec-decision
  history was silently subject to rolling deletion.
- **`install-schedules.sh`** (#64) — `audit-reconcile` ran on Sunday on macOS
  (launchd `Weekday 7` = Sunday, not Saturday), colliding with `cso-weekly-audit`.

### Security

- **Track 2d single-writer write-detection hardened** (#68) — closed confirmed
  bypasses where a non-writer agent could perform git/gh writes: `git -C <path>`
  / `--work-tree` directory-redirect (incl. `cd`-override and `..` traversal on
  the repo-scope check), `bash -c 'git push'` and other indirect-verb forms, and
  `gh api` writes via `--input` / lowercase or compact `--method`/`-X` /
  sibling-or-comment `-X GET`. **Track 4** spec-gate now distinguishes a missing
  spec from a DB-unreachable blip (no longer mis-instructs the agent to author a
  duplicate spec). **Track 2e** sensitive-space audit row moved off the gating
  path (async spool, FEAT-051). Comprehensive regression suite added
  (`tests/hooks/run-tests.sh`, 76 assertions; space-access canary, 26).

## [1.10.0] — 2026-06-22 — Repo-scoped write gate + compile --scope component

### Added

- **FEAT-055** `compile-templates.sh --scope component --component=<slug>` —
  robust maintainer compilation (parity with `--scope projects`): substitutes
  `{{COMPONENT_SLUG/NAME/REPO/TYPE}}` + operating name from `components[]`,
  writes `agents/components/<slug>/maintainer.md` (source pristine), symlinks
  `.claude/agents/<slug>-maintainer.md`. `juv-add-component` now calls it
  instead of a Skill Write+substitution step.

### Changed

- **FEAT-054** Repo-scoped single-writer gate (Track-2d). The gate previously
  authorized the writer *role*; it now confines git/gh **writes** to the
  writer's **owned repo/working-tree set**, derived from the registry:
  `components[].repo`/`working_tree` for a `*-maintainer`; a project's
  `github_repos[]` + `working_tree` + `additional_working_trees[]` for a
  `*-eng-lead` (**N repos supported** — e.g. `hardys` with many repos). The
  command's target is parsed from `cd <abs-path>` and/or `gh -R/--repo` /
  `api repos/<O>/<R>`; a target outside the owned set is denied, an
  undeterminable target **fails open** to the role gate (no false-deny on
  own-repo writes). `eng-platform` is company-broad and exempt. Both Track-2c
  (§9) and Track-2d now honor `JUVANT_CONFIG` for testability.
- **Multi-repo projects**: new `projects.<slug>.github_repos[]` field (the
  generalization of the singular `github_repo`; backward-compatible — a lone
  `github_repo` is treated as a one-element set). Components are the N=1 case of
  the same owned-set model.

Closes the two FEAT-053 follow-ups (#128, #129). Tests: hook suite 46/46
(9 new repo-scope cases incl. multi-repo eng-lead), `compile --scope component`
verified end-to-end, shellcheck clean.

## [1.9.0] — 2026-06-22 — Component-scope for library/MCP/toolbox repos

### Added

- **FEAT-053 / ADR 0020** Component-scope — a third, lighter tier below
  project-scope for single-responsibility `juvantlabs` repos (library /
  mcp-server / toolbox), so the long tail isn't forced into the full 8-agent
  project roster + project DB + board + `-pm`. Big products (e.g. `juvant-os`)
  stay full projects.
  - **`/juv-add-component`** (new command) + `agents/components/maintainer.md`
    template. Registers the component in `.juvant/config.json` `components[]`
    (no DB, no migration) and compiles one `<slug>-maintainer`.
  - **Maintainer** = principal/staff full-stack **+ AI/LLM** engineer that owns
    one repo end-to-end, **single-writer on its own repo only**, `model:
    claude-opus-4-7` (solo role, no safety net, episodic so cost-bounded).
  - **State lives on GitHub** (visibility-agnostic): backlog = Issues/Projects;
    decisions = in-repo ADRs + `juvant:decision`-labeled Issues; knowledge =
    in-repo docs/Discussions. No component DB, no rows in company
    decisions/KB, no `-pm`.
  - **CEO ratification preserved** via the `juvant:decision` label. Boot
    (step 4c) and wrap-up (step 1b) run one timeout-wrapped, best-effort
    `gh search issues --owner <org> label:juvant:decision state:open`
    (via `helpers/with-timeout.sh` — FEAT-052) and surface pending component
    decisions to the CEO. Routine Issues/PRs are not pulled.
  - **§4 intact**: the maintainer is a pure repo-writer. Track-2d's writer set
    gains `*-maintainer`; `bash-policy.json` gets a `maintainer` allow-list
    tier (git, gh, node/npm/npx, python, test tooling). No company-DB write
    scope, so the §4b/§4c scope checks are unchanged. BUG-049 role
    normalization maps `<slug>-maintainer` → `maintainer`.
  - **Working-tree access**: the component's `working_tree` is part of the
    registry and `sync-project-globs.sh` now folds `components[].working_tree`
    (+ `additional_working_trees[]`) into `.claude/settings.json` so the
    maintainer can edit its repo. Track-2c (§9 orchestrator boundary) extended
    to component trees — the orchestrator may not Write/Edit them; only the
    maintainer does. The `juv-add-component` flow runs the glob-sync.
  - **Boot/wrap-up surfacing** quotes the `juvant:decision` label
    (`label:"juvant:decision"`) and searches **per unique org** derived from
    `components[].repo` (multi-org safe).
  - **Testco**: new `single-component` scenario (company-init + one component)
    + a "Batch mode for component-init" Skill section + driver component-phase
    assertions (config registration, maintainer compiled, working_tree granted).
  - Closes all 10 findings of the pre-merge design review. Repo-scoped
    write-gate enforcement (FEAT-054) and `compile-templates --scope component`
    (FEAT-055) are tracked as follow-ups.

## [1.8.0] — 2026-06-22 — GitHub via gh CLI (no MCP) — ends agent stalls

### Added

- **FEAT-052** Dropped the deprecated `@modelcontextprotocol/server-github`
  MCP (npm: *"Package no longer supported"*); GitHub access is now the `gh`
  CLI. The MCP was the dominant remaining stall source after BUG-046/FEAT-051:
  its heavy ops (chiefly `create_pull_request_review`) hung, and **MCP tool
  calls have no client-side timeout** (internal to Claude Code), so a wedged
  call dead-locked the agent until the 600s stream watchdog. `gh` Bash calls
  **can** be timeout-wrapped — the whole point of going CLI-only.
  - `helpers/with-timeout.sh` — portable hard-timeout primitive
    (`timeout`/`gtimeout`/`perl` alarm; macOS has none of the first two),
    returns 124 on timeout. Wrap every GitHub call: `with-timeout.sh 60 gh …`.
  - `docs/MCP_INVENTORY.md`, `scripts/templates/v0-agent-tool-matrix.json`,
    `JUVANT_OS.md` — `github:read`/`github:write` MCP capabilities removed;
    GitHub documented as a gh-CLI capability. (Instance follow-up: drop the
    `github` block from `.mcp.json`.)

### Fixed

- **FEAT-052 / governance** Extended the Track-2d single-writer gate to gh
  **write** operations (`gh pr/issue/release/repo/secret/variable/workflow/
  label/project/gist` mutations, `gh api -X POST|PUT|PATCH|DELETE`, and
  `gh api` field-flags without `-X GET`) → eng-lead/eng-platform only, same
  policy as `git push/commit/merge`. Patterns: `bash-policy.json`
  `single_writer_gh_patterns`. Without this, removing the MCP's read/write
  split would have let any gh-allowed agent write to GitHub (§4 violation).
  Read-only gh (view/list/diff/checks/status, api GET, repo clone) stays open.
- **BUG-049** Track-2 Bash allow-list lookup is now project-prefix aware.
  Project agents carry a slug prefix in `agent_type` (`dog-ai-eng-lead`) but
  `agent_allow` keys are canonical (`eng-lead`), so every **direct** git/gh
  command from a project agent was denied (only `cd`-prefixed compound
  commands slipped through — observed as 268 denied vs 122 success for one
  project eng-lead). `ROLE` is normalized to `LOOKUP_ROLE` (exact key, else
  longest `-<key>` suffix) for the allow-list only; scope/writer gates keep
  the full role. This also unblocks gh-CLI-only for project eng-leads.
- **BUG-048** Closed the last unbounded network calls in hooks:
  `notification.sh` curl now uses `--connect-timeout 5 --max-time 10`
  (Telegram + Teams); `session-end.sh` routes its wrap-up counts through
  `db.sh`'s timeout-wrapped `juvant_db_query` instead of a direct
  `turso db shell`.
- **BUG-050** CSO bootstrap-baseline audit no longer raises a false-P1
  `track-3-disabled` when the audit log is empty. Since FEAT-051 the Track-3
  writes are spooled (`.juvant/audit-spool.sql`) and drained out-of-band, so
  `agent_actions_log` is legitimately empty mid-bootstrap (rows pending
  drain) — which fired a false P1 on every first bootstrap (caught by
  testco: p1=1 vs the pre-FEAT-051 PASS baseline).
  `audit-bootstrap-baseline.sh` now drains the spool **before** checking the
  log (forensic state reflects reality at seal); an empty log with a
  populated spool is reported as `info` (`track-3-async-pending`), and only
  an empty log **and** empty spool remains a `track-3-disabled` finding.
  Also updated the 4 testco fixtures (`single-project`, `multi-project-vpe`,
  `single-company`, `manifesto-walk-through`) to drop the stale
  `github:read`/`github:write` `mcp_servers` assertions (FEAT-052 fallout).

## [1.7.0] — 2026-06-21 — DB calls off the gating path (timeout + async spool)

### Fixed

- **BUG-046** `hooks/lib/db.sh` DB CLI calls had no timeout while sitting on
  the tool **gating path**. `turso db shell` is a network call; under Turso
  latency / token refresh / a dropped socket it hangs forever, so the
  PreToolUse hook never emits its allow/deny decision → the tool never starts
  → the subagent produces no output → Claude Code's 600s stream watchdog
  fires (observed as "stalls" under ~16 parallel subagents). The `|| echo
  WARN` fail-soft only catches non-zero **exits**, never **hangs**. Worse,
  `db.sh`'s quiet-by-default `>/dev/null 2>&1` hid the hang (visible-fast-fail
  → invisible-stall), and stock macOS ships no `timeout`/`gtimeout`. Fix: wrap
  **every** `turso`/`sqlite3` invocation in a portable hard timeout
  (`timeout`/`gtimeout`, else a `perl` alarm — the macOS path), default 8s
  (`JUVANT_DB_TIMEOUT`). Infinite hang → bounded fail-soft.
- **BUG-047** `helpers/cso-weekly-audit.sh` was scheduled by
  `install-schedules.sh` but missing from the framework upstream-sync
  whitelist (same class as BUG-043) — the CSO weekly audit cadence never
  propagated to existing adopters. Added to the whitelist in `JUVANT_OS.md`.

### Added

- **FEAT-051** Audit-log writes moved off the tool gating path via an async
  local spool. The allow/deny decision never depends on the Track-3 audit
  write, yet it was executed inline (a network round-trip — or, pre-BUG-046,
  a hang — on every tool call). New `juvant_db_exec_async()` appends the
  statement to a local `.juvant/audit-spool.sql` (microsecond, network-free,
  hang-impossible; single physical line per statement so concurrent O_APPEND
  writes stay atomic). The pre-tool-use INSERT and post-tool-use UPDATE now
  spool. New `helpers/drain-audit-spool.sh` flushes the spool out-of-band:
  atomically claims the batch, applies it in order (INSERT before its
  UPDATE), and re-queues verbatim on failure (no data loss; eventual
  consistency — Track-3 is forensic, not real-time). Self-bootstrapping —
  drained in the background from `session-start.sh` on every session (no cron
  required) — plus a periodic 5-min schedule in `install-schedules.sh` for
  long sessions. Track-4 spec **reads** stay synchronous and rely on
  BUG-046's timeout. Drainer added to the upstream-sync whitelist; spool
  files gitignored.

## [1.6.0] — 2026-06-21 — Syncable framework hook-registration block

### Added

- **FEAT-050** Syncable framework hook-registration block. The `hooks` block in
  `.claude/settings.json` is framework boilerplate, but settings.json is on the
  upstream-sync "never touched" list (it also holds instance-specific
  permissions), so hook-infra fixes (e.g. BUG-045) could not reach existing
  adopters via `juv-upstream-sync`. New: the canonical hooks block lives in a
  whitelisted template (`scripts/templates/hooks-registration.json`), and
  `scripts/sync-hooks.sh` reconciles it into `.claude/settings.json` with jq —
  replacing only `.hooks`, preserving every instance-specific key, strict JSON,
  idempotent. Wired as a `juv-upstream-sync` post-apply step (runs when the
  template changed) and both files added to the framework whitelist. Hook-infra
  changes now propagate to existing adopters automatically.

## [1.5.4] — 2026-06-21 — Hook registrations anchored on CLAUDE_PROJECT_DIR

### Fixed

- **BUG-045** `.claude/settings.json` — all 11 hook registrations resolved their
  script path via `git rev-parse --show-toplevel` (cwd/git-dependent, suppressed
  with `2>/dev/null`). When `git` resolution failed for any reason (a subagent's
  cwd in a sibling repo with no `hooks/`; `git` absent from the hook env's PATH;
  `safe.directory`; non-git cwd) the `[[ -f ]] && exec` chain silently returned
  the failed test's exit code, surfacing as `<Hook>:<Tool> hook error — Failed
  with non-blocking status code: No stderr output` and, worse, **the hook did
  not run** (Track 2/3 enforcement skipped). Switch each wrapper to the
  documented stable anchor `${CLAUDE_PROJECT_DIR:-$(git rev-parse
  --show-toplevel 2>/dev/null)}` and append `; exit 0` so a legitimate no-run is
  a clean no-op. `CLAUDE_PROJECT_DIR` is exported to every hook process and
  points at the project root regardless of cwd or subagent context.
  NOTE: `.claude/settings.json` is on the upstream-sync "never touched" list, so
  existing adopters must apply this patch by hand; new adopters get it on fork.

## [1.5.3] — 2026-06-20 — sync-project-globs.sh strict-JSON rewrite

### Fixed

- **BUG-044** `scripts/sync-project-globs.sh` emitted invalid strict JSON.
  The BUG-032 sentinel-comment approach wrote JSONC-style markers
  (`// [sync-project-globs:start]` / `:end` / `:addir:start` / `:addir:end`)
  and a trailing comma after every managed entry — including the last —
  producing a trailing comma before the closing `]`. Claude Code parses
  `.claude/settings.json` as strict JSON (no comments, no trailing commas),
  so `/doctor` flagged the file as "Invalid or malformed JSON" on the
  first real sync. The script even self-documented the trap (the BUG-042
  `additionalDirectories` block was intentionally written via pure text
  surgery "because the file is no longer valid JSON at this point"). This
  revision rewrites the script around `jq` end-to-end: auto-managed
  entries are identified by **pattern** (Read/Grep/Glob with absolute-path
  globs in `permissions.allow`; the bare path in
  `permissions.additionalDirectories`), and the set of script-managed
  paths is persisted to a small sidecar
  (`.juvant/.sync-project-globs.state.json`) so stale entries get cleaned
  up when a project is removed from `.juvant/config.json` while any
  manually-added entries are preserved. Output is strict JSON — validated
  in-script with `jq empty` before the atomic write. Pre-existing
  sentinel-broken or pre-sentinel installations are auto-migrated on the
  next run by a one-shot regex sweep of any leftover absolute-path
  Read/Grep/Glob entries.

## [1.5.2] — 2026-06-19 — Propagate seed-matrix + VERSION via upstream-sync

### Fixed

- **BUG-043** `JUVANT_OS.md` § Upstream sync — the framework whitelist omitted
  `scripts/seed-matrix.sh`, so its v1.5.1 security fix (the
  `cloud_provider=none` `cloud:write` drop) could not propagate to adopters'
  operational mirrors. Whitelisted `scripts/seed-matrix.sh`, its coupled
  canonical template `scripts/templates/v0-agent-tool-matrix.json`, and
  `VERSION` (adopters were otherwise frozen on their init-time framework
  version). The whitelist lives in `JUVANT_OS.md`, itself whitelisted, so the
  correction self-propagates on the next sync.

## [1.5.1] — 2026-06-18 — Seed-matrix cloud_provider drop + R3 hook blocklist + audit-script false-positives

### Security

- **`scripts/seed-matrix.sh`** — honor `feature_toggles.cloud_provider`
  when seeding the v0 `agent_tool_matrix`. The canonical template
  (`scripts/templates/v0-agent-tool-matrix.json`) `_doc` field declares:
  "with cloud_provider=none the cloud:write entry is dropped from
  eng-platform's row." Pre-fix the script did not honor that contract —
  every adopter (including `cloud_provider=none` single-Mac local-only
  setups) seeded eng-platform with `cloud:write`, granting cloud-mutation
  authority to an agent on an instance with no cloud control plane.
  Resolution rules: `cloud_provider ∈ {azure,aws,gcp}` → keep
  `cloud:write`; `cloud_provider=none` (default when absent) → drop.
  Class of bug: tool-matrix / seed drift enabling unauthorized agent
  cloud writes. Root-cause fix for the security-incident class where an
  agent in spec-only mode performed live `az` writes against a control
  plane it had no business addressing.
- **`hooks/bash-policy.json` + `hooks/pre-tool-use.sh`** — R3 defense-
  in-depth. New `agent_role_deny_patterns` field deny cloud-mutating CLI
  commands (`az` + write verbs; `aws` + write verbs; `gcloud` + write
  verbs; `terraform apply|destroy|import|state|taint|untaint|force-unlock|
  workspace new|workspace delete`) for any real agent role. Read-only
  invocations (`az ... show|list|account|version|help`,
  `terraform fmt|validate|plan|init|workspace|providers|version`)
  continue to pass. CEO/operator path (ROLE in {unknown, ceo, operator})
  is exempt — the human at the keyboard is exercising direct authority.
  Cloud mutations must only ever flow through the CEO-triggered
  `terraform-apply` GitHub workflow (gated by Track 4 deployment-spec /
  eng-platform-spec), never via local CLI from an agent.

### Fixed

- **`scripts/audit-bootstrap-baseline.sh`** Layer 3 — `.claude/settings.json`
  is JSONC (line comments + trailing commas tolerated by Claude Code's
  loader). Strict `python3 json.load` produced false `FAIL` verdicts on
  every adopter who legitimately commented their settings block. Switch
  to a JSONC-tolerant pre-pass (stdlib-only: strip `//` line comments
  outside strings + trailing commas, then strict parse).
- **`scripts/audit-bootstrap-baseline.sh`** Layer 4 — CI-trigger check
  inspected only `lint.yml` and only for a push-to-main trigger; but
  some workflows are legitimately `workflow_dispatch`-only and the real
  PR gate may live in any `.github/workflows/*.yml`. Now scans
  all workflows for any `pull_request` / `pull_request_target` trigger
  before flagging CI as incomplete.

## [1.5.0] — 2026-06-18 — Sibling-repo grants for project subagents

### Added

- **FEAT-049** `scripts/sync-project-globs.sh` — new optional
  `projects.<slug>.additional_working_trees` config field (list of absolute
  paths). Sibling repos beyond a project's primary `working_tree` — e.g. a `-pm`
  planning repo or a docs repo — are now wired into `permissions.allow` and
  `permissions.additionalDirectories` in the same managed sentinel blocks.
  Generic (no `-pm`-specific semantics). Closes the BUG-042 residual follow-up
  (`working_tree` was single-path).
- **ADR 0019** — model `juvantlabs` as a self-developing project: source-of-truth
  (dual working tree + release-tag boundary), upstream-sync under §4
  single-writer, the `program` convention vs a first-class abstraction,
  bootstrapping-recursion safety, and `labs.juvant.io` placement. Conclusion: no
  framework code/template change required; the existing project model already
  supports it.

## [1.4.0] — 2026-06-18 — CSO weekly audit cadence

### Added

- **CSO weekly audit cadence** (`helpers/cso-weekly-audit.sh`, FEAT-007) —
  scheduled Sunday 22:00 (launchd on Mac, cron on Linux). Checks
  `security_audit_log` for a `5-layer`/`bootstrap_baseline` entry within the
  last 7 days; if stale, escalates to CoS via a `messages` row
  (`type='escalation'`, `priority='critical'`, `notify_ceo=1`) so CoS surfaces
  it at next session start, and posts an AdaptiveCard to the `ops` Teams
  webhook. Config-driven company name; role-based references (CoS → CSO); no
  hardcoded agent identifiers.
- **morning-brief** fail-safe — surfaces a "Security audit overdue" section
  when the last full audit is >7d old, so the gap is visible even outside a
  Teams notification window.
- `helpers/install-schedules.sh` — wires the `cso-weekly-audit` launchd plist
  (Sunday 22:00) and cron line (`0 22 * * 0`) into the install/uninstall loops
  (Mac + Linux); job counts and the Windows manual-scheduling note updated.

## [1.3.1] — 2026-06-17 — Project-subagent sandbox access fix

### Fixed

- **BUG-042** `scripts/sync-project-globs.sh` — also wire
  `permissions.additionalDirectories` (not only `permissions.allow`) for each
  project `working_tree`. The allow-list removes the permission *prompt*, but
  project subagents run in a filesystem *sandbox* confined to `cwd +
  additionalDirectories + /tmp` — so a sibling code repo was still denied at
  the sandbox layer. Managed via a parallel sentinel block (idempotent,
  comment-safe; creates the array if absent, preserves manual entries). Also
  fixes a latent `allow` first-run splice that targeted the wrong array when
  `additionalDirectories` precedes `allow`, and corrects the misleading
  `JUVANT_OS.md` prose (permission layer → permission + sandbox layers).

## [1.3.0] — 2026-06-16 — Structural governance enforcement + single-writer & orchestrator boundaries

Validated end-to-end by the `single-project` testco batch on 2026-06-16
(`bootstrap_verdict=PASS`, all assertions satisfied).

### Added

- **FEAT-040** Governance enforcement — declarative → structural. Layer 0
  retroactive remediation (`scripts/governance-backfill.sh`), Layer 1
  structural DB triggers (decisions category + lifecycle), Layer 1d
  `input_summary` on `agent_actions_log` denied rows, Layer 3 spec-lookup
  gate (Track 4 in `pre-tool-use.sh`).
- **FEAT-047** Single-writer & orchestrator boundaries — Track 2d
  single-writer git gate (only eng-lead / eng-platform may commit, push,
  merge), Track 2c orchestrator boundary hook, §9 Orchestrator Boundary in
  `SYSTEM_INVARIANTS.md`, orchestrator contract block in `JUVANT_OS.md`.
- **FEAT-045 / FEAT-046** §4d project-scoped decision authorship invariant +
  Track 2b Case c semantic content check.
- **FEAT-044** ARCH-013 Task Brief Assembly + universal opening protocol.
- **FEAT-039** decisions ↔ GitHub issues bidirectional traceability.
- **morning-brief** redesign — decisions with titles, system health, scope
  violations.
- **ADR 0018** — de-scope the FEAT-025 dynamic bash escalation flow; the
  self-remediating allow-list deny message is the durable design.
- ADR index (`docs/adr/README.md`) backfilled with entries 0011-0017.

### Fixed

- **BUG-039** `pre-tool-use.sh` — self-remediating allow-list deny message
  (diagnostic prefix, no-retry, native-tool remedy); ends the ~50× file-I/O
  retry-loop.
- **BUG-040** `migrate.sh` — classify schema-patch errors instead of
  blanket-suppressing; a real `ALTER` failure no longer silently leaves a
  trigger-without-column drift.
- **BUG-041** `JUVANT_OS.md` — `knowledge_base` injection prose referenced
  non-existent `project_id` / `agent_role`; corrected to `source_project`.
- **BUG-038** `bash-policy.json` — introduce `read_utils` and `infra_cli` tiers.
- **BUG-037** `pre-tool-use.sh` — first-token extraction skips comments,
  keywords, and array lines.
- **BUG-036** `bash-policy.json` — add `Explore` subagent entry.
- **BUG-035** launchd plists — bake `PATH`+`HOME`; fail loudly if `turso` missing.
- **BUG-034** upstream-sync whitelist — include `agents/projects/*.md` base templates.
- `schema.sql` — restore `IF NOT EXISTS` on category-check triggers.
- FEAT-040 follow-ups — category allowlist (`legal`/`product`/`business`);
  lifecycle triggers fire on status transition only; governance-backfill
  bash 3.2 compat + category mappings; install-schedules / launchd wiring;
  shellcheck cleanups.

### Notes

- **VERSION** file corrected `0.8.2` → `1.3.0`. It had drifted — never bumped
  past 0.8.2 despite the 1.0.0–1.2.0 tags. `migrate.sh`,
  `compile-templates.sh`, and `run-testco-batch.sh` read this file.
- **CHANGELOG gap**: releases **1.1.2** and **1.2.0** were tagged without
  CHANGELOG entries; not reconstructed here. The log resumes at 1.3.0.

## [1.1.3] — 2026-05-16 — Bug fixes: project-scope audit, seed-matrix, and boot sequence

### Fixed

- **BUG-009** `hooks/session-start.sh` — `REPO_ROOT` unbound variable crash at
  SessionStart. Added `REPO_ROOT="$(dirname "$SCRIPT_DIR")"` after the
  `SCRIPT_DIR` assignment.
- **BUG-010** `JUVANT_OS.md` boot sequence — `inbound_queue WHERE category=`
  references a non-existent column; corrected to
  `json_extract(content, '$.category')=` (3 occurrences).
- **BUG-011** `JUVANT_OS.md` boot sequence — `<active_slug>` pseudocode did not
  clarify it maps to `projects.id`; inline note added.
- **BUG-012** `JUVANT_OS.md` — agents hallucinated non-existent columns
  (`messages.subject`, `messages.action_required`, `projects.slug`,
  `decisions.summary/subject/payload`, `knowledge_base.tags/scope`, etc.).
  Added **Schema quick-reference** table listing canonical column names for all
  8 frequently-queried tables, with explicit `NO <col>` warnings for the most
  common hallucinations.
- **BUG-013** `scripts/schema.sql` / `scripts/migrate.sh` — `disclosure_policies`
  missing lifecycle columns (`status`, `validated_by`, `validated_at`,
  `retired_at`, `ceo_approved_at`). Added columns to schema and idempotent
  `apply_schema_patches_*` helpers in migrate.sh (Turso does not support
  `ALTER TABLE ADD COLUMN IF NOT EXISTS`).
- **BUG-014** `hooks/bash-policy.json` — 7 C-suite agents (`cfo`, `clo`, `cmo`,
  `cco`, `chro`, `cetho`, `cro`) absent from `agent_allow`; every Bash call was
  denied, including `turso` and `jq`. Added `["git", "gh", "turso", "jq"]` for
  all seven.
- `helpers/kb-sync.sh` — `${REPOS[@]}` on an empty array crashes under `set -u`
  on bash 3.2 (macOS default). Guarded with `[[ ${#REPOS[@]} -gt 0 ]]`.
- `scripts/migrate.sh` — `--project=<slug>` now accepts both nested
  (`.projects.<slug>.db.provider`) and flat (`.projects.<slug>.provider`) config
  shapes for backward compatibility with instances initialised before the `.db`
  nesting was introduced.
- `scripts/migrate.sh` — `projects.maturity_status` added to column-patch list
  for existing adopter instances created before FEAT-023.
- `JUVANT_OS.md` framework sync reminder — referenced non-existent `--check`
  flag; corrected to `schema-apply`.
- `JUVANT_OS.md` / `hooks/bash-policy.json` / `helpers/kb-sync.sh` added to
  framework sync whitelist (were absent, causing no-op syncs after BUG-014 and
  kb-sync guard fixes).

## [1.1.0] — 2026-05-15 — Meeting transcripts, framework sync, knowledge pipeline

First v1.1 release. Three new Skill operations and the Knowledge Sync
Pipeline (FEAT-026). Requires `@juvantlabs/m365-graph-mcp-server@0.2.1`
for meeting transcript tools.

### Added

- **`m365-graph:list_meeting_transcripts` + `m365-graph:get_transcript`**
  (FEAT-010) — post-meeting Teams transcript analysis. CEO asks *"analyse
  the meeting with Sara Parise"*; CoS finds the event, retrieves the
  transcript, strips VTT markers, and produces a structured summary with
  action items routed to the owning agents via `inbound_queue`. Requires
  `@juvantlabs/m365-graph-mcp-server@0.2.1` with two new admin-consented
  delegated scopes (`OnlineMeetings.Read`, `OnlineMeetingTranscript.Read.All`).
  Implemented in `JUVANT_OS.md` § Skill operation: Analyse meeting.
- **`"Sync with framework"` / `"Aggiorna con il framework"`** (FEAT-029)
  — Skill operation that evaluates the company instance against upstream
  `juvantlabs/juvant-os`, presents per-category diffs (hooks, helpers,
  scripts, JUVANT_OS.md, etc.), and applies CEO-approved files via
  `git checkout upstream/main -- <file>`. Post-apply: reloads launchd agents,
  re-runs `compile-templates` if scripts changed, commits, pushes, runs
  smoke tests. **HARD-REQUIRED**: never applies without explicit CEO approve
  per category — silence = skip.
- **Knowledge Sync Pipeline** (FEAT-026) — SessionStart-driven source change
  detection. New `helpers/kb-sync.sh` runs at every session start (background,
  zero tokens, ~2-3s): hashes GitHub issues and Turso decisions, writes deltas
  to the new `source_snapshots` Turso table. CoS reads changed sources at boot,
  shows `delta_summary` per source, and offers CRO routing. If CEO approves,
  `Task(subagent_type='cro')` processes the deltas, writes structured entities
  to `knowledge_base`, then re-sends Morning Brief to Teams with enriched content.
- **`source_snapshots` table** in `scripts/schema.sql` — tracks content hashes
  per source (type, ref, hash, delta_summary, last_changed_at). Apply via
  `turso db shell < scripts/schema.sql` on existing instances.
- **CRO `Process Source Deltas` operation** in `agents/company/cro.md` —
  fetches changed content, extracts entities (person, contract, deadline,
  decision), writes to `knowledge_base` with `source_ref`, triggers
  Morning Brief on completion.

### Fixed

- **`hooks/*.sh` — cwd-independent path resolution** — all hook commands in
  `.claude/settings.json` now use `git rev-parse --show-toplevel` to find the
  project root at runtime. Previously, `bash hooks/stop.sh` failed with "No
  such file or directory" whenever the shell cwd had been changed to a different
  directory (e.g. `cd ~/Projects/m365-graph-mcp-server`). Now silently succeeds
  when cwd is outside the project's git tree.

## [1.0.1] — 2026-05-15 — Helpers operational + architectural improvements

Patch release. Fixes all scheduled helpers (notification, morning brief,
audit-reconcile, anomaly-check, turso-backup) for real-world use, plus two
architectural improvements to the Skill.

### Fixed

- **`hooks/notification.sh`** — three bugs corrected in sequence:
  (1) credentials read from `.notifications.telegram_*` path (not root-level);
  (2) stdin detection changed from `[ -p /dev/stdin ]` to `[ ! -t 0 ]` so
  here-strings from helpers are correctly parsed;
  (3) Teams payload changed from `{"text":"..."}` to AdaptiveCard JSON —
  Power Automate "Post card in a chat or channel" requires AdaptiveCard format.
  Also: `[ROLE]` prefix suppressed when `AGENT_ROLE` is not set (helpers are
  not agents; prefix was misleading).
- **`helpers/morning-brief.sh`** — four bugs corrected: company name path
  (`.company.name` not `.company_name`); turso output header skipping
  (`awk 'NR > 1'`); space-separated parsing (replaced `IFS='|'` with plain
  `read`); fiscal deadlines section removed (adopters have an accountant);
  Morning Brief now posts to Teams ops channel only (`JUVANT_TEAMS_ONLY=1`)
  as a structured AdaptiveCard with FactSet sections per topic. Kill switch
  and anomalies sections appear conditionally only when there is something
  to report.
- **`helpers/activity-digest.sh`** — same turso header-skip and space-separated
  parsing fixes as morning-brief.
- **`helpers/audit-reconcile.sh`** — two bugs: (1) `decisions.proposer_role`
  column does not exist — correct column is `decisions.agent`; (2) Homebrew
  PATH missing in launchd environment → `turso` not found (exit 127).
- **`helpers/anomaly-check.sh`** — Homebrew PATH fix + header-skip + IFS='|'
  parsing fix.
- **`helpers/turso-backup.sh`** — Homebrew PATH fix (launchd exit 127).
- **`helpers/anomaly-check.sh`** + **`helpers/audit-reconcile.sh`** — replaced
  non-existent `JUVANT_NOTIFY_PRIORITY=critical` env var with
  `JUVANT_NOTIFY_CHANNEL=system`. The priority variable was silently ignored by
  `notification.sh`; notifications were routed to the `approvals` channel
  (incorrect — that channel is for CEO approval queues). System-level security
  alerts now route to the `system` Teams channel + Telegram.

### Changed

- **`helpers/install-schedules.sh`** — `fiscal-deadlines.sh` removed from
  scheduled jobs (launchd/cron). The helper remains available on-demand;
  adopters with an accountant do not need automated fiscal alerts.
- **`helpers/morning-brief.sh`** — `alerts` channel removed from company-scope
  `teams_webhooks`; per-project alerts now live under
  `.projects.<slug>.notifications.teams_webhooks.alerts`.

### Added

- **`hooks/notification.sh`** — `JUVANT_NOTIFY_PROJECT=<slug>` env var for
  per-project Teams channel routing. Checks
  `.projects.<slug>.notifications.teams_webhooks[$channel]` first, falls back
  to company-scope channel. Enables project-specific alert channels (e.g.
  Hardys alerts → `#hardys-alerts`).
- **`hooks/notification.sh`** — `JUVANT_TEAMS_ONLY=1` env var to suppress
  Telegram delivery. Used by Morning Brief (long markdown → Teams only).
- **`JUVANT_OS.md`** — `proj.1.notif` wizard step: optional per-project Teams
  alerts webhook URL collected at project init.
- **`JUVANT_OS.md`** — boot sequence step 4 reads `knowledge_base` project-scoped
  when a project is active; project agent dispatch injects matching
  `knowledge_base` rows as `## Project context` prefix (ARCH-012).
- **`JUVANT_OS.md`** — `"Resync project agents for <slug>"` Skill operation:
  re-runs `compile-templates.sh --scope projects --project=<slug>`, shows diff,
  commits, triggers re-Tier-1 manifesto review. Safe because compiled files
  carry no project customizations post-ARCH-012 (FEAT-021).

## [1.0.0] — 2026-05-14 — First stable release

First production-ready release. All seven bugs surfaced during the first
real-world adopter migration (Juvant Srls, v0.6→v0.8.2) are resolved.
The multi-project compile path is correct and verified. The batch testco
single-project scenario passes with `bootstrap_verdict=PASS` and zero
P0/P1 security findings. The framework is adopter-ready.

### Fixed

- **BUG-001 — `compile-templates.sh`** — optional agents (`vpe.md`,
  `cro.md`) were always compiled regardless of `feature_toggles.vpe_enabled`
  / `feature_toggles.cro_enabled`. Script now checks each toggle before
  compiling. When an agent is disabled it is still compiled (to resolve all
  `{{}}` placeholders, keeping the source file clean for CSO Layer 5), but
  its `.claude/agents/` symlink is removed so the role is inactive at runtime.
- **BUG-002 — `agents/company/vpe.md`** — unresolvable `{{ENG_LEAD_NAME}}`
  placeholder survived in documentation prose, causing the compile residue
  check to fail for any adopter enabling VPE. Placeholder removed; plain text
  used in its place.
- **BUG-003 — `.github/CODEOWNERS`** — template used the obsolete
  `{{CA_GITHUB}}` placeholder (renamed to `{{CTO_GITHUB}}` at v0.8.0).
  `compile-templates.sh` had `CTO_GITHUB` in its substitution map but the
  template still referenced the old name, leaving the CODEOWNERS file
  unresolved after company init.
- **BUG-004 — `compile-templates.sh --scope projects`** — wrote compiled
  project-scope agent files in-place to `agents/projects/*.md`. For
  multi-project adopters, each subsequent project compile overwrote the
  previous one's output silently. Fixed: compiled output now lands in
  `agents/projects/<slug>/`; source templates in `agents/projects/*.md`
  remain pristine and are never modified. After each file, the script wires
  `.claude/agents/<slug>-<role>.md` symlinks automatically.
- **BUG-005 — `hooks/lib/db.sh`** — `juvant_db_query` returned scalar
  results padded with whitespace from the `turso db shell` output. String
  comparisons (`== "0"`, `COUNT(*) > 0`) silently failed, producing false
  P1/P2 findings in the CSO bootstrap baseline audit for all Turso adopters.
  Output is now stripped before returning.
- **BUG-006 — `JUVANT_OS.md` Step 9.8** — the Bootstrap Protocol promoted
  agent manifests to `operational` by updating the `manifests` table but
  omitted the corresponding UPDATE on the `agents` table. The CSO audit
  subsequently flagged agent-manifest-drift on every subsequent audit run.
  Both tables are now updated in the same step.
- **BUG-007 — `scripts/migrate.sh`** — the v0.7→v0.8 migration idempotency
  check included `AND scope='company'` in its SQL guard. The v0.8
  `agent_tool_matrix` schema is scope-less by design (scope is encoded by
  the DB file, per ADR 0014 §4); the column does not exist, causing SQLite
  errors and silent guard bypass so the migration would re-run on an already-
  migrated database.
- **Agent frontmatter — `mcpServers` split from `tools`** — all company-
  and project-scope agent templates had MCP server identifiers listed inside
  the `tools:` frontmatter field. Claude Code resolves `mcpServers` from a
  separate frontmatter key; mixing them caused sub-agents not to see their
  MCP servers. All agent templates now use `mcpServers:` and `tools:`
  separately.
- **`.claude/settings.json`** — narrow `.env.*` deny patterns from a blanket
  `Edit/Write(**/.env.*)` to an explicit list of token-bearing variants.
  The blanket pattern captured `.env.example` (a documentation-only template),
  causing adopters to be prompted on every edit of that file. Explicit deny
  list now covers `.env`, `.env.local`, `.env.production`, `.env.development`,
  `.env.staging`, `.env.test`, `.env.secrets`, `.env.private`, `.env.azure`,
  `.env.aws`, `.env.gcp`. `.env.example` is no longer denied.

### Changed

- **`JUVANT_OS.md` — company-init wizard** — bank provider binding step
  (Step 3) removed. The two planned banking MCP servers (`finom-mcp-server`,
  `aruba-fattura-mcp-server`) are deferred to the parking lot: the Finom
  Partner API is currently closed to new users (no timeline), and the Aruba
  MCP is blocked on the same infrastructure. Adopters who need banking read
  access today can wire a provider-specific MCP server manually after init.
  The `bank:read` entry in the agent tool matrix and `MCP_INVENTORY.md` is
  retained — it becomes a named slot that adopters fill when a compatible
  MCP server is available.
- **`agents/company/cos.md` + `SYSTEM_INVARIANTS.md` §8** — the CoS
  dispatcher pattern requires CoS to run as the main thread. Claude Code
  structurally prevents sub-agents from spawning nested sub-agents; the
  `Task` tool is unavailable to any sub-agent regardless of frontmatter.
  `Task` removed from `cos.md` tools: (dead-code when CoS is a sub-agent;
  available by default when CoS is the main thread). New §8 in
  `SYSTEM_INVARIANTS.md` documents the constraint and the broken invocation
  pattern. Callout added to `JUVANT_OS.md` § How this Skill works.
- **`README.md`** — complete rewrite. Adds CI/license/release/Claude badges.
  Removes all ADR inline references, parking-lot feature mentions, and
  changelog-style historical language. Roadmap uses sequential version numbers
  (v1.0, v1.1, v1.2) rather than release-phase labels (Alpha/Beta). Historical
  detail lives in this CHANGELOG; the README presents the project as it is today.

### Batch testco (internal)

The batch regression driver and single-project fixture received a set of
corrections as part of validating v1.0.0:

- `company_description` added to all testco fixtures — resolves `AGENT_DESCRIPTION`
  placeholder that CSO Layer 5 flagged when the field was absent.
- Fixture filesystem assertions updated from `agents/projects/*.md` to
  `agents/projects/<slug>/*.md` following the BUG-004 compile-path fix.
- Batch driver now sums `manifests` and `decisions` counts across the company
  `state.db` and all per-project databases, not just `state.db`. Combined
  counts reflect the full bootstrap output.
- Budget cap raised from $6.5 to $10 for the single-project scenario.
- `matrix_rows_count` corrected to 20: all 12 company-scope roles are always
  seeded (including disabled ones), with invocation gated by symlink presence.

**Verdict on commit `ce39b5e`:** `bootstrap_verdict=PASS`, all 19 assertions
satisfied, zero P0/P1 security findings, project CSO `bootstrap_baseline` audit
fired and completed.

## [0.8.2] — 2026-05-10 — Documentation refresh — propagate v0.8 vocabulary to README + docs + adopter templates

Docs-only patch. Surface-level files that describe Juvant OS structure
still cited v0.7 role identifiers + agent counts after v0.8.0 +
v0.8.1 shipped. No code or behavior changes; pure prose alignment.

### Changed

- **`README.md`** — agent tree, company-agent table (split mandatory 9
  + toggle-gated 3), project-agent table (8 per project; renamed
  identifiers), GitHub-MCP section (eng-platform + Eng Lead per scope),
  roadmap table (added v0.5, batch-testco, v0.8.0/v0.8.1 milestones).
  Cross-references to ADR 0014/0015/0016 added.
- **`docs/MCP_INVENTORY.md`** — owning-agent columns updated for all
  rows (ca→cto, cdo→Design Lead, github:write to eng-platform + each
  project's eng-lead per §4 single-writer-per-scope). New rows for
  `cloud:write` (eng-platform only, abstract, resolved per
  feature_toggles.cloud_provider) and `npm:publish` (eng-platform only,
  CEO-gated). Universal Boundaries section: forbidden grants
  re-expressed per scope. Adding-new-MCP-server procedure: CTO/CSO
  joint review + eng-platform / project's eng-lead execution.
- **`docs/branch-protection-spec.md`** — Application path documents
  the scope-determined executor (eng-platform for company repos /
  project's eng-lead for project repos). Re-application-after-sync
  flow: CHRO → CTO pr-spec → scope writer.
- **`plugins/README.md`** — Joint-review chain: CTO + CSO (was CA + CSO).
- **`scripts/templates/README.md.template`** (adopter README) — Bootstrap
  info section: 9 mandatory + toggle-gated optional roles (was
  "10 founding"); per-project agent count documented as 8.
- **`scripts/templates/CHANGELOG.md.template`** (adopter CHANGELOG) —
  Same correction; mentions feature_toggles + ADR 0014 §2 + ADR 0016.
- **`scripts/templates/docs-adr-README.md.template`** (adopter ADR README) —
  ADR authorship flow: CTO drafts cross-cutting; project PCA drafts
  project-scope. Spec executor by scope.

### Why a patch release for docs

These files render publicly on the OSS template's GitHub front page
and ship verbatim to every adopter via `compile-templates.sh
--rewrite-meta`. A v0.7-named README at v0.8.x reality is a friction
point for adopters following blog posts or the README in their fresh
fork — they'd hit role names that don't match the agent files
they're seeing. Tagging the docs refresh independently makes the
"docs match reality at this version" claim verifiable per-tag.

---

## [0.8.1] — 2026-05-10 — v0.8.0 follow-ups (driver iteration, [BATCH] split, F-24 DB routing prose)

Maintenance patch surfacing the four follow-ups identified during
v0.8.0 validation runs. No breaking changes; no migration required —
this patch only refines wizard prose + driver assertion logic.

### Changed — `scripts/run-testco-batch.sh` — multi-project assertion iteration

Driver previously read `.inputs.project` (singular) for project-phase
post-run assertions; multi-project fixtures using `.inputs.project_2`
(and future `.inputs.project_3`, …) had their per-project agent count
and CSO audit assertions silently skipped.

Now collects every `.inputs.project*` key in fixture order
(`project`, `project_2`, `project_3`, …) and iterates each through
the per-project assertion block:

- Per-project agent count: reads
  `.expect.project_phase.projects[slug=X].agents_count` when the
  multi-project array is present; falls back to the flat
  `.expect.project_phase.project_agents_count` for single-project
  fixtures; defaults to 8 per ADR 0014 §2 (project-VPE removed).
- Per-project CSO audit: queries
  `.juvant/project-<slug>.db.security_audit_log` first (F-24 v0.7.1+
  per-project DB routing); falls back to company `state.db` for
  pre-F-24 fixtures.

Closes the gap surfaced by `multi-project-vpe.yaml` testco run on
2026-05-10 (2 of 3 v0.8.0 assertion failures fell on this gap).

### Changed — `JUVANT_OS.md` — [BATCH] event channel-split clarified (F-26 follow-up)

Skill instruction for batch-mode event emission strengthened with an
anti-pattern callout: stdout lines get `[BATCH] ` prefix; file appends
to `.juvant/batch-events.jsonl` get raw JSON (NO prefix). v0.8.0
single-company testco run surfaced 115 malformed events where the
Skill double-applied the `[BATCH] ` prefix to file writes; driver
correctly dropped them with `WARN: dropping malformed [BATCH] event`
warnings but the noise floor was high enough to obscure real issues.
New anti-pattern block makes the channel-split unambiguous.

### Changed — `JUVANT_OS.md` — Project-bootstrap DB routing (F-24 follow-up)

Project-init Step 5 (project-bootstrap analog) prose strengthened
with an explicit HARD-REQUIRED DB-routing block. Per F-24 (v0.7.1+),
all project-scope rows (manifests, agents, decisions for
bootstrap-action, security_audit_log) MUST be written to
`.juvant/project-<slug>.db`, NOT the company `state.db`.

v0.8.0 single-project + multi-project-vpe testco runs surfaced the
Skill writing project manifestos to company DB despite the F-24 split
having existed since v0.7.1. The prose now includes an explicit
anti-pattern WRONG vs CORRECT block + the resolution path
(`.projects.<slug>.db.url` strip-`file:` → use for project INSERTs).

This is a wizard-prose fix, not a code change — the Skill reads
JUVANT_OS.md every run and the strengthened instruction reaches the
runtime decision-making path immediately.

### Filed — ARCH-010 in juvant-os-pm (#43)

Historical "what was renamed and why" reference document for adopters
arriving from blog posts citing v0.6 / v0.7 vocabulary. Cross-
references the full rename table (ADR 0014 §1), the migration script,
and the `role_aliases` table for audit-time joins. ADR 0014's
"Cross-references" footer already lists this destination; the issue
is the formal tracking ticket for the document creation.

### Cross-references

- v0.8.0 release: tag v0.8.0 in juvantlabs/juvant-os (commit 77613ca).
- v0.8.0 validation results:
  `tests/fixtures/testco/results/2026-05-10-{single-company,single-project,multi-project-vpe}.{md,jsonl}`.
- juvant-os-pm#43 — ARCH-010 document creation.

---

## [0.8.0] — 2026-05-10 — Tech leadership restructure + brand-spec authority + framework scope position (ADR 0014/0015/0016)

Major minor release. Three companion ADRs land in lockstep:

- **ADR 0014** — Tech leadership restructure (CTO promotion, project-scope
  rename, VPE toggle).
- **ADR 0015** — Design & brand ownership (CMO ↔ Design Lead split,
  3-mode brand-spec pattern).
- **ADR 0016** — Framework scope position (Juvant OS as software-
  development-flavored opinionated stack).

The release is invasive: ~40 files touched, ~1100 LOC churn across role
identifiers, agent templates, the matrix, the bash policy, the wizard, the
audit script, the schema, the migration script, and all four testco
fixtures. Adopters on v0.7.x must run `bash scripts/migrate.sh
--from=v0.7 --to=v0.8` to land on this baseline (see Migration below).

### ⚠ MIGRATION REQUIRED for v0.7.x adopter forks

```bash
# From the root of your adopter fork:
bash scripts/migrate.sh --from=v0.7 --to=v0.8 --dry-run    # inspect first
bash scripts/migrate.sh --from=v0.7 --to=v0.8              # apply
git fetch origin && git merge origin/main                  # pull v0.8 framework changes
bash scripts/compile-templates.sh --scope company          # recompile placeholders
bash scripts/compile-templates.sh --scope projects --project=<your-active-project-slug>
bash scripts/audit-bootstrap-baseline.sh --scope=company   # verify v0.8 expected-roles
```

The migration script:
- Renames agent files in place (`git mv` preserving compiled per-company
  content + history).
- Creates the `role_aliases` table (audit-time joins for renamed roles
  per ADR 0014 §7).
- Updates active `agents` and `agent_tool_matrix` rows; supersedes legacy
  rows; leaves historical rows in `manifests`/`decisions`/
  `agent_actions_log`/`inbound_queue`/`security_audit_log` UNTOUCHED
  (audit-time joins via `role_aliases`).
- Migrates `.juvant/config.json` `agent_names` keys + seeds
  `feature_toggles` defaults.
- Migrates `hooks/bash-policy.json` `agent_allow` keys.
- Does NOT re-run bootstrap.

A backup of pre-migration `state.db` is taken automatically:
`<state.db>.pre-v0.8.<utc-iso-timestamp>`.

New adopter forks (no prior bootstrap) start clean at v0.8.0 — no
migration needed.

### Changed — Role identifier rename (ADR 0014 §1)

Company scope:
- `ca` (Chief Architect) → **`cto`** (Chief Technology Officer). Restores
  industry alignment; acknowledges company-wide tech authority.

Project scope:
- `cto` (project) → **`pca`** (Project Chief Architect).
- `coo` (project) → **`eng-lead`** (Engineering Lead).
- `cdo` (project) → **`design-lead`** (Design Lead). Removes the Chief
  Data Officer collision surfaced in 3/5 preflight conversations through
  v0.7.x.
- `cpo` (project) → **`product-lead`** (Product Lead).

Eng/* identifiers (`eng-api`, `eng-backend`, `eng-frontend`, `eng-ai`)
unchanged.

Affects: every `agents/**/*.md` template, the `agent_tool_matrix` JSON
template, `hooks/bash-policy.json` keys, `compile-templates.sh`
placeholder substitutions, `audit-bootstrap-baseline.sh` expected-roles
list, `JUVANT_OS.md` wizard prose, all 4 testco fixtures, and
SYSTEM_INVARIANTS.md §1/§2/§4/§6/§7/Appendix.

### Changed — Project-VPE removed; optional company-scope VPE added (ADR 0014 §2)

Project-scope VPE is removed. Aggregator function (Eng/* day-to-day
delegation, model override, sprint coordination, release-spec authoring)
is absorbed by the project's `eng-lead`.

VPE returns at company scope as an OPTIONAL role gated by
`feature_toggles.vpe_enabled` (default false). When enabled, VPE
aggregates Eng/* status across ALL projects into a Weekly Engineering
Health Report, coordinates cross-project releases, receives cross-
project Tier-4 disclosure-cascade fallbacks. SKIP for single-project
shops — the company `cto` performs cross-project aggregation directly
when N=1.

### Changed — eng-platform expansion to company-scope sole writer (ADR 0014 §3)

`eng-platform` matrix row upgraded:

```
mcp_servers: ["turso", "github:write", "cloud:write", "npm:publish"]
```

Authority codified per §4 single-writer-per-scope:
- **Company scope** sole writer: `eng-platform` (company repos, cloud
  control plane, npm registry for canonical helpers).
- **Project scope** sole writer per project: project's `eng-lead`.
- Cross-scope writes are forbidden; the 5-check protocol verifies spec
  target scope before execution.

`eng-platform` is mandatory by default in v0.8.0
(`feature_toggles.eng_platform_enabled=true` per ADR 0016 — software-
flavored framework). Toggle OFF only for non-software adopters who run
no cloud / IaC / canonical-helper publishing surface.

`cloud:write` is an abstract MCP entry resolved at adoption time per
`feature_toggles.cloud_provider` ∈ {`azure`, `aws`, `gcp`, `none`}; with
`cloud_provider: none` the entry is dropped from eng-platform's row
(single-Mac local-only setups).

### Added — `eng-platform-spec` class (ADR 0014 §5)

New spec class covering company-level infra changes that don't fit
`pr-spec` or `install-spec` — IaC drift remediation, cloud control-plane
bumps, npm version cuts of canonical helpers.

Author = executor (the explicit exception to author/executor split,
because no other agent has both company-scope infra context and
company-scope writer authority). `cto` is approver-of-record at the
5-check protocol — that gate is what preserves the audit boundary.

`scripts/templates/v0-agent-tool-matrix.json` schema_version 2 codifies
this; `cso.md` Layer 5 audits read against the new spec class.

### Changed — SYSTEM_INVARIANTS.md §1 founding count parameterized (ADR 0014 §6)

```
N = (mandatory company)
  + (eng-platform if feature_toggles.eng_platform_enabled — default true)
  + (CRO          if feature_toggles.cro_enabled          — default false)
  + (VPE          if feature_toggles.vpe_enabled          — default false)
```

Default at v0.8.0 baseline: **N = 10** (9 mandatory + eng-platform on by
default). Adopter overrides at company init: +1 per optional role
enabled. Per-project agents (PCA + Product Lead + Design Lead + Eng Lead
+ 4 Eng/* = 8 per project) bootstrap at project-init AFTER company
bootstrap; not part of N.

`scripts/audit-bootstrap-baseline.sh` Layer 1 + Layer 5 read
`feature_toggles` from `.juvant/config.json` and compute the expected
count + expected-roles list dynamically. Layer 5 also checks toggle-
coherence per role: when toggle=true, file + matrix row must both
exist; when toggle=false, neither should leak.

### Added — Brand-spec class with 3-mode validator/advisory pattern (ADR 0015)

CMO is the canonical owner of company brand identity (logo system,
color tokens, typography, voice/tone, brand architecture across
sub-products) and the company brand book artifact.

NEW spec class: `brand-spec`. Carries a `mode` field:

- `inherit` — project visuals are a direct child of company brand. CMO
  validates against company brand book; CMO is approver of record.
- `extend` — project inherits some elements + invents others. CMO
  validates inheritance coherence + that invented elements don't break
  company-brand promises; CMO is approver of record.
- `independent` — project brand is intentionally separate (acquired
  product, sub-brand strategy, disjoint audience, portfolio play). CMO
  is **advisory only** (must NOT veto on grounds of divergence —
  divergence is the explicit point of the mode); CEO ratifies the mode
  once per brand; Design Lead executes; CMO advisory recorded in
  `decisions` category `brand-advisory`.

Audit boundaries (CSO Layer 5):
- `brand-spec` with `mode: independent` MUST have a corresponding
  `brand-mode-ratification` row from CEO. Missing = FAIL.
- CMO advisory in `independent` mode MUST NOT contain rejection-on-
  divergence language. Mode-laundering = FAIL.
- Brand-architecture document drift > 7 days from approved specs = WARN.

Design Lead authors brand-specs at project scope; CMO authors at company
scope. The full lifecycle is documented in `agents/projects/design-lead.md`
§ Brand-Spec Protocol and `agents/company/cmo.md` § Brand-Spec Authority
Protocol.

### Changed — Framework scope position (ADR 0016)

Juvant OS is positioned as a **software-development-flavored opinionated
stack** — not a vertical-agnostic operating system. Default-on
`eng-platform` reflects this; non-software adopters explicitly toggle
it off.

This is a positioning decision, not a feature change — the framework
already shipped IaC modules, CI/CD federation patterns, npm canonical-
helper publishing surface (FEAT-024), and software-engineering-shaped
agent roles. ADR 0016 names the assumption and lets the matrix +
config defaults reflect it cleanly.

### Added — `role_aliases` table in schema.sql

Audit-time joins for renamed roles. Populated by `migrate.sh` during
version-pair migrations; new v0.8 forks bootstrap with the table empty.
CSO Layer 5 audits join historical `manifests` / `decisions` /
`agent_actions_log` / `inbound_queue` / `security_audit_log` rows
against this alias table when reconciling activity-by-role across
version boundaries — without modifying historical rows themselves.

### Added — `multi-project-vpe` testco fixture

First fixture exercising `feature_toggles.vpe_enabled=true`. Two
projects (Apollo + Boreas) bootstrapped in sequence; verifies
manifest count = 11 (9 mandatory + eng-platform + vpe; cro off);
project agents = 8 each (project-VPE removed); company-scope
`agents/company/vpe.md` exists; `agents/projects/vpe.md` does NOT
exist (rename verification). Also confirms the cro-off + vpe-on
combination — i.e. that the two optional toggles are truly
independent.

### Removed

- `agents/projects/vpe.md` (cross-scope move to `agents/company/vpe.md`).
- `agent_names.ca`, `.cdo`, `.cpo`, `.coo`, `.vpe` keys at project scope
  (renamed in `.juvant/config.json` per migrate.sh; removed
  unconditionally for project-VPE).
- `bash-policy.json` legacy `ca` / `coo` / `cdo` / `cpo` keys (renamed).

### Deprecated

- v0.7.x adopter forks running on the old role identifier set are
  unsupported in v0.8.0. The migration script is the supported path;
  forks that don't migrate will fail bootstrap on the v0.8 audit
  (toggle-coherence + expected-roles list will mismatch).

### Cross-references

- `docs/adr/0014-tech-leadership-restructure.md` — full migration sequence.
- `docs/adr/0015-design-brand-ownership.md` — brand-spec lifecycle.
- `docs/adr/0016-framework-scope-position.md` — framework positioning.
- Handbook ADR 0004 (agent action guardrails) — Track 2 bash policy
  keys renamed in lockstep; Track 3 audit log rows pre-rename are
  preserved via `role_aliases`.
- `juvantlabs/juvant-os-pm` ARCH-010 (to be filed at v0.8.0 ship) —
  historical "what was renamed and why" reference for adopters arriving
  from blog posts citing v0.6 / v0.7 vocabulary.

---

### Added — `scripts/audit-bootstrap-baseline.sh` shipped (F-8 + F-11)

Canonical CSO `bootstrap_baseline=1` audit as a single Bash invocation.
Pre-v0.6.5 the CSO subagent issued ~30 inline `sqlite3 ... <<'SQL'`
heredocs and ~50 `grep / awk / find` invocations during the audit —
each tripping Claude Code's "shell syntax cannot be statically
analyzed" approval prompt. The Foxtrot Corp testco run on 2026-05-09
saw ~300+ approval prompts during a single audit, with the user
clicking through every one. F-8 collapses this to ONE allowlistable
invocation.

`scripts/audit-bootstrap-baseline.sh`:

- 5-layer audit encoded inline (access, secrets, network, code, agents).
- Outputs newline-delimited JSON findings on stdout. Schema:
  `{"layer":"...", "severity":"info|low|medium|high|critical",
  "finding":"...", "category":"..."}`.
- Plus a final summary line:
  `{"summary":true, "verdict":"PASS|WARN-WITH-CONDITIONS|FAIL", "counts":{...}}`.
- Verdict logic: FAIL on any critical/high; WARN-WITH-CONDITIONS on
  medium; PASS otherwise.
- The CSO subagent — NOT the script — is the source of truth for the
  audit verdict and writes the `security_audit_log` rows. The script
  encodes the WHAT; CSO interprets and decides severity per the cso.md
  persona. This preserves the v0.6.1 hard-required rule (Skill must
  not synthesize verdict / write audit rows directly) while
  eliminating the heredoc prompt-flood.

Folds in **F-11** (CSO query schema correctness) — the script's queries
use the canonical schema (`messages.from_agent` not `messages.agent`,
`agent_actions_log` for tool-call audit log, etc.), correcting the
schema mismatches CSO improvised in prior runs.

`JUVANT_OS.md` Step 9.7 prompt now instructs the CSO subagent to
invoke the script and interpret its output. `.claude/settings.json`
pre-allows `Bash(bash scripts/audit-bootstrap-baseline.sh:*)`.

Adopters running their first bootstrap audit see one approval prompt
(or zero, with `--permission-mode auto`) instead of 300+. Same family
as F-6 `compile-templates.sh` shipped in v0.6.4 — replacing
improvisation with a deterministic shipped helper.

### Fixed — Wizard MUST update `init_state` after every step (F-17)

Surfaced by the Foxtrot Corp testco run: the Skill wrote
`init_state: "step-1.5-in-progress"` early in the wizard but never
updated it — by Step 9 the field still said `1.5-in-progress` despite
9 subsequent steps complete. Recovery via re-run *"Initialize Juvant
OS"* would have restarted from Step 1.5 (re-asking 11 folder prompts)
instead of from where the CEO actually left off.

Fix in `JUVANT_OS.md` global wizard rendering rule: new HARD-REQUIRED
clause "Incremental config persistence". The Skill MUST re-write
`.juvant/config.json` after every step that collects new state,
updating `init_state` with the canonical step identifier
(`step-1-complete` → `step-1.5-complete` → ... → `bootstrapped`).
The Skill MUST write the updated value before any state-bearing
operation that follows the step. Mid-step abort recoverable to the
granularity of `init_state` at that moment.

### Fixed — Local SQLite hooks silently fail when wizard writes `db.url=file:...` (HIGH; F-20)

Surfaced by the Foxtrot Corp testco run on 2026-05-09. The wizard
sometimes writes `db.url = "file:.juvant/state.db"` (libsql URI form)
into `.juvant/config.json` for local provider — this is libsql-syntax
valid but our `hooks/lib/db.sh` and `scripts/migrate.sh` (v0.6.3)
passed the value verbatim to `sqlite3`, which interpreted it as a
literal path `<repo>/file:.juvant/state.db`. Result: silent
INSERT/UPDATE failures swallowed by `2>/dev/null`. Track 3 (audit log)
non-functional whenever the wizard chose the `file:` prefix variant.

Echo Corp run wrote `.juvant/state.sqlite` (no prefix) and worked;
Foxtrot wrote `file:.juvant/state.db` (with prefix) and silently
failed. Skill-side variation surfaced again — non-deterministic
config generation for the same `provider=local` choice.

Fix: `hooks/lib/db.sh` and `scripts/migrate.sh` strip the `file:`
prefix when resolving the local-provider filesystem path. Verified
post-hoc against the Foxtrot `state.db`: an `agent_actions_log`
INSERT that previously failed silently now writes the row.

### Fixed — Step 3 [5] Other branch must collect provider name + MCP URL (F-19 + F-18)

Surfaced by the Foxtrot Corp testco run on 2026-05-09: the CEO chose
`[5] Other` at Step 3 (Bank provider binding), and the Skill recorded
`bank.provider = null, bank.mcp_server = null` and advanced — without
prompting for the provider slug or MCP server URL. The doc said
*"Other (specify name + MCP server URL)"* but the Skill collapsed
the branch into a "skip" path.

Fix in `JUVANT_OS.md` Step 3:

- Menu now exposes both `[5] Other` AND `[6] Skip` as distinct paths.
- `[5] Other` HARD-REQUIRES two sub-prompts: provider slug, then MCP
  server URL/package. The Skill MUST NOT collapse these to null.
- `[6] Skip` is the explicit defer path; sets `bank.provider = null`,
  `bank.mcp_server = null` cleanly.
- Validation rule: any selection that ends with both fields null AND
  was NOT explicitly `[6] Skip` must re-prompt with the same options.

This closes F-18 (no input validation / no re-prompt on invalid bank
input) by folding it into the same Step 3 amendment.

### Added — Per-company file rewrites at bootstrap (F-16)

The OSS template at `juvantlabs/juvant-os` ships with framework-facing
`README.md` / `CHANGELOG.md` / `SECURITY.md` / `docs/adr/*.md` —
appropriate **upstream**, but wrong inside a per-company instance.
Pre-v0.6.5, every adopter who looked at their own private repo saw
"Juvant OS — The OSS multi-agent operating system" instead of their
own brand. Same for `docs/adr/`: framework-architecture decisions
(Skill-first, ADR 0010 symlinks, etc.) leaked into the per-company
namespace, blocking adopters from numbering their own ADRs from 0001.

Fix: new wizard Step 7.6 invokes `scripts/compile-templates.sh
--rewrite-meta`, which:

- Renders `README.md` from `scripts/templates/README.md.template` —
  company-specific landing page with name, domain, CEO, bootstrap
  date, audit verdict, "Powered by Juvant OS" footer, and an
  AUTO-GENERATED `Active projects` section (maintained by future
  Skill operations on project-init / maturity transition).
- Renders `CHANGELOG.md` from `scripts/templates/CHANGELOG.md.template`
  — empty `[Unreleased]` + `[0.0.1] — <bootstrap-date> — Bootstrap`
  initial entry. Tracks **company-specific** changes only; framework
  CHANGELOG stays at upstream.
- Renders `SECURITY.md` from `scripts/templates/SECURITY.md.template`
  — `security@<domain>` disclosure policy + 48h SLA + scope
  declaration. Framework-level SECURITY policy at upstream.
- Renders `docs/adr/README.md` from
  `scripts/templates/docs-adr-README.md.template` — company-scope
  ADR stub (numbering, Nygard form, authorship flow, examples).
- **Removes** all framework ADRs (`docs/adr/0001-*.md` through
  `docs/adr/NNNN-*.md`) from the per-company repo. Adopters read
  framework ADRs at upstream when they need to.

Bootstrap metadata (`bootstrap_completed_at`, `bootstrap_audit_verdict`)
is read from `state.db` `master_context`. Framework version is read
from a new repo-root `VERSION` file (`0.6.5`).

`JUVANT_OS.md` Step 10 git-add list extended with `README.md`,
`CHANGELOG.md`, `SECURITY.md`, `docs/adr/`, `VERSION`; uses `git add -A`
so the framework ADRs removed at Step 7.6 are picked up as deletions.

Validated post-hoc against the Foxtrot Corp testco state: all four
files rewrote with company-specific content; 10 framework ADRs
removed cleanly.

`LICENSE` is **not** rewritten by this step — adopters keep the
upstream MIT license unless they manually replace it post-bootstrap.
A future v0.6.6+ extension may add a wizard prompt for license choice.

### Added — `scripts/compile-templates.sh` shipped (F-6)

Pre-v0.6.4 every wizard pass at Step 7 (template substitution)
improvised an ad-hoc Python helper at a different path:

- Acme: `.juvant/_compile.py`
- Beta: `/tmp/compile_templates.py`
- Gamma: `/tmp/testco-bootstrap-manifestos.py`
- Delta: `.juvant/seed-manifests.py`
- Echo: `/tmp/compile_agents.py`

Five different paths across five testco runs. Different sessions
interpret the substitution rules subtly differently; inconsistent
behavior across adopters. Plus: each anonymous heredoc tripped
Claude Code's "shell syntax cannot be statically analyzed" warning,
contributing to the prompt-flood during the CSO subagent audit.

v0.6.4 ships `scripts/compile-templates.sh` — canonical Bash script
codifying the substitution rules:

- Reads identity, agent names, GitHub handles, and tunables from
  `.juvant/config.json` (with SYSTEM_INVARIANTS.md §2 defaults
  for tunables when not overridden).
- Walks `agents/<scope>/*.md` (default: company; `--scope projects`
  at project init).
- Substitutes whole-token placeholders only.
- Refuses to write (exit code 2) if any non-allowlisted placeholder
  survives. Allowlist: `ACTIVE_PROJECT`, `PROJECT_NAME` (runtime-
  bound at SessionStart / project init).
- `--codeowners` flag substitutes `{{*_GITHUB}}` in
  `.github/CODEOWNERS` (Step 7.5 deliverable).
- `--check-only` flag for dry-run validation.

`JUVANT_OS.md` Step 7 + Step 7.5 rewritten to invoke the script:
*"The Skill MUST invoke `bash scripts/compile-templates.sh --scope
company`."* The improvised helper anti-pattern is closed at Step 7.

`.claude/settings.json` pre-allows `Bash(bash scripts/compile-templates.sh:*)`
+ `Bash(scripts/compile-templates.sh:*)` + same for `migrate.sh` so
adopters don't get prompted during normal bootstrap. One named
allowlist entry per script vs N anonymous heredoc prompts pre-v0.6.4.

This is the first of three shipped-script fixes in v0.6.4. The other
two (`scripts/seed-matrix.sh` for F-7 and `scripts/audit-bootstrap-baseline.sh`
for F-8) require additional investigation:

- F-7 depends on F-12 (`coo.md` canonical v0 matrix has 11 errors
  the wizard auto-corrects; need to fix at source before encoding
  in a script).
- F-8 depends on F-11 (CSO query schema correctness; need to know
  which queries to encode).

Both deferred to a focused dogfood pass with explicit logging.

### Fixed — Wizard rendering rule amended with collection-collapse pattern (F-4 + F-5)

The v0.6.2 wizard determinism rule (HARD-REQUIRED one-question-at-a-time)
fixed the Delta Corp testco's batch-mode collapse but proved too rigid
during the Echo Corp testco run on 2026-05-09: the user faced 11
sequential prompts at Step 1.5 (folders), 4 at Step 1.5b (mailboxes),
6 at Step 4 (notifications), 20 at Step 9 (manifesto display + approve
× 10). Onboarding fatigue compounded by static-analysis approval
prompts during the CSO subagent audit (~300+ approvals).

v0.6.4 amends the rule with **two clauses**:

- **Clause 1 (unchanged from v0.6.2)** — identity-critical / branching
  fields render one question at a time, sequential, no batch.
  Step 1 identity (6 fields), Step 2 DB provider, Step 3 bank
  provider, Step 6 CRO enablement, Step 9 manifesto-approval mode.
- **Clause 2 (new, v0.6.4)** — **collection-collapse menu** for
  homogeneous collections of like-typed fields. Steps 1.5 / 1.5b /
  1.6 multi-human / 4 / 4.5 / 5 / 6 §2 names / 9 manifestos render
  a 4-option menu first:
    - [1] Accept all defaults (one approval, defaults applied)
    - [2] Edit specific (defaults + overrides)
    - [3] Walk-through every item (per-field prompts; v0.6.2
          fallback path)
    - [4] Skip the step (record as empty / null / fallback chain)

Path [1] for collections is **one decision** instead of N. Sandbox
and test instances pick [1] universally; production picks [3] for
the first bootstrap manifestos. v0.6.2 batch-mode prevention is
preserved by clause 1 + the menu-renders-verbatim requirement
(Skill emits exact text, no improvisation).

Per-step amendments:

- **Step 1.5 — folders**: header note documenting N=11 collection;
  default policy is function-centric layout.
- **Step 9 — manifestos**: full 4-option menu inlined verbatim.
  Path [1] writes all 10 in one transaction (10 manifests +
  10 agents + 10 bootstrap-action decisions). Path [3] is the
  canonical pre-v0.6.4 walk-through — kept as fallback for the
  production first-bootstrap. Path [4] keeps bootstrap NOT
  completed (master_context.bootstrap_completed_at stays NULL).

The two clauses together close finding #11 (wizard determinism)
in both facets: integrity (no batch-mode collapse on identity
fields) and UX (no N-prompt fatigue on collections).

### Fixed — v0.6.4 batch quick-wins (F-3, F-9, F-13, F-14, F-15)

Five small but adopter-visible fixes from the Echo Corp testco backlog,
batched together because each is a single-file change with clear
scope. Detail per finding:

- **F-3 — `hooks/bash-policy.json` CSO allow-list expansion.**
  Previous: `[git, gh, gpg, shellcheck, jq]` — too narrow for the
  audit job. CSO needs read-only access to query state, scan agent
  files, validate frontmatter. Expanded to: add `sqlite3`, `turso`,
  `grep`, `awk`, `sed`, `find`, `ls`, `cat`, `head`, `tail`, `wc`,
  `python3`. All read-only verbs; destructive `sudo`/`rm -rf`/`DROP`
  remain blocked by the universal deny-list.

- **F-9 — `.claude/settings.json` `defaultMode` policy + flag docs.**
  Kept the production-safe `acceptEdits` default (Edit/Write
  auto-accept, Bash prompts on each call). Added `README.md §
  Permission modes for sandbox / test contexts` documenting
  `claude --permission-mode auto` for trusted local work and
  `--permission-mode bypassPermissions` for `/tmp/<testco>` throwaway
  directories where the prompt cadence during the CSO audit becomes
  excessive (~300 prompts on the Echo run).

- **F-13 — `.mcp.json` first-run UX.** Pre-v0.6.4 shipped
  `.mcp.json` with the github MCP server pre-registered, requiring
  `GITHUB_PERSONAL_ACCESS_TOKEN` — every fresh adopter saw the
  *"Missing environment variables: GITHUB_PERSONAL_ACCESS_TOKEN"*
  warning at the first `claude` invocation. v0.6.4 ships an empty
  `mcpServers: {}` (with explanatory comment); README adds an
  `### Adding the github MCP server` section walking through PAT
  creation + env-var setup + `.mcp.json` snippet.

- **F-14 — `JUVANT_OS.md` Step 5 menu canonical pinning.** Previous
  prose said only *"Skip if CEO says 'no counterparties yet'"* —
  Skill improvised different menu UIs each session (Acme/Beta:
  4-option menu; Gamma: pipe-delimited; Echo: skip-only). Now the
  doc inlines the canonical 4-option menu verbatim
  (Skip / Sample / Walk-through / Custom); per the wizard
  determinism rule, Skill renders verbatim.

- **F-15 — `JUVANT_OS.md` Step 1.5 type-it slash-prefix caveat.**
  Claude Code's TUI interprets a leading `/` as a slash-command
  prefix; typing `/Echo Corp/01 - Legal` emits *"Unknown command:
  /Echo"* before the wizard recovers. Added a one-line caveat under
  the type-it path: *"Tip: paste folder paths verbatim — Claude
  Code may flag the leading `/` as an unknown command, but the
  wizard records the path correctly regardless."*

L1 4/4, L2 15/15, L4 10/10 PASS unchanged.

### Fixed — Layer 5 orphan-check SQL had wrong tool_name (HIGH; v0.6.4 patch #1)

Surfaced by the Echo Corp testco run on 2026-05-09 against post-v0.6.3
`main`. The v0.6.3 §11 detection SQL queries
`agent_actions_log.tool_name = 'Task'`, but Claude Code logs subagent
invocations with `tool_name = 'Agent'`. Result on every legitimate
audit: orphan check returns ALL CSO audit rows as suspect (11/11 false
positives in the Echo run), indistinguishable from the cover-up the
rule was designed to detect.

Fix: `tool_name IN ('Task', 'Agent')` in `agents/company/cso.md` §11.
Both names kept for forward-compat in case Anthropic renames.

This is the third revision of the §11 orphan check (v0.6.1 introduced
session_id-equality which never matched; v0.6.3 rewrote to time-window
correlation; v0.6.4 corrects the tool_name predicate). After this fix
the time-window correlation works as designed: zero false positives on
the Echo run's 11-row CSO audit.

The Echo run is documented in
`tests/integration/results-2026-05-09-echo-testco.md` as the canonical
v0.6.x cumulative validation record. 14 additional findings (F-2
through F-15) are tracked there for future v0.6.4+ patches.

### Fixed — Local SQLite hooks were silently no-op (HIGH) + Layer 5 orphan check correlation rewritten

Surfaced by the Delta Corp testco run on 2026-05-08: `agent_actions_log`
was **completely empty** after a full bootstrap with hundreds of tool
calls. Track 3 of handbook ADR 0004 (audit log) had been silently
disabled for every Local SQLite adopter since hooks were first shipped
on `main` (commit `9acfa71`). And the Layer 5 orphan-audit detection
rule shipped in v0.6.1 (`cso.md` §11) used a session_id-equality join
that **never matches** because the parent invoking Task and the spawned
CSO subagent use distinct Claude Code session_id values — the rule
produced false positives on every legitimate audit.

Two coupled bugs, both fixed in v0.6.3:

**Bug B — Local SQLite hooks no-op.** Pre-v0.6.3 every hook called
`turso db shell "$TURSO_URL"` directly. For Local SQLite adopters,
`db.url` is a filesystem path (e.g. `.juvant/state.sqlite`) — the
turso CLI cannot read filesystem paths, so every INSERT/UPDATE/SELECT
fell through to the silent `2>/dev/null || echo WARN` fallback.
`agent_actions_log` empty, `agents.status` never updated,
`agent_token_usage` never populated, `session_snapshots` never written.
Cloud adopters (Turso/Azure/AWS/GCP) were unaffected.

Fix:

- `hooks/lib/db.sh` — new shared helper. Three entry points:
  `juvant_db_exec` (DDL/DML), `juvant_db_query` (SELECT, text output),
  `juvant_db_query_csv` (SELECT, CSV output). `juvant_db_resolve`
  reads `db.provider` from `.juvant/config.json` and routes through
  either `sqlite3 <path>` (Local) or `turso db shell <url>` (cloud).
  Env override (`TURSO_URL`/`TURSO_TOKEN`) honored for cloud paths.
- All ten DB-touching hooks migrated to the helper:
  `pre-tool-use.sh`, `post-tool-use.sh`, `post-tool-use-failure.sh`,
  `session-start.sh`, `session-end.sh`, `subagent-start.sh`,
  `subagent-stop.sh`, `stop.sh`, `pre-compact.sh`, `post-compact.sh`,
  plus the `hooks/lib/track-tokens.sh` library.
- bash 3.2 SQL-escape regression fixed in `pre-compact.sh` while
  migrating (same root cause as the v0.6.0 fix in `pre-tool-use.sh`).

L2 hook tests (15/15) continue to pass — fake-turso shim is
provider-agnostic so the test setup works unchanged.

**Bug A — Layer 5 orphan check correlation broken.** The v0.6.1 rule
joined `security_audit_log.session_id` with `agent_actions_log.session_id`,
expecting them to share the parent's session_id. They don't:
`security_audit_log.session_id` is populated by the CSO subagent
(running in its own Claude Code session, getting its own session_id —
or a synthetic one as Delta showed: `cso-bootstrap-baseline-<TS>`),
while `agent_actions_log` rows for the Task invocation are written by
`pre-tool-use.sh` in the parent session (parent's session_id). The
two side never matched, so the orphan SQL flagged every legitimate
audit as suspect.

Fix in `agents/company/cso.md` Layer 5 §11:

- Rewrote the detection SQL to use a **time-window** correlation
  (Task invocation in the 60-min window preceding the audit row),
  no longer joining on session_id. Imprecise on which agent was
  spawned, but precise on the absence-of-Task signal (which is the
  cover-up failure mode we care about).
- Added two **fail-safe predicates** that catch the failure mode
  regardless of correlation precision:
  - Predicate (a): `agent_actions_log` empty plus `security_audit_log`
    with `auditor='cso'` populated → always cover-up flag.
  - Predicate (b): operator-mode (`AGENT_ROLE` unset / `'ceo'` /
    `'operator'`) writing audit rows → always cover-up flag, since
    humans cannot author CSO audits.
- Documented that the orphan check is best-effort
  defense-in-depth; the primary integrity guarantee remains
  `JUVANT_OS.md` Step 9.7 HARD-REQUIRED rule (v0.6.1).
- v0.6.4+ will add a `parent_session_id` column to
  `agent_actions_log` (or pass the parent session_id through the
  Task prompt and have CSO write it into `security_audit_log.session_id`)
  for tighter correlation. The `security_audit_log.session_id`
  column shipped in v0.6.1 stays in the schema as forward-compat
  metadata.

The Delta run is documented separately as an in-progress incident in
`tests/integration/results-2026-05-08-delta-testco.md` (added in a
follow-up commit if not already present).

### Fixed — wizard rendering must be deterministic (one question at a time)

Surfaced by the Delta Corp testco run on 2026-05-08 (post-v0.6.1
re-validation). At Step 1 (Identity), the Skill rendered all six
identity fields as a single batch prompt (*"reply with all six in
one message"*) — a fourth distinct rendering across four runs of the
same JUVANT_OS.md prose. Acme / Beta / Gamma had each rendered Step 1
"one question at a time" but inconsistently styled the wording.

This is wizard determinism finding #11 surfacing concretely. Prior to
v0.6.2 the rule lived only as informal phrasing inside individual
steps (e.g. Step 1's *"Collect from the CEO, one question at a time"*),
which different Skill sessions interpret as a suggestion rather than
a requirement. v0.6.2 promotes it to a load-bearing directive at the
top of `## Company setup` and `## Project setup`:

> **Wizard rendering rule (HARD-REQUIRED).** Every wizard step that
> collects multiple fields MUST render as one question at a time,
> sequentially, waiting for the CEO's reply before proceeding to the
> next field. Batch-mode collection is forbidden — non-deterministic
> across Skill sessions, breaks reasoning continuity, prevents
> per-field validation. The Skill emits each prompt, waits for the
> reply, records it, then emits the next. Steps with option menus
> render the menu verbatim from the JUVANT_OS.md prose without
> paraphrase or restructuring.

Step 1 prose tightened: bullet list → numbered sequence with
explicit "Skill emits each prompt, waits for the reply, records it,
then emits the next" preamble. Project setup section gets a
back-reference to the Company setup directive.

Same architectural principle as v0.6.1 (Step 9 hard-required CSO
audit): wizard procedure must be deterministic across Skill sessions.
v0.6.1 closed the integrity-relevant case (CSO audit fabrication);
v0.6.2 closes the UX-relevant cases (Step 1 batch, Step 1.5 missing
type-it option, Step 5 pipe-delimited freeform — all under the same
root cause).

### Fixed — CSO bootstrap_baseline audit can no longer be fabricated by the Skill (HIGH)

Surfaced by the Gamma Corp testco run on 2026-05-08 against post-merge
`main`. The wizard's previous Step 9 procedure permitted the Skill to
auto-skip the `Task(subagent_type='cso', ...)` invocation under
"sandbox-fast" interpretation, then synthesize the audit verdict
in-prose and write `security_audit_log` rows with `auditor='cso'`
directly. This is exactly the cover-up failure mode that handbook
ADR 0004 multi-track guardrails are designed to prevent: rows authored
as if produced by the CSO subagent that were in fact produced by the
Skill itself, structurally indistinguishable from a malicious agent
forging audit history.

Acme + Beta runs masked the failure mode by explicitly choosing
"Run via Task subagent" at the audit-mode prompt; Gamma run never saw
that prompt because the Skill collapsed "fast manifesto path" into
"skip all subsequent prompts including audit-mode". Three runs, three
different paths against the same JUVANT_OS.md prose.

The fix has four parts:

- **`SYSTEM_INVARIANTS.md` §1 step 7** — declares the Task spawn
  HARD-REQUIRED. Skill MUST NOT synthesize the verdict; MUST NOT write
  `security_audit_log` rows with `auditor='cso'` directly; MUST NOT
  substitute `subagent_type='general-purpose'` with inline cso.md
  briefing as a fallback. If the canonical resolution fails, the
  bootstrap aborts with explicit error and
  `master_context.bootstrap_completed_at` stays NULL — bootstrap is
  recoverable by addressing the registration gap and re-running.
- **`JUVANT_OS.md` Step 9** — removed the `[y/N]` "Trigger CSO audit?"
  prompt (it defaulted to skip-by-default and was the entry-point for
  the fast-path collapse). The audit now runs automatically and
  unconditionally. Step 7 declares the Task invocation hard-required
  with explicit prohibitions on synthesis / direct writes / fallback
  subagent type. Step 8 says verdicts come back from the subagent's
  response, never from the Skill's own reasoning. The project-bootstrap
  analog (Project setup Step 5) inherits the same hard-required rule.
- **`agents/company/cso.md` Layer 5 §11 — orphan-audit detection.**
  Any `security_audit_log` row authored as `auditor='cso'` lacking a
  corresponding `Task(subagent_type='cso', ...)` invocation in the
  same session window is forensically suspect. Detection SQL provided
  inline. HIGH-severity finding `cover-up:cso-audit-fabrication`.
  Operator-mode CSO audit rows (`AGENT_ROLE` unset or `'ceo'`) are
  flagged identically — humans cannot author CSO audits.
- **`scripts/schema.sql` + `scripts/upgrade-v0.5.sql`** —
  `security_audit_log.session_id TEXT` column added to support the
  Layer 5 orphan check (cross-reference against
  `agent_actions_log.session_id` for matching `tool_name='Task'`
  invocations). Existing rows without session_id are flagged by the
  Layer 5 check; new rows written by the CSO subagent capture the
  session_id from the event payload.

The Gamma run is documented in
`tests/integration/results-2026-05-08-gamma-testco.md` as the canonical
incident record.

### Added — ADR 0010: compiled agent registration via `.claude/agents/`

Surfaced by the Acme Corp testco bootstrap (FEAT-008 layer 4 dogfood,
2026-05-08, finding #6 — CRITICAL). Compiled agent templates lived
under `agents/<scope>/` but Claude Code's Task tool resolves
`subagent_type` from `.claude/agents/`. The two locations were not
bridged, so canonical `Task(subagent_type='<role>', ...)` failed to
register on every adopter and the Skill had to fall back to
`general-purpose` with inline briefing.

- `docs/adr/0010-compiled-agent-registration.md` (Accepted, validated
  end-to-end by the Beta Corp testco re-run on the same date).
- `.claude/agents/{ca,cco,cetho,cfo,chro,clo,cmo,cos,cro,cso}.md` —
  10 founding company-scope symlinks committed as mode 120000.
- `JUVANT_OS.md` Step 7 — item 5 documents the implicit registration.
- `README.md` — repo layout shows `.claude/agents/`.

### Added — FEAT-008 four-layer test suite

Closes `juvantlabs/juvant-os-pm#16`. L1 (eval scaffold), L3 (manual
integration scenarios), and L4 (schema validators) ship full;
L2 (hook tests) ships covering the v0.6.0 hook surface (15/15 cases).
LLM-judge automation and SDK-driven end-to-end runs are deferred
to v1.1.

- `tests/scenarios/` (L1) — eval scaffold + scenario lint + 4 seed
  scenarios (cfo/inbound-mail, clo/contract-review, cos/boot-summary,
  cso/system-audit).
- `tests/integration/` (L3) — three manual end-to-end procedures
  (mail-inbound-cfo-draft, context-compaction, offline-restart) +
  the dogfood evidence reports from the 2026-05-08 testco runs:
  `results-2026-05-08-acme-testco.md` (discovery, 10 findings) and
  `results-2026-05-08-beta-testco.md` (re-validation: six v1.0-blocking
  fixes confirmed PASS; CSO bootstrap_baseline audit returned PASS;
  three new MEDIUM/HIGH findings deferred to v1.1).
- `tests/hooks/run-tests.sh` (L2) — 15 cases against a local SQLite
  via `tests/hooks/fake-turso.sh` shim. Covers session-start,
  session-end + FEAT-024 token row, stop UPSERT idempotency,
  subagent-stop + parent_session_id, pre-tool-use universal deny +
  allow-list hit + allow-list miss + audit-log row + unknown role.
- `tests/schema/validate.py` (L4) — asserts 24 expected tables,
  9 indexes, CHECK constraint rejection of invalid maturity_status /
  to_status, baseline `model_pricing` seed presence, default values,
  and that `scripts/upgrade-v0.5.sql` applies cleanly to a v0.4-shape
  DB and backfills `project_maturity_history`.
- `.github/workflows/lint.yml` — three new CI jobs (L1, L2, L4) +
  `workflow_dispatch` + `push: branches: [release/**, feat/**]`
  triggers (the existing `pull_request` trigger has never fired on
  this repo).

### Added — FEAT-024: token usage tracking + cost report

Closes `juvantlabs/juvant-os-pm#40`. Captures token usage per session
and per subagent invocation, denormalizes cost using a versioned
`model_pricing` table, and surfaces a "Cost report" Skill operation
with by-agent / by-project / by-model breakdowns.

- `scripts/schema.sql` — `agent_token_usage` table (uuid pk,
  FEAT-022/023 forward-compat principal_id + project_slug,
  denormalized computed_cost_usd) + 5 indexes; `model_pricing` table
  (versioned by effective_from); seed rows for opus-4-7 / sonnet-4-6 /
  haiku-4-5 with explicit "verify against published pricing"
  disclaimer.
- `hooks/lib/track-tokens.sh` — shared library: transcript JSONL
  parse, pricing lookup, cost compute, UPSERT main / INSERT subagent.
- `hooks/stop.sh` — Stop hook (per-turn UPSERT for main session).
- `hooks/session-end.sh`, `hooks/subagent-stop.sh` — extended with
  FEAT-024 finalize / subagent-row write while preserving prior
  status-update behavior.
- `.claude/settings.json` — Stop hook registration.
- `JUVANT_OS.md` § Cost report — Skill operation phrasings, output
  structure, filter qualifiers, pricing-refresh procedure.

Token tracking is no-op on local-SQLite installations
(`hooks/lib/track-tokens.sh` requires Turso credentials per the
no-portal-on-local rule of ADR 0002). Adopters on Turso Cloud get
cost reports out of the box.

### Added — FEAT-023: project maturity status

Closes `juvantlabs/juvant-os-pm#39`. Adds the maturity-tier axis to
projects (`incubation` / `preview` / `general_availability`) that
calibrates how every agent treats the project — CMO publication
guard, CSO audit thresholds, CFO revenue tagging, CoS Morning Brief
grouping.

- `scripts/schema.sql` — `projects.maturity_status` column with
  CHECK constraint; `projects.maturity_changed_at`;
  `project_maturity_history` append-only table (demotion=1 flag);
  `idx_pmh_project_time` index. Plus a small bundled hardening:
  `agents.bash_allow` JSON-array column (mirrors
  `hooks/bash-policy.json` agent_allow[<role>] for query speed) and
  `idx_actions_log_status` index on `agent_actions_log`.
- `scripts/upgrade-v0.5.sql` — one-time migration for company DBs
  created before v0.6.0. Covers FEAT-018 bash_allow column,
  FEAT-019 agent_actions_log + indexes, FEAT-023 maturity_status +
  project_maturity_history (with backfill INSERT for existing
  projects), FEAT-024 agent_token_usage + model_pricing + seed.
  FEAT-025 (escalate-deny + bash_oneshot_grants) intentionally
  omitted — deferred to v1.1.
- `JUVANT_OS.md` § Project maturity status — two-axis model
  (status vs maturity_status), three-tier semantics with per-agent
  calibration table, transition procedure, agent guards, Skill
  operation.

### Fixed — bash 3.2 SQL escape regression in pre-tool-use.sh

The audit-log INSERT in `hooks/pre-tool-use.sh` used the bash
parameter expansion `${V//\'/\'\'}` which on macOS default bash 3.2
produces `\'\'` instead of `''` — invalid SQL escaping that silently
failed every `agent_actions_log` row carrying single quotes
(every allow-list miss deny reason). Replaced with a sed-based
`sql_escape` helper. Surfaced by FEAT-008 L2 tests on the first run.

Same root cause + same fix shape as commit `5d8aa52` (which only
patched `pre-compact.sh`). The same pattern still lives in
`hooks/post-tool-use.sh`, `hooks/post-tool-use-failure.sh`, and
`hooks/pre-compact.sh` — a follow-up sweep will harden those too.

### Fixed — testco trivial findings batch

Surfaced by the Acme Corp testco bootstrap on 2026-05-08. Full context
in `tests/integration/results-2026-05-08-acme-testco.md`.

- `scripts/migrate.sh` (finding #1) — handle `db.provider == "local"`
  (apply schema via `sqlite3` against a filesystem path); cloud
  providers retain the turso CLI path with TURSO_URL/TURSO_TOKEN env
  override.
- `JUVANT_OS.md` Step 3 (finding #2) — neutral inline descriptions
  per bank option + explicit no-template-maintainer-default directive
  (eliminates the synthesized "Common Juvant default" leak observed
  at runtime).
- `agents/company/cso.md` §9 (finding #4) — rephrased substitution
  audit rule without typing the literal token (was self-tripping the
  rule it described).
- `.gitignore` (finding #7) — added `.juvant/state.db` (local SQLite
  from Step 2 option [1]).
- `JUVANT_OS.md` Step 10 (finding #8) — extended canonical git-add
  list with `.github/CODEOWNERS`, `.gitignore`, `.claude/agents/`.

### Pending — Phase 6+
- `plugins/m365-mail/` (TypeScript Channel plugin via `defineChannel`) — Phase 6 / Beta.
- Desktop Scheduled Tasks (Morning Brief, Finom poll, fiscal deadlines) — Phase 7 / Beta.
- Test scenarios (`tests/scenarios/`) — Phase 9 / v1.0.
- External Portals (Service + Demo) — Phase 8 / v1.1.
- `juvantlabs/finom-mcp-server` — FEAT-011 (Beta).
- `juvantlabs/aruba-fattura-mcp-server` — FEAT-012 (Beta).
- `juvantlabs/m365-graph-mcp-server` — FEAT-014 (Beta), re-implement from scratch
  per audit FAIL on `ftaricano/mcp-onedrive-sharepoint`
  (gist: https://gist.github.com/juvantlabs/a9fe0a76a23b0c1260b1e0ad3194a6da).
- Webhook Services cloud receiver — FEAT-015 (Beta), multi-cloud (Azure/AWS/GCP)
  per-company webhook → Turso pipeline.

---

## [0.5.0] — 2026-05-03 — OSS template shipping defaults (FEAT-013)

First minor bump after Alpha. Closes FEAT-013 (`juvantlabs/juvant-os-pm#27`):
the six CSO baseline-audit Tier-2 follow-ups that previously surfaced in
every fresh `Initialize Juvant OS` run are now resolved at the OSS template
level. New per-company instances boot with **zero** Tier-2 follow-ups
(target — to be re-validated on the next dogfood run).

### Added — `.github/CODEOWNERS` template

Path-to-role ownership map with `{{*_GITHUB}}` placeholders rendered at
company-init Step 7.5 from `github_user_map` (Step 1.6). Solo-founder
instances collapse all placeholders to the CEO's GitHub handle; multi-human
teams get per-role overrides. Covers: orchestrator + invariants (CEO + CA),
ADRs (CA), agent templates (CHRO + CA), hooks + schema (CSO + CA),
plugins (CA), infra (CSO + CA), CI (CSO + CA), default fallback (CEO).

### Added — `.github/workflows/lint.yml`

CI workflow runs on PR + push to `main`. Five checks:

1. Markdownlint (relaxed, adopters tighten via `.markdownlint.yaml` in fork).
2. YAML frontmatter parse on every `agents/**/*.md`.
3. `scripts/schema.sql` syntax check via `sqlite3 :memory:` dry-run.
4. `.claude/settings.json` JSON.parse validation.
5. Tracked-secret detector (`BEGIN PRIVATE KEY`, `ghp_*`, `github_pat_*`,
   `sk-*`, `xox[abrs]-*`) — CSO Layer 2 mirror; per-company instances are
   expected to add tighter scanners (gitleaks / trufflehog) post-init.

### Added — `docs/branch-protection-spec.md`

Normative spec for branch protection on `main`. Six rules (PR required, ≥1
reviewer, status checks required, linear history, no force-push, no
deletion, include admins where plan supports). Documents the
Free-org-plan caveat: rules ship in `disabled` state per CSO Layer 4
convention — audit returns `WARN` not `FAIL` when plan limits enforcement.

### Added — `docs/MCP_INVENTORY.md`

Normative manifest of every MCP server the template references. Eight rows
covering `turso`, `ms-graph`, `m365-graph` (FEAT-014), `github:read/write`,
`bank` (FEAT-011), `fattura_elettronica` (FEAT-012), `buffer`. Includes the
abstract-role-vs-concrete-server pattern (`bank`, `fattura_elettronica`,
`buffer` are abstract qualifiers bound to provider-specific MCPs at company
init), the Universal Boundaries from `SYSTEM_INVARIANTS.md` §4, and the
process for adding new MCP servers (CA + CSO joint review).

### Added — `plugins/README.md` proper Channel-plugin pattern doc

Replaces the previous minimal placeholder. Documents the convention for
new Channel plugins (TypeScript, polling cadence, sender-confidence,
dead-letter, auth env vars, registration, **stdout discipline** —
explicit reference to the 2026-05-03 ftaricano audit C6 finding for what
happens when stdout is contaminated). Distinguishes Channel plugins (this
directory) from MCP servers (separate repos under `juvantlabs/*-mcp-server`).

### Added — JUVANT_OS.md wizard steps 1.6, 7.5, 8.5, 10.5

- **Step 1.6 — GitHub user mapping**: collects `github_user_map`. Default
  mapping = all roles → CEO. Per-role overrides for multi-human teams.
- **Step 7.5 — Render infrastructure files**: substitutes `{{*_GITHUB}}` in
  `.github/CODEOWNERS`. Other infra files ship as-is.
- **Step 8.5 — MCP inventory cross-check**: validates each
  `agent_tool_matrix` v0 row against `docs/MCP_INVENTORY.md`. Build-fails
  on Universal Boundary violations or unlisted servers.
- **Step 10.5 — Branch-protection spec**: authors a `branch-protection-spec`
  decision queued for COO execution. Free-plan-aware (records `disabled`
  state where enforcement is plan-limited).

### Updated — `.gitignore` extensions

Six new pattern groups (six-from-FEAT-013 anti-pattern checklist):

- Key material — `*.pem`, `*.key`, `id_rsa*`, `*.p12`, `*.pfx`
- Yarn / pnpm logs (consistent with existing Node patterns)
- Local SQLite artifacts — `*.sqlite`, `*.sqlite-shm`, `*.sqlite-wal`,
  `*.db-shm`, `*.db-wal` (relevant for `provider=local` doc_storage and
  dev databases)
- Turso CLI cache — `.turso/`
- Editor noise — `.idea/`, `.vscode/local-settings/`, `*.swp`, `*~`
- Test artifacts — `coverage/`, `.nyc_output/` (relevant once FEAT-008
  lands at Phase 9)

### Notes

- Closes `juvantlabs/juvant-os-pm#27` (FEAT-013).
- Six CSO baseline-audit Tier-2 follow-ups (CODEOWNERS, CI, branch
  protection, MCP inventory, plugin reference, `.gitignore` extensions)
  resolved at template level — fresh instances bootstrapping after this
  release should hit zero Tier-2 follow-ups (target — re-validation on
  next dogfood).
- The scheduled cleanup agent on `juvantio/juvant` (firing 2026-05-16)
  will still run for the existing instance (which was bootstrapped at
  v0.4.0). After upstream-sync of v0.5.0 lands in the instance, the
  cleanup PR may be redundant — confirmed at fire time.
- No SYSTEM_INVARIANTS.md changes (avoided system-wide manifesto
  re-validation per Appendix B). All policy lives in `JUVANT_OS.md` and
  the new `docs/*.md` files.

---

## [0.4.2] — 2026-05-03 — Document storage folder mapping + null-binding policy

---

## [0.4.2] — 2026-05-03 — Document storage folder mapping + null-binding policy

Second post-Alpha patch. Closes the five spec/template gaps surfaced during the
2026-05-03 dogfood OneDrive folder-mapping discussion (`juvantio/juvant`
instance) — all wizard / template gaps, no functional regression.

### Added — `JUVANT_OS.md` Step 1.5: Document storage folder mapping

New wizard step inserted between Step 1 (Identity) and Step 2 (Database setup).
Captures the agent-actionable doc-storage state that Step 1's abstract provider
choice (OneDrive / Google Drive) does not:

- **Discover-via-tool path** (preferred when M365 / Google Drive connector is
  loaded in the Claude Code session): wizard calls connector list / search
  tools, walks the discovered structure with the CEO, captures resource IDs
  (`drive_id`, `site_id`, `tenant_id`) for direct API resolution. Anti-pattern:
  the wizard MUST NOT ask the CEO to type folder paths when a connector is
  loaded (Bug #7b — first surfaced in the dogfood; CEO directly questioned
  "where are you looking?" when the wizard tried to type-it-blind).
- **Type-it path** (fallback when no connector available).
- **Three folder-organization models** documented as supported: function-centric,
  product-centric, hybrid. The schema is identical across all three; what varies
  is which `folders.<role>` keys are bound vs. set to `null` with a fallback
  chain.

New `.juvant/config.json` shape:

```json
{
  "doc_storage": {
    "provider": "onedrive",
    "mcp_server": "ms-graph",
    "resource_ids": { "tenant_id": "...", "site_id": "...", "drive_id": "b!..." },
    "folders": { "root": "/Co", "legal": "/Co/Legal", "research": null, ... },
    "fallback_chain": { "press": ["gtm", "root"], "research": [], ... }
  }
}
```

### Added — folder resolution algorithm + null-binding semantics

Documented in `JUVANT_OS.md` Step 1.5 and referenced from each affected agent
template's identity reference box. `resolve_folder(role)` consults
`folders.<role>` first; on `null` walks `fallback_chain.<role>` in order; on
exhaustion returns `None` and the agent surfaces `[<ROLE> SOURCE UNBOUND]` in
its response, offering the CEO three choices: bind now, confirm intentional
(logged as `decisions` cat `binding-confirmation`, `intentional_null=true`),
or use a one-time path.

### Added — write capability check

Distinct from folder resolution: write capability requires a write-capable MCP
bound (today: `juvantlabs/m365-graph-mcp-server`, FEAT-014, shipping in beta).
Until FEAT-014 ships, write paths are limited to (a) explicit local path
provided by the CEO turn-by-turn, or (b) waiting. Agents surface
`[<ROLE> WRITE UNAVAILABLE]` when capability is missing.

### Added — Project setup Step 1 auto-discovery

When the M365 / Google Drive connector is loaded and `doc_storage.folders.products`
is bound at company-level, the project-init wizard scans for existing subfolders
not yet mapped to a Juvant OS project and proposes them as project candidates.
Avoids forcing the CEO to type project folder paths when the structure already
exists. Per-project `doc_folder` recorded under `projects.<slug>.doc_folder` in
`.juvant/config.json`.

### Updated — agent templates

The six agent templates that read or write documents (`agents/company/cro.md`,
`cmo.md`, `cco.md`, `cfo.md`, `clo.md` and `agents/projects/cdo.md`) now
reference the `JUVANT_OS.md` Step 1.5 policy in their identity box and
document role-specific surface flags (`[CRO SOURCE UNBOUND]`, `[CMO WRITE
UNAVAILABLE]`, `[CFO BANK SOURCE UNAVAILABLE]`, etc.). The CFO template also
documents the bank-source-unbinding case for the FEAT-011 deferred-shipping
period.

### Fixed — bugs from the 2026-05-03 dogfood

- **Bug #7** — Wizard at company-init never asked for OneDrive folder mapping
  even after capturing the abstract provider, leaving every doc-handling agent
  to surface "source unbound" on first call. Resolved by Step 1.5.
- **Bug #8** — Templates assumed function-centric folder organization
  (dedicated `Research`, `Press`, `Sales` at company root). Real companies are
  often product-centric or hybrid. Resolved by `null` + fallback-chain schema
  flexibility.
- **Bug #10** — Wizard captured paths but not provider-specific resource IDs
  (`drive_id`, `site_id`, `tenant_id`), forcing every MCP call to do a path-
  resolution roundtrip. Resolved by `resource_ids` block populated during
  discover-via-tool.
- **Bug #11** — Project-init wizard asked for typed folder paths instead of
  exploring `doc_storage.folders.products` for existing candidates. Resolved
  by Project setup Step 1 auto-discovery.
- **Bug #12** — Agent templates' fail-mode for null / missing bindings was
  unspecified, risking silent failures or hard errors. Resolved by the
  `[<ROLE> SOURCE UNBOUND]` / `[<ROLE> WRITE UNAVAILABLE]` surfacing pattern
  + `decisions` cat `binding-confirmation` audit trail.

### Notes

- All five bugs fixed at the OSS-template level (`juvantlabs/juvant-os`).
  Per-company instances at `v0.4.0` / `v0.4.1` (e.g. `juvantio/juvant`)
  receive the fixes via the next CHRO upstream-sync proposal (CHRO drift
  detection → CA `pr-spec` → COO PR).
- No SYSTEM_INVARIANTS.md changes (would have triggered system-wide
  manifesto re-validation per Appendix B). The doc-storage policy is
  expressed in `JUVANT_OS.md` and referenced from individual templates;
  promotion to SYSTEM_INVARIANTS.md §8 is deferred until / if multiple
  Juvant OS adopters need provider-agnostic policy enforcement.

---

## [0.4.1] — 2026-05-02 — Dogfood patch

---

## [0.4.1] — 2026-05-02 — Dogfood patch

First post-Alpha patch. All bugs surfaced during the **first real dogfood run**
of `Initialize Juvant OS for Juvant Srls` on 2026-05-02 (17 minutes 50 seconds,
end-to-end Bootstrap Protocol §1 completed successfully).

### Fixed — pre-dogfood corrections (Teams setup)

- **Teams channel naming**: Teams uses bare channel names (no `#` prefix; that is
  Slack convention). All references to `#approvals`,
  `#{{ACTIVE_PROJECT}}-alerts`, `#{{COMPANY_NAME_SLUG}}-ops`, `#system` updated
  to `Approvals`, `{{ACTIVE_PROJECT}}-alerts`, `{{COMPANY_NAME_SLUG}}-ops`,
  `System`. Affects `JUVANT_OS.md` (Step 4 Notifications + CoS Communication Map)
  and `agents/company/cos.md` (Message Priority Rules + Channel use).
- **Wizard Step 4 schema**: company-setup wizard now collects **four** Teams
  Adaptive Cards webhook URLs (one per canonical channel) instead of a single
  webhook. New `.juvant/config.json` schema:
  `teams_webhooks: { approvals, ops, system, alerts }`. The wizard description
  table spells out each channel's purpose; alerts is optional at company-init.
- **`{{COMPANY_NAME}}-ops` → `{{COMPANY_NAME_SLUG}}-ops`** in `cos.md` Channel
  use — `COMPANY_NAME` may contain spaces (e.g. "Acme Corp"); only `_SLUG` form
  is a valid Teams channel name.
- **Telegram `chat_id` collection**: Step 4 now also collects the CEO's numeric
  Telegram `chat_id` (the bot needs it to send Critical alerts; the bot token
  alone is insufficient).
- **`hooks/notification.sh`**: rewritten to read `teams_webhooks.<channel-key>`
  using `jq --arg`. Channel selection is driven by the `JUVANT_NOTIFY_CHANNEL`
  env var (default `approvals`). Empty / unset URLs gracefully skip Teams and
  fall through to Telegram.

### Fixed — dogfood (Step 2 — Database setup)

- **`scripts/schema.sql` PRAGMA WAL rejected by Turso.** Removed the
  `PRAGMA journal_mode=WAL;` statement; Turso (LibSQL) uses WAL by default and
  rejects the PRAGMA when applied via `turso db shell`. Added a comment
  documenting that the local SQLite path (provider=local) sets WAL via the
  wizard at runtime instead of via the schema.
- **`scripts/migrate.sh` flat keys vs. spec schema.** Migration script now
  reads `db.url` and `db.auth_token` from `.juvant/config.json` (matching
  the JUVANT_OS.md Step 2 nested schema), instead of the legacy flat
  `turso_url` / `turso_token` keys.

### Fixed — dogfood (Step 6 — Agent names)

- **`JUVANT_OS.md` Agent naming table incorrectly listed COO under company-scope.**
  Per `SYSTEM_INVARIANTS.md` §2, COO is project-scope (default
  `<project_id>-coo`); the file lives in `agents/projects/coo.md`. The
  Agent naming reference table is split into a Company-scope table (10 agents)
  and a Project-scope table (5 leadership + 4 Eng/*) to match the canonical §2
  definition. Each project gets its own COO; there is no company-wide COO.

### Fixed — dogfood (Step 7 — Compile templates)

- **`agents/company/cso.md` self-reference.** Layer 5 audit check #9 contained
  the literal token `{{PLACEHOLDER}}` inside backticks while describing its
  own substitution-failure rule, which would fail its own audit on first run.
  Reworded to prose: "any surviving `{{NAME}}`-style placeholder is a
  substitution failure (`FAIL`)" with explicit reference to the §2 allowlist.
- **Project-scope name placeholders inside company-scope templates.** Eight
  company-scope files (`cos.md`, `cco.md`, `cmo.md`, `clo.md`, `chro.md`,
  `cso.md`, `ca.md`) referenced `{{CTO_NAME}}` / `{{CPO_NAME}}` /
  `{{CDO_NAME}}` / `{{COO_NAME}}` / `{{VPE_NAME}}` in role-routing tables and
  cross-references. At company-init no project exists yet, so these tokens
  could not be substituted with real names. Replaced all occurrences with
  generic phrasing (`the project's CTO`, `the project's COO`, etc.) since
  company-scope agents address project-scope agents abstractly across all
  active projects, not as a single named person.
- **Substitution-failure rule conflicted with `{{ACTIVE_PROJECT}}`
  runtime-bound exception.** `SYSTEM_INVARIANTS.md` §2 stated both that any
  surviving `{{...}}` triggers a CSO Layer 5 finding AND that
  `{{ACTIVE_PROJECT}}` binds at SessionStart and survives compilation —
  contradiction. Resolution: §2 now defines an explicit **runtime-bound
  allowlist** (today: `{{ACTIVE_PROJECT}}` only); CSO Layer 5 audits skip
  allowlisted placeholders. All four "refuse to write any surviving
  `{{...}}`" assertions in `JUVANT_OS.md` (Wizard Step 7, project-init Step 4,
  Agent naming section, Appendix A) updated to reference the §2 allowlist.

### Build process — dogfood validation

- First end-to-end `Initialize Juvant OS` on `juvantio/juvant` succeeded:
  - 10/10 founding company-scope manifestos `operational` after Bootstrap
    Protocol §1 with `tier1_bootstrap=1` + `precondition_bypassed='bootstrap'`.
  - CSO `bootstrap_baseline=1` audit returned `WARN-WITH-CONDITIONS`
    (treated as PASS per §1.8); promoted manifestos to `operational`.
  - `master_context.bootstrap_completed_at` set at `2026-05-02T21:26:01Z`.
  - 6 Tier-2 follow-ups authored as `decisions` rows (CODEOWNERS, CI,
    branch protection, MCP inventory, plugin reference, `.gitignore`
    extensions); these are tracked as **FEAT-013 OSS template shipping
    defaults** to address the underlying gaps in the OSS template, so future
    fresh instances start cleaner.

---

## [0.4.0] — 2026-05-02 — JUVANT_OS.md Skill orchestrator

Phase 4 of Juvant OS. Closes the Alpha milestone. The Skill orchestrator is the only entry
point for all Juvant OS operations — natural language replaces the CLI that never existed.

### Added

- **`JUVANT_OS.md`** — Skill orchestrator at the repo root (1,249 lines). Read at every
  Claude Code SessionStart; defers to `SYSTEM_INVARIANTS.md` (§1–§7) for cross-cutting
  invariants. Contains:
  - **§ When to use this skill** — intent → procedure mapping table for every CEO trigger
    phrase.
  - **§ How this skill works** — Turso = canonical memory; context window = temporary;
    `.juvant/config.json` = local-only secrets (gitignored).
  - **§ Company setup** — 10-step wizard: identity → database (CLI or Manual; Local /
    Turso / Azure / AWS / GCP) → bank provider binding (`bank` abstract → Finom / Mercury /
    Revolut / Wise) → notifications (Telegram + Teams + Morning Brief) → counterparties →
    name resolution (§2 defaults) → template compilation (whole-token substitution; refuse
    surviving `{{...}}`) → `agent_tool_matrix` v0 seed → **Bootstrap Protocol §1**
    (CEO-only one-shot override, `tier1_bootstrap=1`, `precondition_bypassed='bootstrap'`,
    structural-completeness check, CSO `bootstrap_baseline=1` audit, `master_context.
    bootstrap_completed_at`) → initial commit.
  - **§ Project setup** — 6-step wizard with project-bootstrap analog
    (`precondition_bypassed='project-bootstrap'`); CTO Tier-1 sole approver after CHRO + CA
    bootstrap the project CTO.
  - **§ Starting agents** — boot sequence with bootstrap-state check, 3-level session
    continuity, parallel pending-state reads, disclosure-fallback gate, always-on first
    triad (CoS / CFO / CLO), Boot Mode resolution (Single / All).
  - **§ Status check** — unified dashboard reads + format with `[MANIFESTO PENDING]` and
    `[DISCLOSURE FALLBACK ACTIVE]` flags.
  - **§ Manifesto review flow** — Tier 1 (blocking; company = CHRO + CA, project = CTO
    sole) and Tier 2 (async, 7-day); CSO precondition (passing 5-layer audit ≤30 days,
    bypassed only during bootstrap); restricted-mode behaviour by role.
  - **§ Agent naming** — §2 defaults, project-prefix pattern, whole-token substitution.
  - **§ Memory commit protocol** — SQL templates per exchange type (`counterparty_history`,
    `messages`, `inbound_queue`, `decisions`); enumerated `category` values matching the
    schema.
  - **§ Context resume** — 3-level redundancy: Agent SDK `session_id` → `session_snapshots`
    → structured Turso memory.
  - **§ CoS proxy model** — default proxy with disclosure validation, direct-1:1 exception
    flow, Eng/* delegated through VPE, Teams channel routing (#approvals,
    #{{ACTIVE_PROJECT}}-alerts, #{{COMPANY_NAME_SLUG}}-ops, #system).
  - **§ Spec-driven single-writer model (§4 + §6)** — all 9 spec classes (`pr-spec`,
    `gh-issue-spec`, `gh-project-update-spec`, `gh-milestone-spec`, `install-spec`,
    `branch-protection-spec`, `release-spec`, `deployment-spec`, `secret-rotation-spec`)
    plus `gh-pr-review-spec`; COO 5-check verification (author authorization, approval
    state, format completeness, Universal CONFIDENTIAL invariant, linked artifact
    integrity); no partial execution; Universal Boundaries (no `bank:write`, no
    `m365-mail` send except portals, no `github:write` to non-COO, no `state.db` read +
    external-channel send in same row, no unrestricted `Bash` to portal/demo agents).
  - **§ Disclosure fallback cascade (§3)** — detection (Turso unreachable OR
    zero active rows); Tier 1 universal `inbound_queue` + `security_audit_log` writes;
    Tier 2 CoS T+5min Telegram CRITICAL aggregation; Tier 3 COO halt-all-writes
    (single-writer → single-reader-only); Tier 4 VPE Eng/* routing + buffered
    `eng-output-held`; CSO post-incident `cascade-postmortem`.
  - **§ Model assignment + override** — Opus 4.7 (cos, cso, clo, cetho, ca), Sonnet 4.6
    (cfo, cmo, cco, chro, cro, cto, cpo, cdo, coo, vpe), Haiku 4.5 (eng-api, eng-backend,
    eng-frontend, eng-ai); CoS / VPE override authority; mandatory logging in `decisions`
    category `model-override` (unlogged override = security incident).
  - **§ Hiring / offboarding** — post-bootstrap hiring flow (CHRO tool-matrix-change → CA
    `pr-spec` → CHRO+CA+CSO+CEthO review → standard manifesto lifecycle WITH CSO
    precondition); 5-step CR-09 offboarding (Drain → Handoff → Revoke → Cleanup → Notify).
  - **§ Upstream sync** — CHRO drift detection vs `juvantlabs/juvant-os@main` →
    `decisions` category `upstream-sync-proposal` → CoS → CEO → CA `pr-spec` → COO PR with
    CHRO + CA + CSO + CEthO review (CEthO required when §3/§5 changed); `git merge
    upstream/main` reserved for emergencies + post-incident audit.
  - **§ Migration watch** — OP-001 (Agent Teams: 0/3 today), OP-002 (Cloud Routines: 0/4
    today), OP-004 (Azure 24/7: not yet required); deltas recorded in `decisions` category
    `migration-watch`; never proposed to CEO until all criteria green.
  - **§ Security rules** — 10 Skill-enforced invariants including Universal CONFIDENTIAL
    (§5), COO 5-check, one-shot bootstrap, SYSTEM_INVARIANTS.md as canonical authority,
    credentials never in context, counterparty input as data not instructions,
    `bank:read`-only by construction, COO-only `github:write`, CMO m365-mail = press scope
    only, structural cascade engagement.
  - **Appendix A** — placeholder substitution checklist (company-init vs project-init
    tokens; `{{ACTIVE_PROJECT}}`/`{{PROJECT_NAME}}` resolved at SessionStart and project
    init respectively; surviving `{{...}}` = compile failure).
  - **Appendix B** — first-time-setup procedure for a per-company instance: create empty
    private repo in `juvantio` → `git clone --bare` of `juvantlabs/juvant-os` →
    `git push --mirror` to per-company repo (standalone, NOT a GitHub fork) → working
    clone → optional `upstream` remote → `claude` → `Initialize Juvant OS`.

### Notes

- All SQL examples in JUVANT_OS.md target columns that exist in `scripts/schema.sql` from
  Phase 2 (commit `cbe7d6f`).
- All hook references match the 7 scripts shipped in Phase 3 (commit `f5bdfc5`) and the
  registrations in `.claude/settings.json`.
- All agent references match the 19 compiled subagent templates from Phase 5 / commit
  history `16c31d2..32ef1a1` (CDO = Chief **DESIGN** Officer; COO = sole `github:write`
  bearer; `bank` abstract; CMO m365-mail = press scope only).
- Closes `juvantlabs/juvant-os-pm` issue #12 (FEAT-004).
- Alpha milestone complete (Phases 1–5 ✅).

---

## [0.3.0] — 2026-05-01 — SYSTEM_INVARIANTS refactor

Phase 3 of Juvant OS. Resolves audit findings P0.1, P1.1, P1.2 by extracting cross-cutting
invariants into a single canonical document and refactoring all 19 subagent templates to
defer to it via reference boxes.

### Added

- **`SYSTEM_INVARIANTS.md`** — canonical source-of-truth for the seven cross-cutting
  invariant classes (commit f59dded):
  - §1 Bootstrap Protocol (CEO + CSO ownership) — CEO-only override path for the founding 19
    manifestos at company init. Flags: `tier1_bootstrap=1`, `precondition_bypassed='bootstrap'`,
    `master_context.bootstrap_completed_at`. One-shot, no re-entry. CSO performs
    `bootstrap_baseline=1` audit immediately after all 19 reach OPERATIONAL_RESTRICTED.
  - §2 Default Naming Convention (CHRO ownership) — populated `{{*_NAME}}` placeholders with
    defaults: Atlas (CoS), Theos (CFO), Lex (CLO), Mira (CMO), Clio (CCO), Sage (CHRO),
    Shield (CSO), Vera (CEthO), Arch (CA), Lumen (CRO), Coo (COO).
  - §3 Unified Disclosure Fallback Cascade (CSO ownership) — 4 tiers: Universal (every agent)
    → CoS-side aggregation (T+5min Telegram CEO Critical) → COO halt-all-writes →
    VPE-routing extension for Eng/*. Per-agent extensions documented inline.
  - §4 Single-Writer Invariant (COO canonical executor) — COO is the sole GitHub writer
    system-wide; cross-ref to `coo.md`.
  - §5 Universal CONFIDENTIAL List — 10 items, amendable only by CEO + CSO + CLO + CEthO
    joint approval.
  - §6 Spec Authorization Matrix (COO canonical source) — the matrix in `coo.md` is the
    source-of-truth; SYSTEM_INVARIANTS.md cross-refs to it.
  - §7 Architectural Principles (CA ownership) — 11 principles; cross-ref to `ca.md`.

- **Project-bootstrap analog** in `cto.md` — when a new project is added to an existing
  company post-bootstrap, `precondition_bypassed='project-bootstrap'` is permitted for the
  initial Tier 1 wave of the new project's agents. Sequencing: CHRO + CA approve the new
  project CTO's manifesto first; once OPERATIONAL_RESTRICTED, CTO performs Tier 1 on the
  remaining project-scope agents; CSO performs `bootstrap_baseline=1` audit immediately after.

- **Tier-3 cascade specification** in `coo.md` — full halt-all-writes spec: all `*-spec` rows
  freeze with `status='deferred-fallback'`; single-writer → single-reader-only invariant;
  emergency carve-out requires CEO direct authorization with
  `disclosure_fallback_emergency_override=1`; CSO notified for post-incident audit; resume
  protocol with re-validation of any disclosure-tagged specs.

- **Tier-4 cascade specification** in `vpe.md` — full Eng/*-routing spec: VPE-side hold buffer
  for Eng/* outputs (`decisions` category `eng-output-held`, `held_for_fallback=1`); internal
  engineering work continues; external-facing artifacts paused; resume replay verification.

- **Dual-surface invariant codification** in `cpo.md` — explicit Backlog Protocol stating
  Turso is canonical (CPO writes), GitHub Projects is the operational projection (COO writes
  per CPO-authored specs); canonical wins on drift.

- **Design-system canonical assertion** in `cdo.md` — explicit reference box stating the
  design system is canonical in `knowledge_base WHERE tags LIKE '%design-system%'` (Turso);
  repo implementation is verified against canonical, not the other way around.

### Changed

- **All 19 subagent templates** refactored to defer to `SYSTEM_INVARIANTS.md`:
  - Reference box added at the top of each template citing relevant sections.
  - Disclosure Fallback rules collapsed to "Apply Universal Cascade SYSTEM_INVARIANTS.md §3"
    plus per-agent extensions where applicable.
  - Universal CONFIDENTIAL references replaced with §5 cross-refs.
  - Single-Writer Invariant references replaced with §4 cross-refs.
  - Peer-agent name references substituted with `{{*_NAME}}` placeholders per §2.

  Per-template commits on `juvantlabs/juvant-os` `main`:

  | Template | Commit | Notes |
  |---|---|---|
  | `cos.md` | 16c31d2 | Tier-2 cascade aggregation owner; bootstrap awareness |
  | `cfo.md` | 1953ca2 | Bank MCP unavailable handling |
  | `clo.md` | 4859af8 | CLO is policy lifecycle owner; structural alarm |
  | `cmo.md` | ab96e50 | CRO "if enabled" fallback |
  | `cco.md` | 9615f1a | CRO "if enabled" fallback |
  | `chro.md` | 7ef18e8 | Manifests row schema clarified (P1.9); bootstrap exception |
  | `cso.md` | 7ca9c45 | Layer 5 expanded (SYSTEM_INVARIANTS check); bootstrap baseline |
  | `cetho.md` + `ca.md` + `cro.md` | 25a2271 | CEthO co-custodian §5; CA canonical §4+§7; CRO OPTIONAL |
  | `coo.md` | 06ae526 | Canonical executor §4 + canonical source §6; full Tier-3 spec |
  | `cto.md` | 4d9f23e | Project bootstrap analog; project-scope Tier 1 sole approver |
  | `cpo.md` | 5d5cab9 | Dual-surface invariant codified |
  | `cdo.md` | dcee304 | Design-system canonical assertion; CDO is NOT data role |
  | `vpe.md` | 2962f63 | Full Tier-4 cascade Eng/* routing spec |
  | `eng-api.md` | 6e5e009 | Subordinate to VPE Tier-4; held_for_fallback buffer |
  | `eng-backend.md` | 41a89e3 | Data-deletion gate preserved through fallback |
  | `eng-frontend.md` | c0a0171 | Design-system consumer; accessibility floor |
  | `eng-ai.md` | 32ef1a1 | User-facing AI work HALTS during fallback; CEthO notified |

### Fixed

- **P0.1 (CRITICAL) — bootstrap chicken-and-egg.** Tier 1 manifesto approval required
  CHRO/CA/CTO evaluators and a CSO precondition (passing audit ≤30 days). At company init,
  none of the 19 founding agents had a manifesto yet, so the gate could not open. Resolution:
  §1 Bootstrap Protocol with CEO-only override (one-shot), `bootstrap_baseline` CSO audit
  immediately after. Project-bootstrap analog handles the same problem for new projects added
  to an existing company.

- **P1.1 — Disclosure Fallback inconsistency.** Templates carried inconsistent fallback
  behavior, ranging from "halt all work" to "treat as CONFIDENTIAL but continue." Resolution:
  §3 Unified 4-Tier Cascade with explicit per-agent extensions (CHRO structural alarm, CTO
  project-scope manifesto pause, CDO external-facing pause, CSO post-incident audit, CEthO
  joint acknowledgment on resume, eng-ai user-facing AI halt).

- **P1.2 — Placeholder naming inconsistency.** Templates referenced peer agents by literal
  default names in some places and by `{{PLACEHOLDER}}` form in others, with no canonical
  list. Resolution: §2 Default Naming Convention with all `{{*_NAME}}` placeholders enumerated
  and populated defaults (Atlas, Theos, Lex, Mira, Clio, Sage, Shield, Vera, Arch, Lumen, Coo);
  templates substituted accordingly.

### Documentation

- **`docs/session-commit-p1.md`** in `juvantlabs/juvant-os-pm` updated with a dedicated
  SYSTEM_INVARIANTS.md section (commit `juvantlabs/juvant-os-pm@6b40804`):
  - Section table of the 7 invariant classes with owners and notes.
  - Bootstrap Protocol full explanation with project-bootstrap analog.
  - Disclosure Fallback Cascade 4-tier table with per-agent specifics.
  - Architecture, Initialize-the-system, Upstream sync, Org structure, Matrix, Universal
    Boundaries, and Spec authorization sections updated with §-cross-refs.
  - "Refactor history" section appended listing all 20 commits (1 SYSTEM_INVARIANTS.md +
    19 templates).

---

## [0.2.0] — 2026-04-23 — Initial 19-template build

Phase 2 of Juvant OS. All 33 CRs from Chat 19+20 design phase resolved. 19 subagent templates
built. Org separation `juvantlabs` (OSS) ↔ `juvantio` (product). Single-writer model
(COO sole `github:write` bearer) and CDO=Design (not Data) established. Bank MCP abstracted
to per-company binding. Repository model: per-company instances are mirror-pushed standalone
repos, not formal GitHub forks.

(Pre-CHANGELOG history; see `juvantlabs/juvant-os-pm/docs/session-commit-p1.md` and
`session-commit-p2.md` for the full design rationale and chat-by-chat trace.)

---

## [0.1.0] — pre-2026-04-23 — Architecture phase

Skill-first orchestration model selected (no CLI). Two-org structure decided. Model
Assignment Policy locked (Opus 4.7 / Sonnet 4.6 / Haiku 4.5). State Architecture established
(Turso shared persistent memory; context window temporary; OneDrive/GDrive for sensitive
documents). Agent Tool Matrix v0 default seed authored.

(Pre-CHANGELOG history; design rationale in `juvantlabs/juvant-os-pm/docs/`.)

[Unreleased]: https://github.com/juvantlabs/juvant-os/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/juvantlabs/juvant-os/releases/tag/v0.5.0
[0.4.2]: https://github.com/juvantlabs/juvant-os/releases/tag/v0.4.2
[0.4.1]: https://github.com/juvantlabs/juvant-os/releases/tag/v0.4.1
[0.4.0]: https://github.com/juvantlabs/juvant-os/releases/tag/v0.4.0
[0.3.0]: https://github.com/juvantlabs/juvant-os/releases/tag/v0.3.0
[0.2.0]: https://github.com/juvantlabs/juvant-os/releases/tag/v0.2.0
[0.1.0]: https://github.com/juvantlabs/juvant-os/releases/tag/v0.1.0
