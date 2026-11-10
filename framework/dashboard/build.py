#!/usr/bin/env python3
"""Build the company dashboard: one self-contained, read-only HTML page.

    python3 .claude/dashboard/build.py [--root DIR] [--out FILE] [--today YYYY-MM-DD]
                                       [--agents-json FILE]

Reads memory/, roles/, state/activity.jsonl, state/briefs/, drafts/ and
memory/deadlines.md from the company repo (default: $CLAUDE_PROJECT_DIR or the
current directory) and writes state/dashboard.html. Standard library only; the
page loads only its fonts from Google Fonts. --agents-json takes the output of
`claude agents --json` (local only) to show live session states.
"""
import argparse
import datetime as dt
import html
import json
import os
import re

DEDICATED = ("legal", "finance", "ethics")
RECENT_DECISIONS = 8
ACTIVITY_DAYS = 14
DEADLINE_DAYS = 30


def esc(x):
    return html.escape(str(x), quote=True)


def plain(x):
    """Agent outcomes are markdown one-liners: show them as plain text."""
    return re.sub(r"[*_`#]+", "", str(x or "")).strip()


def read(root, rel):
    try:
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def listdir(root, rel, pattern=r".*\.md$"):
    try:
        return sorted(n for n in os.listdir(os.path.join(root, rel)) if re.match(pattern, n))
    except OSError:
        return []


def frontmatter(text):
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    out = {}
    if m:
        for line in m.group(1).splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                out[k.strip()] = v.strip()
    return out


def first_heading(text, default=""):
    return next((l[2:].strip() for l in text.splitlines() if l.startswith("# ")), default)


def parse_date(s):
    try:
        return dt.date.fromisoformat(str(s)[:10])
    except ValueError:
        return None


# ── data ─────────────────────────────────────────────────────────────────────
def company_name(root):
    t = read(root, "manifesto.md")
    h = first_heading(t, "")
    return re.sub(r"\s+manifesto$", "", h, flags=re.I) or os.path.basename(os.path.abspath(root))


def activity(root):
    rows = []
    for line in read(root, "state/activity.jsonl").splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict) and r.get("ts"):
            rows.append(r)
    return rows


def waiting(root):
    items = []
    days = listdir(root, "memory/journal", r"\d{4}-\d{2}-\d{2}\.md$")
    if days:
        # Each wrap-up writes the whole current list, so only the last
        # "Waiting for the CEO" line of the latest journal is current; earlier
        # ones are stale (same rule as the session-start hook).
        latest = days[-1]
        found = [m.group(1).strip() for m in (
            re.match(r"^\s*-\s*Waiting for the CEO:\s*(.+)$", line, re.I)
            for line in read(root, "memory/journal/" + latest).splitlines()) if m]
        if found and found[-1].lower() not in ("none", "nothing", "-"):
            items.append((found[-1], "memory/journal/" + latest))
    drafts = []
    for n in listdir(root, "drafts", r".*"):
        p = os.path.join(root, "drafts", n)
        if os.path.isfile(p):
            drafts.append((n, dt.date.fromtimestamp(os.path.getmtime(p))))
    drafts.sort(key=lambda x: x[1], reverse=True)
    return items, drafts


def decisions(root):
    out = []
    for n in reversed(listdir(root, "memory/decisions", r"\d{4}-\d{2}-\d{2}-.*\.md$")):
        t = read(root, "memory/decisions/" + n)
        fm = frontmatter(t)
        if fm.get("status", "active") != "active":
            continue
        out.append((fm.get("date", n[:10]), first_heading(t, n[:-3]), fm.get("decided_by", ""), "memory/decisions/" + n))
        if len(out) == RECENT_DECISIONS:
            break
    return out


def deadlines(root, today):
    rows = []
    for line in read(root, "memory/deadlines.md").splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 2:
            d = parse_date(cells[0])
            if d and today <= d <= today + dt.timedelta(days=DEADLINE_DAYS):
                rows.append((d, cells[1], cells[2] if len(cells) > 2 else ""))
    return sorted(rows)


