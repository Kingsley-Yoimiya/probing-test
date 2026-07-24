#!/usr/bin/env python3
"""P1-SW-A 趋势型离线线索：看 cuda_frag_gap_bytes / frag_stall_ms / step_ms。

不读取 injection ground-truth 窗；只比较 C0 vs C1 的可分性（探索冻结用）。
正式 D-level 仍走共享 score_dlevel_*.py + Probing SQL。
"""
from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path


def load_steps(root: Path, case: str, config: str) -> list[dict]:
    rows: list[dict] = []
    base = root / case / "by_pod"
    if not base.exists():
        return rows
    for pod_dir in base.iterdir():
        for p in pod_dir.rglob("rank_*.jsonl"):
            if f"/{config}/" not in str(p).replace("\\", "/") and f"/{config}" not in str(p.parent):
                # 路径形如 .../round_1/C0_baseline/ranks/rank_0000.jsonl
                if config not in str(p):
                    continue
            for line in p.read_text(errors="ignore").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return rows


def median_field(rows: list[dict], field: str, lo: int = 50, hi: int = 300) -> float | None:
    vals = [float(r[field]) for r in rows if lo <= int(r.get("step", -1)) < hi and field in r]
    if not vals:
        return None
    return float(statistics.median(vals))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--result-root", required=True)
    ap.add_argument("--case", default="P1-SW-A")
    ap.add_argument("--write-md", default="")
    args = ap.parse_args()
    root = Path(args.result_root)
    c0 = load_steps(root, args.case, "C0_baseline")
    c1 = load_steps(root, args.case, "C1_inject_none")
    lines = [f"# trend {args.case}", ""]
    for name, rows in [("C0", c0), ("C1", c1)]:
        sm = median_field(rows, "step_ms")
        gap = median_field(rows, "cuda_frag_gap_bytes")
        st = median_field(rows, "frag_stall_ms")
        lines.append(f"- {name}: n={len(rows)} step_ms_med={sm} gap_med={gap} stall_med={st}")
    sm0 = median_field(c0, "step_ms") or 0.0
    sm1 = median_field(c1, "step_ms") or 0.0
    ratio = (sm1 / sm0) if sm0 > 0 else None
    lines.append(f"- C1/C0 step_ms ≈ {ratio}")
    gap0 = median_field(c0, "cuda_frag_gap_bytes") or 0.0
    gap1 = median_field(c1, "cuda_frag_gap_bytes") or 0.0
    lines.append(f"- gap C1-C0 ≈ {gap1 - gap0}")
    text = "\n".join(lines) + "\n"
    print(text)
    if args.write_md:
        Path(args.write_md).write_text(text)


if __name__ == "__main__":
    main()
