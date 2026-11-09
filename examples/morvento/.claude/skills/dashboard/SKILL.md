---
name: dashboard
description: "Build the company dashboard from the repo and publish it as a private claude.ai page, updating the same page each time. Use when the CEO asks for the dashboard or a status page, and from the hourly scheduled task."
---

# Build and publish the dashboard

The dashboard is read-only: it shows what the files say, built by a script, never written by hand.

1. **Build:** `python3 .claude/dashboard/build.py` → `state/dashboard.html`. Locally, for live session states, first run `claude agents --json > /tmp/agents.json` and add `--agents-json /tmp/agents.json`; in the cloud, skip it.
2. **Publish** with the claude.ai artifact tools:
   - If `state/dashboard-artifact.json` exists, read its `slug`, get the live version (`get_artifact`), and republish `state/dashboard.html` to that slug with that `base_version`, keeping title and icon.
   - If it doesn't, publish `state/dashboard.html` as a new artifact titled "<Company> dashboard", icon `chart`, and write `state/dashboard-artifact.json`: `{"slug": "<slug>", "url": "<url>"}`.
   - Prefer publishing from the file; if file publishing isn't available here, publish the file's content as the page.
   - The artifact stays private to the CEO. Never share it, and never put secrets or data the CEO wouldn't want on that page into memory in the first place.
3. **Don't edit the page.** If something on it is wrong, the source file is wrong: fix the file (with the CEO), then rebuild.
4. **Commit** `state/dashboard-artifact.json` the first time; the HTML stays out of git (it's rebuilt every time).
5. Interactive use: give the CEO the link in one line. From the scheduled task: say nothing unless publishing failed, and then log it with `python3 .claude/hooks/juvant_hooks.py log-outcome "dashboard: <error>"`.

## Scheduled task (set up once, by the CEO)

At claude.ai/code → Scheduled tasks → New, on the company repo, hourly on working days, with the prompt: `Run the dashboard skill.`