def agents(root, acts, today):
    week_ago = today - dt.timedelta(days=7)
    out = []
    for role in DEDICATED:
        card = read(root, f"roles/{role}.md")
        m = re.search(r"^name:\s*(.+)$", card, re.M)
        name = m.group(1).strip() if m and "{{" not in m.group(1) else ""
        mine = [a for a in acts if a.get("agent_type") == role]
        starts = [a for a in mine if a.get("event") in ("subagent_start", "session_start")]
        last = max((a["ts"] for a in mine), default="")
        outcome = next((a.get("outcome") for a in reversed(mine) if a.get("outcome")), "")
        week = sum(1 for a in starts if (parse_date(a["ts"]) or dt.date.min) >= week_ago)
        out.append({"role": role, "name": name, "last": last[:16].replace("T", " "), "week": week, "outcome": outcome})
    others = {}
    for a in acts:
        t = a.get("agent_type")
        if t and t not in DEDICATED and a.get("event") in ("subagent_start", "session_start"):
            others[t] = others.get(t, 0) + 1
    return out, sorted(others.items(), key=lambda x: -x[1])


def collaborators(root, acts, live):
    out = []
    for n in listdir(root, "state/briefs"):
        name = n[:-3]
        t = read(root, "state/briefs/" + n)
        m = re.search(r"(\d{4}-\d{2}-\d{2})", t)
        outcome = next((a.get("outcome") for a in reversed(acts) if a.get("agent_type") == name and a.get("outcome")), "")
        state = live.get(name, "")
        out.append({"name": name, "started": m.group(1) if m else "", "outcome": outcome, "state": state})
    return sorted(out, key=lambda x: x["started"], reverse=True)


def projects(root):
    out = []
    for slug in sorted(n for n in listdir(root, "memory/projects", r"[^.].*") if os.path.isdir(os.path.join(root, "memory", "projects", n))):
        card = read(root, f"memory/projects/{slug}/README.md")
        fm = frontmatter(card)
        status = fm.get("status", "active")
        m = re.search(r"^## Status\s*\n(.*?)(?=^## |\Z)", card, re.S | re.M)
        note = ""
        if m:
            note = next((l.strip(" -") for l in m.group(1).splitlines() if l.strip() and not l.strip().startswith("<!--")), "")
        ds = list(reversed(listdir(root, f"memory/projects/{slug}/decisions", r"\d{4}-\d{2}-\d{2}-.*\.md$")))
        latest = ("", "")
        if ds:
            t = read(root, f"memory/projects/{slug}/decisions/{ds[0]}")
            latest = (frontmatter(t).get("date", ds[0][:10]), first_heading(t, ds[0][:-3]))
        out.append({"slug": slug, "name": first_heading(card, slug), "status": status, "note": note, "latest": latest})
    order = {"active": 0, "paused": 1, "closed": 2}
    return sorted(out, key=lambda p: (order.get(p["status"], 3), p["name"].lower()))


def per_day(acts, today):
    days = [today - dt.timedelta(days=i) for i in range(ACTIVITY_DAYS - 1, -1, -1)]
    counts = {d: 0 for d in days}
    for a in acts:
        if a.get("event") == "session_start":
            d = parse_date(a["ts"])
            if d in counts:
                counts[d] += 1
    return [(d, counts[d]) for d in days]


def live_states(path):
    if not path:
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return {}
    rows = d if isinstance(d, list) else d.get("sessions", [])
    return {r.get("name"): (r.get("state") or r.get("status") or "") for r in rows if isinstance(r, dict) and r.get("name")}


