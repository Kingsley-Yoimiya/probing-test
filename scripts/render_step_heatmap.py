#!/usr/bin/env python3
"""从 live train.step span 渲染 Step × Rank 热力图 HTML（供 headless 截图）。"""
from __future__ import annotations

import html
import json
import subprocess
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from pathlib import Path

STEP_SQL = """
SELECT s.attributes,
  CAST((CAST(e.time AS BIGINT) - CAST(s.time AS BIGINT)) / 1000 AS DOUBLE) AS duration_us
FROM python.trace_event s
JOIN python.trace_event e
  ON s.span_id = e.span_id AND e.record_type = 'span_end'
WHERE s.record_type = 'span_start' AND s.name = 'train.step'
ORDER BY s.time ASC
"""


def cli_query(cli: str, pid: int, sql: str) -> list[dict]:
    proc = subprocess.run(
        [cli, "-t", str(pid), "query", "--format", "json", sql.strip()],
        capture_output=True,
        text=True,
        env={**dict(**{k: v for k, v in __import__("os").environ.items()}), "PROBING_CLI_MODE": "1"},
    )
    if proc.returncode != 0:
        return []
    try:
        data = json.loads(proc.stdout)
        return data if isinstance(data, list) else []
    except json.JSONDecodeError:
        return []


def rows_to_samples(rows: list[dict]) -> list[dict]:
    samples: list[dict] = []
    for row in rows:
        attrs_raw = row.get("attributes") or "{}"
        meta = json.loads(attrs_raw) if isinstance(attrs_raw, str) else dict(attrs_raw)
        rank = int(meta.get("rank", -1))
        if rank < 0:
            rank = 0
        step = int(meta.get("local_step", meta.get("global_step", -1)))
        if step < 0:
            continue
        duration_ms = float(row.get("duration_us", 0.0)) / 1000.0
        if duration_ms <= 0:
            continue
        samples.append(
            {
                "rank": rank,
                "local_step": step,
                "coord_step": step,
                "duration_ms": duration_ms,
            }
        )
    return samples


def fetch_via_cli(cli: str, pids: list[int]) -> dict:
    merged: list[dict] = []
    for pid in pids:
        merged.extend(rows_to_samples(cli_query(cli, pid, STEP_SQL)))
    ranks = {s["rank"] for s in merged}
    steps = {s["local_step"] for s in merged}
    return {
        "samples": merged,
        "rank_count": len(ranks),
        "step_count": len(steps),
        "cluster": len(pids) > 1,
        "nodes_queried": len(pids),
        "nodes_failed": [],
    }


def fetch_step_matrix_api(base: str, cluster: bool = True, limit: int = 40) -> dict:
    url = f"{base.rstrip('/')}/apis/training/step_matrix?limit={limit}&cluster={str(cluster).lower()}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.loads(resp.read().decode())


