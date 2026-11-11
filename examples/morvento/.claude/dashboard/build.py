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
# Light by default (the page is content-heavy), dark with the system setting.
# One dark header band; the violet-to-cyan gradient appears only in the header
# hairline, the activity bars and the sparkline. No scripts.
CSS = """
:root{
  --bg:#f4f6fb; --panel:#ffffff; --ink:#0d1117; --ink-2:#1f2937; --muted:#5f6878; --line:rgba(13,17,23,.08);
  --line-2:rgba(13,17,23,.14); --accent:#7c3aed; --accent-soft:rgba(124,58,237,.08); --link:#6d28d9;
  --warn:#9a4a00; --warn-bg:#fdf0dc; --warn-line:rgba(154,74,0,.22); --shadow:0 1px 2px rgba(8,11,20,.06),0 4px 14px rgba(8,11,20,.05);
  --head:#080b14; --head-ink:#e8eefa; --head-muted:#94a3b8;
  --violet:#a855f7; --cyan:#22d3ee;
  --display:"DM Serif Display",Georgia,"Times New Roman",serif;
  --body:"DM Sans",-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif;
  --mono:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
  --ease:cubic-bezier(.16,1,.3,1);
}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){
  --bg:#080b14; --panel:#121827; --ink:#e8eefa; --ink-2:#cbd5e1; --muted:#94a3b8; --line:rgba(232,238,250,.08);
  --line-2:rgba(232,238,250,.14); --accent:#b67cf9; --accent-soft:rgba(168,85,247,.12); --link:#22d3ee;
  --warn:#f5b45a; --warn-bg:rgba(245,180,90,.1); --warn-line:rgba(245,180,90,.28); --shadow:none; color-scheme:dark}}
:root[data-theme="dark"]{
  --bg:#080b14; --panel:#121827; --ink:#e8eefa; --ink-2:#cbd5e1; --muted:#94a3b8; --line:rgba(232,238,250,.08);
  --line-2:rgba(232,238,250,.14); --accent:#b67cf9; --accent-soft:rgba(168,85,247,.12); --link:#22d3ee;
  --warn:#f5b45a; --warn-bg:rgba(245,180,90,.1); --warn-line:rgba(245,180,90,.28); --shadow:none; color-scheme:dark}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
@media (prefers-reduced-motion:reduce){html{scroll-behavior:auto}*{transition:none!important}}
html,body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.55 var(--body);-webkit-font-smoothing:antialiased}
a{color:var(--link)}
:focus-visible{outline:2px solid var(--violet);outline-offset:2px;border-radius:4px}
.wrap{max-width:1240px;margin:0 auto;padding:0 24px}

/* Header band */
.top{background:var(--head);color:var(--head-ink);position:relative;padding:48px 0 112px;
  background-image:radial-gradient(rgba(168,85,247,.16) 1px,transparent 1.2px),radial-gradient(rgba(34,211,238,.10) 1px,transparent 1.2px);
  background-size:28px 28px,44px 44px;background-position:0 0,14px 20px}
.top .wrap{display:flex;flex-wrap:wrap;align-items:flex-end;justify-content:space-between;gap:16px}
.eyebrow{font:600 11px/1 var(--body);letter-spacing:.3em;text-transform:uppercase;color:var(--head-muted);margin:0 0 12px}
h1{font:400 clamp(34px,4.6vw,52px)/1.08 var(--display);letter-spacing:-.01em;margin:0;text-wrap:balance}
.asof{color:var(--head-muted);font-size:13px;text-align:right}
.asof strong{color:var(--head-ink);font-weight:500;display:block;font-size:15px}

/* Summary tiles: overlap the band */
.tiles{display:grid;gap:16px;grid-template-columns:repeat(auto-fit,minmax(min(210px,100%),1fr));margin-top:-52px;position:relative}
.tile{display:block;text-decoration:none;color:inherit;background:var(--panel);border:1px solid var(--line);border-radius:12px;
  padding:22px 24px;box-shadow:var(--shadow);transition:border-color .16s var(--ease),transform .16s var(--ease)}
.tile:hover{border-color:var(--line-2);transform:translateY(-1px)}
.tile .k{font:600 11px/1 var(--body);letter-spacing:.18em;text-transform:uppercase;color:var(--muted)}
.tile .v{font:400 44px/1 var(--display);margin:12px 0 6px;font-variant-numeric:lining-nums tabular-nums}
.tile .s{font-size:13px;color:var(--muted);min-height:1.5em}
.tile.hot{border-color:var(--warn-line)}
.tile.hot .v{color:var(--warn)}
.tile .spark{display:block;margin-top:4px}

/* Section nav */
nav{position:sticky;top:0;z-index:2;background:var(--bg);margin-top:44px}
nav::after{content:"";position:absolute;left:0;right:0;bottom:0;height:1px;background:linear-gradient(90deg,rgba(168,85,247,.45),rgba(34,211,238,.45))}
nav .wrap{display:flex;gap:4px;overflow-x:auto;padding-top:10px;padding-bottom:10px;scrollbar-width:none}
nav a{flex:none;color:var(--ink-2);text-decoration:none;font-size:13px;font-weight:500;padding:6px 12px;border-radius:999px}
nav a:hover{background:var(--accent-soft);color:var(--accent)}
nav a .n{display:inline-block;min-width:18px;margin-left:6px;padding:0 6px;border-radius:999px;background:var(--accent-soft);color:var(--accent);font-size:12px;text-align:center}

/* Panels */
main{display:grid;gap:20px;align-items:start;grid-template-columns:minmax(0,1fr)}
@media (min-width:1000px){main{grid-template-columns:repeat(12,minmax(0,1fr))}
  .c7{grid-column:span 7}.c5{grid-column:span 5}.c6{grid-column:span 6}.c12{grid-column:span 12}}
section{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:22px 24px;min-width:0;box-shadow:var(--shadow);scroll-margin-top:64px}
.sh{display:flex;align-items:baseline;justify-content:space-between;gap:12px;margin:0 0 14px;flex-wrap:wrap}
h2{font:400 22px/1.2 var(--display);margin:0;letter-spacing:-.005em}
.meta{font-size:12px;color:var(--muted)}
section.attention{border-color:var(--warn-line)}
.empty{color:var(--muted);margin:4px 0;padding:18px;border:1px dashed var(--line-2);border-radius:8px;text-align:center;font-size:14px}
.src{font:12px/1.4 var(--mono);color:var(--muted);word-break:break-all}
.pill{display:inline-block;white-space:nowrap;padding:2px 9px;border-radius:999px;font-size:12px;font-weight:500;border:1px solid var(--line-2);color:var(--muted)}
.pill.warn{background:var(--warn-bg);color:var(--warn);border-color:transparent}
.pill.on{background:var(--accent-soft);color:var(--accent);border-color:transparent}
ul.rows{list-style:none;margin:0;padding:0}
ul.rows>li{padding:12px 0;border-top:1px solid var(--line)}
ul.rows>li:first-child{border-top:0;padding-top:2px}

/* Waiting */
.wait li{display:grid;grid-template-columns:20px minmax(0,1fr);gap:12px}
.wait .dot{width:12px;height:12px;margin-top:6px;border-radius:50%;border:2px solid var(--accent)}
.wait .t{font-size:16px;color:var(--ink)}

/* Deadlines */
.dl li{display:grid;grid-template-columns:52px minmax(0,1fr) auto;gap:14px;align-items:center}
.date{text-align:center;border:1px solid var(--line-2);border-radius:8px;padding:5px 0 6px;line-height:1}
.date b{display:block;font:400 22px/1 var(--display)}
.date i{display:block;font:600 10px/1 var(--body);font-style:normal;letter-spacing:.16em;text-transform:uppercase;color:var(--muted);margin-top:4px}
.dl .soon .date{border-color:var(--warn-line);background:var(--warn-bg)}
.dl .soon .date b{color:var(--warn)}
.who{font-size:13px;color:var(--muted)}

/* Agents */
.agents{display:grid;gap:16px;grid-template-columns:repeat(auto-fit,minmax(min(250px,100%),1fr))}
.agent{border:1px solid var(--line);border-radius:12px;padding:16px 18px;display:flex;flex-direction:column;gap:10px}
.agent .hd{display:flex;align-items:center;gap:12px}
.mono-av{flex:none;width:38px;height:38px;border-radius:50%;display:grid;place-items:center;font:400 18px/1 var(--display);
  color:var(--accent);background:var(--accent-soft);border:1px solid var(--line)}
.agent .nm strong{display:block;font-size:16px;font-weight:600}
.agent .nm span{font:12px var(--mono);color:var(--muted)}
.agent .st{display:flex;justify-content:space-between;gap:8px;font-size:13px;color:var(--muted);flex-wrap:wrap}
.agent .st b{font-weight:600;color:var(--ink);font-variant-numeric:tabular-nums}
.agent blockquote{margin:0;padding:10px 12px;border-radius:8px;background:var(--bg);font-size:14px;color:var(--ink-2);
  display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
.agent blockquote.none{color:var(--muted)}
.others{margin:14px 0 0;font-size:13px;color:var(--muted)}

/* Projects, sessions, decisions */
.proj li .row1,.sess li .row1{display:flex;align-items:baseline;justify-content:space-between;gap:12px}
.proj li strong,.sess li strong{font-size:15px;font-weight:600}
.note{margin:4px 0 2px;color:var(--ink-2)}
.latest{font-size:13px;color:var(--muted)}
.latest em{font-style:normal;font-weight:600;letter-spacing:.12em;text-transform:uppercase;font-size:10px;margin-right:6px}
.dec li{display:grid;grid-template-columns:86px minmax(0,1fr);gap:12px}
.dec .d{font:12px/1.9 var(--mono);color:var(--muted);font-variant-numeric:tabular-nums}
.dec .t{font-weight:500}
.by{font-size:12px;color:var(--muted)}

/* Chart */
svg text{fill:var(--muted);font:11px var(--body)}
svg .gl{stroke:var(--line-2);stroke-dasharray:2 3}
svg .base{stroke:var(--line-2)}
svg .wk{fill:var(--accent-soft);opacity:.55}
svg .zero{fill:var(--line-2)}
svg text.today{fill:var(--ink);font-weight:600}
.chartnote{margin:8px 0 0;font-size:13px;color:var(--muted)}
.chartwrap{overflow-x:auto}
main.wrap{padding-top:36px;padding-bottom:28px}
footer{color:var(--muted);font-size:12px}
footer.wrap{padding-bottom:48px}
footer code{font-family:var(--mono)}
@media (max-width:640px){.wrap{padding:0 16px}.dec li{grid-template-columns:minmax(0,1fr);gap:0}.sh .meta{display:none}section{padding:18px}.top{padding:32px 0 96px}.asof{text-align:left}.tile .v{font-size:36px}}
"""