# ── page ─────────────────────────────────────────────────────────────────────
CSS = """
:root{
  /* Layout: one column of panels, summary first; two columns from 900px. */
  --bg:#f4f6f5; --panel:#ffffff; --ink:#1d2421; --muted:#5d6a64; --line:#d9e0dc; --accent:#1f6f5c;
  --warn:#9a5b00; --warn-bg:#fff3df; --crit:#a3261f; --ok:#2f6d3a;
  --display:"IBM Plex Sans Condensed","Arial Narrow",sans-serif; --body:"IBM Plex Sans",system-ui,sans-serif;
}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){
  --bg:#121614; --panel:#1a201d; --ink:#e4ebe7; --muted:#9aa8a1; --line:#2c3531; --accent:#5cc2a4;
  --warn:#f0b35a; --warn-bg:#2d2414; --crit:#f0837b; --ok:#86c98f; color-scheme:dark}}
:root[data-theme="dark"]{
  --bg:#121614; --panel:#1a201d; --ink:#e4ebe7; --muted:#9aa8a1; --line:#2c3531; --accent:#5cc2a4;
  --warn:#f0b35a; --warn-bg:#2d2414; --crit:#f0837b; --ok:#86c98f; color-scheme:dark}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 var(--body)}
main{max-width:1100px;margin:0 auto;padding:24px 16px 48px;display:grid;gap:16px}
header{display:flex;flex-wrap:wrap;align-items:baseline;justify-content:space-between;gap:8px}
h1{font:600 28px/1.15 var(--display);margin:0;text-wrap:balance}
h2{font:600 15px/1.2 var(--display);letter-spacing:.04em;text-transform:uppercase;color:var(--muted);margin:0 0 10px}
.asof{color:var(--muted);font-size:13px}
.grid{display:grid;gap:16px}
@media (min-width:900px){.grid{grid-template-columns:1fr 1fr}}
section{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:16px;min-width:0}
section.attention{border-left:4px solid var(--warn)}
ul{margin:0;padding-left:18px} li{margin:4px 0}
.src{color:var(--muted);font-size:12px;word-break:break-all}
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}
td,th{text-align:left;padding:6px 8px 6px 0;border-bottom:1px solid var(--line);vertical-align:top}
th{font-weight:600;color:var(--muted);font-size:13px}
.pill{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12px;border:1px solid var(--line);color:var(--muted)}
.pill.warn{background:var(--warn-bg);color:var(--warn);border-color:transparent}
.empty{color:var(--muted)}
.tablewrap{overflow-x:auto}
nav{position:sticky;top:0;z-index:1;background:var(--bg);border-bottom:1px solid var(--line);margin:0 -16px;padding:8px 16px;display:flex;flex-wrap:wrap;gap:6px}
nav a{color:var(--accent);text-decoration:none;font-size:13px;padding:4px 10px;border:1px solid var(--line);border-radius:999px;background:var(--panel)}
nav a:hover,nav a:focus-visible{border-color:var(--accent);outline:none}
section{scroll-margin-top:56px}
html{scroll-behavior:smooth}
@media (prefers-reduced-motion:reduce){html{scroll-behavior:auto}}
svg text{fill:var(--muted);font:11px var(--body)}
svg .bar{fill:var(--accent)}
svg .grid{stroke:var(--line)}
"""


def ul(items, empty):
    return "<ul>" + "".join(items) + "</ul>" if items else f'<p class="empty">{esc(empty)}</p>'


def chart(series):
    w, h, pad = 560, 120, 24
    top = max([c for _, c in series] + [1])
    bw = (w - pad) / len(series)
    bars, labels = [], []
    for i, (d, c) in enumerate(series):
        bh = (h - 30) * c / top
        x = pad + i * bw + 2
        bars.append(f'<rect class="bar" x="{x:.1f}" y="{h - 18 - bh:.1f}" width="{bw - 4:.1f}" height="{bh:.1f}"><title>{d.isoformat()}: {c}</title></rect>')
        if i % 2 == 0 or i == len(series) - 1:
            labels.append(f'<text x="{x + (bw - 4) / 2:.1f}" y="{h - 4}" text-anchor="middle">{d.day}/{d.month}</text>')
    grid = f'<line class="grid" x1="{pad}" x2="{w}" y1="{h - 18}" y2="{h - 18}"/><text x="0" y="{12 + 0}">{top}</text>'
    return (f'<div class="tablewrap"><svg viewBox="0 0 {w} {h}" width="100%" role="img" '
            f'aria-label="Sessions per day, last {len(series)} days">{grid}{"".join(bars)}{"".join(labels)}</svg></div>')


