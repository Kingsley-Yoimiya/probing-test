#!/usr/bin/env python3
"""从 Probing live 数据生成可视化预览 HTML（无 Dioxus 构建时的截图素材）。"""
from __future__ import annotations

import html
import json
import subprocess
import sys
from pathlib import Path


def cli_query(cli: str, pid: int, sql: str) -> list[dict]:
    proc = subprocess.run(
        [cli, "-t", str(pid), "query", "--format", "json", sql],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return []
    try:
        data = json.loads(proc.stdout)
        return data if isinstance(data, list) else []
    except json.JSONDecodeError:
        return []


def fetch_overview(base: str) -> dict:
    import urllib.request

    try:
        with urllib.request.urlopen(f"{base}/apis/overview", timeout=8) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return {}


STYLE = """
body { font-family: Inter, system-ui, sans-serif; margin: 0; background: #f9fafb; color: #111827; }
.sidebar { width: 220px; background: linear-gradient(180deg,#0f172a,#1e293b); color:#e2e8f0; min-height:100vh; float:left; padding:16px; box-sizing:border-box; }
.sidebar h1 { font-size:18px; margin:0 0 16px; color:#93c5fd; }
.sidebar a { display:block; color:#cbd5e1; text-decoration:none; padding:6px 8px; border-radius:6px; margin:2px 0; font-size:13px; }
.sidebar a.active { background:#2563eb; color:white; }
.main { margin-left:220px; padding:24px; }
.card { background:white; border:1px solid #e5e7eb; border-radius:10px; padding:16px; margin-bottom:16px; box-shadow:0 1px 2px rgba(0,0,0,.04); }
h2 { margin:0 0 12px; font-size:20px; }
table { width:100%; border-collapse:collapse; font-size:13px; }
th,td { border-bottom:1px solid #e5e7eb; padding:8px 10px; text-align:left; }
th { background:#f3f4f6; font-weight:600; }
.badge { display:inline-block; background:#dbeafe; color:#1d4ed8; padding:2px 8px; border-radius:999px; font-size:11px; }
.note { color:#6b7280; font-size:12px; margin-top:8px; }
.grid2 { display:grid; grid-template-columns:1fr 1fr; gap:16px; }
.stat { font-size:28px; font-weight:700; color:#2563eb; }
"""


def page(title: str, nav: str, body: str, note: str = "") -> str:
    note_html = f'<p class="note">{html.escape(note)}</p>' if note else ""
    return f"""<!doctype html><html><head><meta charset=utf-8><title>{html.escape(title)}</title>
<style>{STYLE}</style></head><body>
<div class="sidebar"><h1>Probing</h1>{nav}</div>
<div class="main"><h2>{html.escape(title)}</h2>{note_html}{body}</div></body></html>"""


def nav(active: str) -> str:
    items = [
        ("dashboard", "Dashboard"),
        ("spans", "Distributed Spans"),
        ("training", "Training"),
        ("profiling", "Profiling"),
        ("analytics", "Analytics"),
        ("python", "Python"),
        ("agent", "Investigate"),
    ]
    links = []
    for k, label in items:
        cls = ' class="active"' if k == active else ""
        links.append(f'<a href="#"{cls}>{label}</a>')
    return "\n".join(links)


def table_from_rows(rows: list[dict], limit: int = 20) -> str:
    if not rows:
        return "<p>（暂无数据）</p>"
    cols = list(rows[0].keys())
    head = "".join(f"<th>{html.escape(str(c))}</th>" for c in cols)
    body_rows = [
        "<tr>" + "".join(f"<td>{html.escape(str(r.get(c, '')))}</td>" for c in cols) + "</tr>"
        for r in rows[:limit]
    ]
    return f"<table><thead><tr>{head}</tr></thead><tbody>{''.join(body_rows)}</tbody></table>"


def render_all(base: str, cli: str, pid: int, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    note = "预览页由 live 探针数据实时渲染（等价于 Web UI 各页面展示的数据源）"

    overview = fetch_overview(base)
    mem_rows = cli_query(
        cli,
        pid,
        "SELECT ts, rss_bytes FROM process.memory ORDER BY ts DESC LIMIT 12",
    )
    span_rows = cli_query(
        cli,
        pid,
        """
        SELECT s.name, s.phase, round((e.time - s.time)/1e6,2) AS ms
        FROM python.trace_event s
        JOIN python.trace_event e ON s.span_id=e.span_id AND e.record_type='span_end'
        WHERE s.record_type='span_start'
        ORDER BY s.time DESC LIMIT 20
        """,
    )
    step_rows = cli_query(
        cli,
        pid,
        "SELECT local_step, duration_ms, loss FROM train.step ORDER BY local_step DESC LIMIT 15",
    )
    tables = cli_query(cli, pid, "SHOW TABLES")

    pid_val = overview.get("pid", pid)
    dash_body = f"""
<div class="grid2">
  <div class="card"><div class="stat">{pid_val}</div><div>Process PID</div></div>
  <div class="card"><div class="stat">{len(span_rows)}</div><div>Recent Spans</div></div>
</div>
<div class="card"><span class="badge">/apis/overview</span><pre style="font-size:12px;overflow:auto">{html.escape(json.dumps(overview, indent=2)[:1500])}</pre></div>
<div class="card"><span class="badge">process.memory</span>{table_from_rows(mem_rows)}</div>
"""
    pages = {
        "preview_dashboard.html": ("Dashboard", "dashboard", dash_body),
        "preview_spans.html": (
            "Distributed Spans",
            "spans",
            f'<div class="card"><span class="badge">python.trace_event</span>{table_from_rows(span_rows)}</div>',
        ),
        "preview_training.html": (
            "Training",
            "training",
            f'<div class="card"><span class="badge">train.step</span>{table_from_rows(step_rows)}</div>',
        ),
        "preview_profiling.html": (
            "Profiling",
            "profiling",
            """<div class="card"><span class="badge">pprof</span><p>CPU 火焰图：<code>probing flamegraph</code> / Web <code>/profiling/pprof</code></p></div>
<div class="card"><span class="badge">torch</span><p>Chrome trace：<code>/apis/pythonext/pytorch/timeline</code></p></div>""",
        ),
        "preview_analytics.html": (
            "Analytics",
            "analytics",
            f'<div class="card"><span class="badge">SHOW TABLES</span>{table_from_rows(tables, 40)}</div>',
        ),
        "preview_python.html": (
            "Python",
            "python",
            '<div class="card"><p>函数级 live trace：<code>/python</code>，CLI <code>probing eval</code></p></div>',
        ),
        "preview_agent.html": (
            "Investigate",
            "agent",
            '<div class="card"><p>Playbook 诊断 Agent：<code>/agent</code>，CLI <code>probing skill</code></p></div>',
        ),
    }
    for fname, (title, key, body) in pages.items():
        (out_dir / fname).write_text(page(title, nav(key), body, note), encoding="utf-8")

    (out_dir / "preview_meta.json").write_text(
        json.dumps({"base": base, "pid": pid_val, "spans": len(span_rows)}, indent=2),
        encoding="utf-8",
    )


if __name__ == "__main__":
    base, cli, pid_s, out_s = sys.argv[1:5]
    render_all(base.rstrip("/"), cli, int(pid_s), Path(out_s))
    print(f"rendered -> {out_s}")