GRAD = ('<linearGradient id="{id}" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="{w}" y2="0">'
        '<stop offset="0" stop-color="#a855f7"/><stop offset="1" stop-color="#22d3ee"/></linearGradient>')


def rel_day(d, today):
    n = (d - today).days
    return "today" if n == 0 else "tomorrow" if n == 1 else f"in {n} days"


def short_ts(s):
    try:
        t = dt.datetime.fromisoformat(s)
        return f"{t.day} {t.strftime('%b %H:%M')}"
    except ValueError:
        return s


def empty(msg):
    return f'<p class="empty">{esc(msg)}</p>'


def chart(series, today):
    w, h, pad_l, pad_b, top_pad = 640, 190, 28, 26, 14
    top = max([c for _, c in series] + [1])
    plot_h = h - pad_b - top_pad
    bw = (w - pad_l) / len(series)
    base = h - pad_b
    out = [f"<defs>{GRAD.format(id='bars', w=w)}</defs>"]
    for i, (d, c) in enumerate(series):
        x = pad_l + i * bw
        if d.weekday() >= 5:
            out.append(f'<rect class="wk" x="{x:.1f}" y="{top_pad}" width="{bw:.1f}" height="{plot_h}"/>')
    for v in sorted({top, (top + 1) // 2} - {0}):
        y = base - plot_h * v / top
        out.append(f'<line class="gl" x1="{pad_l}" x2="{w}" y1="{y:.1f}" y2="{y:.1f}"/><text x="{pad_l - 8}" y="{y + 4:.1f}" text-anchor="end">{v}</text>')
    out.append(f'<line class="base" x1="{pad_l}" x2="{w}" y1="{base}" y2="{base}"/>')
    for i, (d, c) in enumerate(series):
        x = pad_l + i * bw + bw * 0.18
        bwi = bw * 0.64
        tip = f"<title>{d.strftime('%a')} {d.isoformat()}: {c} session{'s' if c != 1 else ''}</title>"
        if c:
            bh = max(plot_h * c / top, 3)
            out.append(f'<rect x="{x:.1f}" y="{base - bh:.1f}" width="{bwi:.1f}" height="{bh:.1f}" rx="3" fill="url(#bars)">{tip}</rect>')
        else:
            out.append(f'<rect class="zero" x="{x:.1f}" y="{base - 2}" width="{bwi:.1f}" height="2" rx="1">{tip}</rect>')
        is_today = d == today
        if is_today or i % 2 == (len(series) - 1) % 2:
            label = "Today" if is_today else f"{d.day} {d.strftime('%b')}"
            cls = ' class="today"' if is_today else ""
            out.append(f'<text{cls} x="{x + bwi / 2:.1f}" y="{h - 6}" text-anchor="middle">{label}</text>')
    return (f'<div class="chartwrap"><svg viewBox="0 0 {w} {h}" width="100%" role="img" '
            f'aria-label="Sessions per day, last {len(series)} days">{"".join(out)}</svg></div>')


def sparkline(series):
    w, h = 180, 28
    top = max([c for _, c in series] + [1])
    step = w / max(len(series) - 1, 1)
    pts = " ".join(f"{i * step:.1f},{h - 3 - (h - 6) * c / top:.1f}" for i, (_, c) in enumerate(series))
    return (f'<svg class="spark" viewBox="0 0 {w} {h}" width="100%" height="{h}" aria-hidden="true" preserveAspectRatio="none">'
            f'<defs>{GRAD.format(id="spk", w=w)}</defs><polyline points="{pts}" fill="none" stroke="url(#spk)" '
            f'stroke-width="2" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/></svg>')


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
    now = dt.datetime.now()

    # Waiting: the journal line is the whole current list, usually several
    # items separated by "; " -- show and count each one.
    w_items = []
    for t, src in wait_items:
        parts = [p.strip() for p in t.split("; ") if p.strip()] or [t]
        for p in parts:
            w_items.append(f'<li><span class="dot"></span><div><div class="t">{esc(p)}</div><div class="src">{esc(src)}</div></div></li>')
    w_items += [f'<li><span class="dot"></span><div><div class="t">Draft to review: {esc(n)}</div>'
                f'<div class="src">drafts/{esc(n)} · {d.isoformat()}</div></div></li>' for n, d in drafts[:10]]
    need = len(w_items)
    waiting_html = f'<ul class="rows wait">{"".join(w_items)}</ul>' if w_items else empty("Nothing is waiting for you.")

    def dl_row(d, what, who):
        soon = (d - today).days <= 7
        pill = '<span class="pill warn">' if soon else '<span class="pill">'
        who_html = f'<div class="who">{esc(who)}</div>' if who else ""
        return (f'<li class="{"soon" if soon else ""}"><div class="date"><b>{d.day}</b><i>{d.strftime("%b")}</i></div>'
                f'<div><div>{esc(what)}</div>{who_html}</div>{pill}{rel_day(d, today)}</span></li>')

    dl_html = (f'<ul class="rows dl">{"".join(dl_row(*r) for r in dls)}</ul>' if dls
               else empty(f"No deadlines in memory/deadlines.md for the next {DEADLINE_DAYS} days."))
    soon_n = sum(1 for d, _, _ in dls if (d - today).days <= 7)

    def agent_card(a):
        label = a["name"] or a["role"]
        out = plain(a["outcome"])
        status = (f'<span class="pill on">{a["week"]} session{"s" if a["week"] != 1 else ""} this week</span>' if a["week"]
                  else '<span class="pill">Quiet this week</span>')
        quote = (f'<blockquote title="{esc(out)}">{esc(out)}</blockquote>' if out
                 else '<blockquote class="none">No outcome recorded yet.</blockquote>')
        return (f'<div class="agent"><div class="hd"><span class="mono-av" aria-hidden="true">{esc(label[:1].upper())}</span>'
                f'<div class="nm"><strong>{esc(label)}</strong><span>{esc(a["role"])}</span></div></div>'
                f'<div class="st"><span>Last active <b>{esc(short_ts(a["last"]) if a["last"] else "—")}</b></span>{status}</div>{quote}</div>')

    other_line = ", ".join(f"{esc(t)} ({c})" for t, c in others[:8]) or "none recorded"

    def state_pill(c):
        if c["state"]:
            return '<span class="pill warn">' + esc(c["state"]) + "</span>"
        return '<span class="pill">see agent view</span>'

    sess_html = (('<ul class="rows sess">' + "".join(
        f'<li><div class="row1"><strong>{esc(c["name"])}</strong>{state_pill(c)}</div>'
        f'<div class="note">{esc(plain(c["outcome"]) or "No report yet.")}</div>'
        f'<div class="latest">Started {esc(c["started"] or "—")}</div></li>' for c in collabs) + "</ul>")
        if collabs else empty("No collaborator sessions."))

    def proj_row(p):
        pill = {"paused": "pill warn", "active": "pill on"}.get(p["status"], "pill")
        latest = (f'<div class="latest"><em>Latest decision</em>{esc(p["latest"][0])} {esc(p["latest"][1])}</div>'
                  if p["latest"][1] else "")
        note = f'<div class="note">{esc(p["note"])}</div>' if p["note"] else ""
        return (f'<li><div class="row1"><strong>{esc(p["name"])}</strong><span class="{pill}">{esc(p["status"])}</span></div>'
                f'{note}{latest}<div class="src">memory/projects/{esc(p["slug"])}/</div></li>')

    proj_html = (f'<ul class="rows proj">{"".join(proj_row(p) for p in projs)}</ul>' if projs
                 else empty("No projects in memory/projects/."))
    active_n = sum(1 for p in projs if p["status"] == "active")

    def dec_row(d, t, by, src):
        by_html = f'<div class="by">by {esc(by)}</div>' if by else ""
        return (f'<li><span class="d">{esc(d)}</span><div><div class="t">{esc(t)}</div>'
                f'{by_html}<div class="src">{esc(src)}</div></div></li>')

    dec_html = (f'<ul class="rows dec">{"".join(dec_row(*x) for x in decs)}</ul>' if decs
                else empty("No decisions recorded yet."))

    week = sum(c for _, c in series[-7:])
    total = sum(c for _, c in series)
    next_dl = f"Next: {dls[0][0].day} {dls[0][0].strftime('%b')} · {rel_day(dls[0][0], today)}" if dls else "Nothing due"
    tiles = (
        f'<a class="tile{" hot" if need else ""}" href="#waiting"><div class="k">Waiting for you</div><div class="v">{need}</div>'
        f'<div class="s">{"Decisions and drafts to review" if need else "All clear"}</div></a>'
        f'<a class="tile{" hot" if soon_n else ""}" href="#deadlines"><div class="k">Deadlines · {DEADLINE_DAYS} days</div>'
        f'<div class="v">{len(dls)}</div><div class="s">{esc(next_dl)}</div></a>'
        f'<a class="tile" href="#activity"><div class="k">Sessions · 7 days</div><div class="v">{week}</div>{sparkline(series)}</a>'
        f'<a class="tile" href="#projects"><div class="k">Active projects</div><div class="v">{active_n}</div>'
        f'<div class="s">{len(projs)} in memory/projects/</div></a>')

    navs = (("waiting", "Waiting for you", need), ("deadlines", "Deadlines", len(dls)), ("agents", "Agents", None),
            ("projects", "Projects", None), ("sessions", "Collaborator sessions", None),
            ("decisions", "Decisions", None), ("activity", "Activity", None))
    nav = "".join(f'<a href="#{a}">{l}' + (f'<span class="n">{n}</span>' if n else "") + "</a>" for a, l, n in navs)

    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(name)} dashboard</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display&family=DM+Sans:opsz,wght@9..40,400;9..40,500;9..40,600&family=JetBrains+Mono:wght@400&display=swap" rel="stylesheet">
<style>{CSS}</style></head>
<body>
<header class="top"><div class="wrap"><div><p class="eyebrow">Company dashboard</p><h1>{esc(name)}</h1></div>
<div class="asof"><strong>{today.strftime("%A %d %B %Y").replace(" 0", " ")}</strong>Read-only · built {esc(now.strftime("%H:%M"))} from the company repo</div></div></header>
<div class="wrap"><div class="tiles">{tiles}</div></div>
<nav aria-label="Sections"><div class="wrap">{nav}</div></nav>
<main class="wrap">
<section id="waiting" class="c7{' attention' if need else ''}"><div class="sh"><h2>Waiting for you · {need}</h2><span class="meta">Latest journal and drafts/</span></div>{waiting_html}</section>
<section id="deadlines" class="c5"><div class="sh"><h2>Deadlines · next {DEADLINE_DAYS} days</h2><span class="meta">memory/deadlines.md</span></div>{dl_html}</section>
<section id="agents" class="c12"><div class="sh"><h2>Agents</h2><span class="meta">Dedicated roles · last {ACTIVITY_DAYS} days of activity</span></div>
<div class="agents">{"".join(agent_card(a) for a in dedicated)}</div><p class="others">Other collaborators used: {other_line}</p></section>
<section id="projects" class="c7"><div class="sh"><h2>Projects</h2><span class="meta">{active_n} active</span></div>{proj_html}</section>
<section id="sessions" class="c5"><div class="sh"><h2>Collaborator sessions</h2><span class="meta">state/briefs/</span></div>{sess_html}</section>
<section id="decisions" class="c5"><div class="sh"><h2>Latest decisions</h2><span class="meta">Active only · last {RECENT_DECISIONS}</span></div>{dec_html}</section>
<section id="activity" class="c7"><div class="sh"><h2>Sessions per day · last {ACTIVITY_DAYS} days</h2><span class="meta">{total} total · weekends shaded</span></div>{chart(series, today)}{'' if total else '<p class="chartnote">No sessions recorded in the last ' + str(ACTIVITY_DAYS) + ' days.</p>'}</section>
</main>
<footer class="wrap">Built by <code>.claude/dashboard/build.py</code> from the files in the company repo. To change something here, change the file it comes from.</footer>
</body></html>
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