def build(root, today, agents_json=None):
    acts = activity(root)
    wait_items, drafts = waiting(root)
    decs = decisions(root)
    dls = deadlines(root, today)
    dedicated, others = agents(root, acts, today)
    collabs = collaborators(root, acts, live_states(agents_json))
    series = per_day(acts, today)
    projs = projects(root)
    name = company_name(root)
    now = dt.datetime.now().strftime("%Y-%m-%d %H:%M")

    w_items = [f'<li>{esc(t)} <span class="src">{esc(s)}</span></li>' for t, s in wait_items]
    w_items += [f'<li>Draft to review: {esc(n)} <span class="src">drafts/{esc(n)} · {d.isoformat()}</span></li>' for n, d in drafts[:10]]
    need = len(w_items)

    ag_rows = "".join(
        f'<tr><td><strong>{esc(a["name"] or a["role"])}</strong><br><span class="src">{esc(a["role"])}</span></td>'
        f'<td>{esc(a["last"] or "—")}</td><td>{a["week"]}</td><td>{esc(plain(a["outcome"]) or "—")}</td></tr>'
        for a in dedicated)
    other_line = ", ".join(f"{esc(t)} ({c})" for t, c in others[:8]) or "none recorded"

    def state_pill(c):
        if c["state"]:
            return '<span class="pill warn">' + esc(c["state"]) + "</span>"
        return '<span class="pill">see agent view</span>'

    co_rows = "".join(
        f'<tr><td><strong>{esc(c["name"])}</strong></td><td>{esc(c["started"] or "—")}</td>'
        f'<td>{state_pill(c)}</td><td>{esc(plain(c["outcome"]) or "—")}</td></tr>' for c in collabs)

    def proj_row(p):
        pill = "pill warn" if p["status"] == "paused" else "pill"
        latest = f'{esc(p["latest"][0])} {esc(p["latest"][1])}' if p["latest"][1] else "—"
        return (f'<tr><td><strong>{esc(p["name"])}</strong><br><span class="src">memory/projects/{esc(p["slug"])}/</span></td>'
                f'<td><span class="{pill}">{esc(p["status"])}</span></td><td>{esc(p["note"]) or "—"}</td><td>{latest}</td></tr>')

    proj_rows = "".join(proj_row(p) for p in projs)
    dec_items = [f'<li><strong>{esc(d)}</strong> {esc(t)} <span class="src">{esc(by)} · {esc(src)}</span></li>' for d, t, by, src in decs]
    dl_items = [f'<li><strong>{d.strftime("%d %b")}</strong> {esc(w)} <span class="src">{esc(o)}</span></li>' for d, w, o in dls]

    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(name)} dashboard</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+Condensed:wght@600&family=IBM+Plex+Sans:wght@400;600&display=swap" rel="stylesheet">
<style>{CSS}</style></head>
<body><main>
<header><h1>{esc(name)}</h1><span class="asof">Read-only · built {esc(now)} from the company repo</span></header>
<nav aria-label="Sections"><a href="#waiting">Waiting for you ({need})</a><a href="#agents">Agents</a><a href="#sessions">Collaborator sessions</a><a href="#projects">Projects</a><a href="#decisions">Decisions</a><a href="#deadlines">Deadlines</a><a href="#activity">Activity</a></nav>
<section id="waiting" class="{'attention' if need else ''}"><h2>Waiting for you · {need}</h2>{ul(w_items, "Nothing is waiting for you.")}</section>
<div class="grid">
<section id="agents"><h2>Agents</h2><div class="tablewrap"><table><thead><tr><th>Agent</th><th>Last active</th><th>7 days</th><th>Last outcome</th></tr></thead><tbody>{ag_rows}</tbody></table></div>
<p class="src">Other collaborators used: {other_line}</p></section>
<section id="sessions"><h2>Collaborator sessions</h2>{('<div class="tablewrap"><table><thead><tr><th>Session</th><th>Started</th><th>State</th><th>Last report</th></tr></thead><tbody>' + co_rows + '</tbody></table></div>') if collabs else '<p class="empty">No collaborator sessions.</p>'}</section>
<section id="projects"><h2>Projects</h2>{('<div class="tablewrap"><table><thead><tr><th>Project</th><th>Status</th><th>Where it stands</th><th>Latest decision</th></tr></thead><tbody>' + proj_rows + '</tbody></table></div>') if projs else '<p class="empty">No projects in memory/projects/.</p>'}</section>
<section id="decisions"><h2>Latest decisions</h2>{ul(dec_items, "No decisions recorded yet.")}</section>
<section id="deadlines"><h2>Deadlines · next {DEADLINE_DAYS} days</h2>{ul(dl_items, "No deadlines in memory/deadlines.md for the next 30 days.")}</section>
</div>
<section id="activity"><h2>Sessions per day · last {ACTIVITY_DAYS} days</h2>{chart(series)}</section>
</main></body></html>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
    ap.add_argument("--out", default=None)
    ap.add_argument("--today", default=None)
    ap.add_argument("--agents-json", default=None)
    a = ap.parse_args()
    today = parse_date(a.today) if a.today else dt.date.today()
    out = a.out or os.path.join(a.root, "state", "dashboard.html")
    page = build(a.root, today, a.agents_json)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(page)
    print(out)


if __name__ == "__main__":
    main()