def build_heatmap(samples: list[dict]) -> tuple[list[int], list[int], dict[tuple[int, int], dict], float]:
    raw: dict[tuple[int, int], float] = defaultdict(float)
    ranks: set[int] = set()
    steps: set[int] = set()
    for s in samples:
        step = int(s.get("local_step", -1))
        if step < 0:
            continue
        rank = int(s.get("rank", 0))
        if rank < 0:
            rank = 0
        ranks.add(rank)
        steps.add(step)
        key = (rank, step)
        raw[key] = max(raw[key], float(s.get("duration_ms", 0.0)))

    rank_list = sorted(ranks)
    step_list = sorted(steps)
    if len(step_list) > 40:
        step_list = step_list[-40:]

    medians: dict[int, float] = {}
    for step in step_list:
        vals = sorted(raw.get((r, step), 0.0) for r in rank_list if (r, step) in raw)
        if vals:
            medians[step] = vals[len(vals) // 2]

    max_ms = max(raw.values(), default=1.0) or 1.0
    cells: dict[tuple[int, int], dict] = {}
    for (rank, step), dur in raw.items():
        if step not in step_list:
            continue
        median = medians.get(step, dur)
        outlier = dur > median * 1.2 and len(rank_list) > 1
        cells[(rank, step)] = {"duration_ms": dur, "outlier": outlier}

    return rank_list, step_list, cells, max_ms


def render_html(data: dict, title: str = "Step straggler heatmap") -> str:
    samples = data.get("samples") or []
    ranks, steps, cells, max_ms = build_heatmap(samples)
    multi = len(ranks) > 1
    subtitle = (
        "cluster scan · darker = slower · red ring = outlier (>1.2× step median)"
        if multi
        else "single-process view · bar height = train.step duration"
    )

    if multi:
        grid_rows = []
        header = "".join(f'<div class="cell head step">{s}</div>' for s in steps)
        grid_rows.append(
            f'<div class="row"><div class="cell head rank">rank \\ step</div>{header}</div>'
        )
        for rank in ranks:
            row_cells = [f'<div class="cell head rank">R{rank}</div>']
            for step in steps:
                cell = cells.get((rank, step))
                if cell:
                    pct = min(1.0, max(0.0, cell["duration_ms"] / max_ms))
                    alpha = 0.15 + pct * 0.85
                    ring = " outlier" if cell["outlier"] else ""
                    title_attr = html.escape(
                        f"rank {rank} step {step}: {cell['duration_ms']:.1f} ms"
                    )
                    row_cells.append(
                        f'<div class="cell heat{ring}" style="background:rgba(109,40,217,{alpha:.3f})" '
                        f'title="{title_attr}"></div>'
                    )
                else:
                    row_cells.append('<div class="cell empty"></div>')
            grid_rows.append(f'<div class="row">{"".join(row_cells)}</div>')
        viz = f'<div class="heatmap">{"".join(grid_rows)}</div>'
    else:
        bars = []
        for step in steps:
            for rank in ranks:
                cell = cells.get((rank, step))
                if not cell:
                    continue
                pct = min(1.0, max(0.08, cell["duration_ms"] / max_ms))
                h = int(pct * 120)
                avg = sum(c["duration_ms"] for c in cells.values()) / max(len(cells), 1)
                slow = cell["duration_ms"] > avg * 1.2
                color = "#ef4444" if slow else "#7c3aed"
                bars.append(
                    f'<div class="bar-wrap" title="step {step}: {cell["duration_ms"]:.1f} ms">'
                    f'<div class="bar" style="height:{h}px;background:{color}"></div>'
                    f'<span class="bar-label">{step}</span></div>'
                )
        viz = f'<div class="bars">{"".join(bars)}</div>'

    stats = [
        ("Ranks", str(data.get("rank_count", len(ranks)))),
        ("Steps", str(data.get("step_count", len(steps)))),
        ("Samples", str(len(samples))),
        ("Cluster", "yes" if data.get("cluster") else "no"),
    ]
    stat_html = "".join(
        f'<div class="stat"><div class="stat-val">{html.escape(v)}</div>'
        f'<div class="stat-lbl">{html.escape(k)}</div></div>'
        for k, v in stats
    )

    return f"""<!doctype html>
<html><head><meta charset=utf-8><title>{html.escape(title)}</title>
<style>
body {{ font-family: Inter, system-ui, sans-serif; margin: 0; background: #f9fafb; color: #111827; }}
.wrap {{ max-width: 1200px; margin: 0 auto; padding: 24px; }}
.card {{ background: #fff; border: 1px solid #e5e7eb; border-radius: 12px; padding: 20px; box-shadow: 0 1px 2px rgba(0,0,0,.04); }}
h1 {{ margin: 0 0 6px; font-size: 22px; }}
.sub {{ color: #6b7280; font-size: 13px; margin-bottom: 16px; }}
.stats {{ display: grid; grid-template-columns: repeat(4, minmax(0,1fr)); gap: 12px; margin-bottom: 16px; }}
.stat {{ background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 8px; padding: 10px 12px; }}
.stat-val {{ font-size: 20px; font-weight: 700; color: #6d28d9; }}
.stat-lbl {{ font-size: 11px; color: #6b7280; text-transform: uppercase; letter-spacing: .04em; }}
.heatmap {{ display: grid; gap: 4px; overflow-x: auto; }}
.row {{ display: grid; grid-template-columns: auto repeat({max(len(steps), 1)}, minmax(28px, 1fr)); gap: 4px; align-items: center; }}
.cell {{ min-height: 28px; min-width: 28px; border-radius: 4px; }}
.cell.head {{ font-size: 10px; color: #6b7280; font-family: ui-monospace, monospace; display:flex; align-items:center; justify-content:center; background: transparent; }}
.cell.head.rank {{ justify-content: flex-end; padding-right: 8px; }}
.cell.heat {{ border: 1px solid rgba(109,40,217,.15); }}
.cell.heat.outlier {{ box-shadow: 0 0 0 2px #ef4444; }}
.cell.empty {{ background: #f3f4f6; }}
.bars {{ display: flex; align-items: flex-end; gap: 6px; min-height: 150px; padding-top: 8px; overflow-x: auto; }}
.bar-wrap {{ display:flex; flex-direction:column; align-items:center; gap:4px; min-width:36px; }}
.bar {{ width: 28px; border-radius: 4px 4px 0 0; }}
.bar-label {{ font-size: 9px; color: #6b7280; font-family: ui-monospace, monospace; }}
.note {{ margin-top: 12px; font-size: 12px; color: #9ca3af; }}
</style></head>
<body><div class="wrap"><div class="card">
<h1>{html.escape(title)}</h1>
<p class="sub">{html.escape(subtitle)}</p>
<div class="stats">{stat_html}</div>
{viz}
<p class="note">Live train.step spans · ranks {html.escape(str(ranks))}</p>
</div></div></body></html>"""


def main() -> None:
    args = sys.argv[1:]
    cli = "/home/yjr/probing-test/probing/target/release/probing-cli"
    base = "http://127.0.0.1:8767"
    out_html = Path("step_heatmap.html")
    pids: list[int] = []

    i = 0
    while i < len(args):
        if args[i] == "--cli" and i + 1 < len(args):
            cli = args[i + 1]
            i += 2
        elif args[i] == "--pids" and i + 1 < len(args):
            pids = [int(x) for x in args[i + 1].split(",") if x.strip()]
            i += 2
        elif args[i].startswith("http"):
            base = args[i]
            i += 1
        else:
            out_html = Path(args[i])
            i += 1

    if pids:
        data = fetch_via_cli(cli, pids)
    else:
        try:
            data = fetch_step_matrix_api(base, cluster=True)
        except urllib.error.URLError as exc:
            print(f"fetch failed: {exc}", file=sys.stderr)
            sys.exit(1)

    if not data.get("samples"):
        print("no train.step samples", file=sys.stderr)
        sys.exit(1)

    out_html.write_text(render_html(data), encoding="utf-8")
    print(
        json.dumps(
            {
                "html": str(out_html),
                "rank_count": data.get("rank_count"),
                "step_count": data.get("step_count"),
                "samples": len(data.get("samples", [])),
            }
        )
    )


if __name__ == "__main__":
    main()
