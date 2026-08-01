#!/usr/bin/env python3
"""P1-SW-C Loud 验收：median 或 p99/max 尖刺任一达标即通过。

2C 是 one-shot 结构盲区 case——median 常接近 1.0，但 max/p99 应显著抬升。
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path


def load_steps(path: Path, lo: int, hi: int) -> list[float]:
    xs: list[float] = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            s = o.get("step")
            if s is None or not (lo <= int(s) <= hi):
                continue
            if "step_ms" in o:
                xs.append(float(o["step_ms"]))
    return xs


def find_rank(case_root: Path, cfg: str, rank: int) -> Path | None:
    hits = sorted(case_root.glob(f"by_pod/*/round_1/{cfg}/ranks/rank_{rank:04d}.jsonl"))
    return hits[0] if hits else None


def pct(xs: list[float], p: float) -> float:
    s = sorted(xs)
    return s[max(0, min(len(s) - 1, int(p * (len(s) - 1))))]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--result-root", required=True)
    ap.add_argument("--case", default="P1-HW-C")
    ap.add_argument("--lo", type=int, default=100)
    ap.add_argument("--hi", type=int, default=300)
    ap.add_argument("--min-median-ratio", type=float, default=1.3)
    ap.add_argument("--min-p99-ratio", type=float, default=1.5)
    ap.add_argument("--min-max-ratio", type=float, default=2.5)
    ap.add_argument("--victim-rank", type=int, default=7)
    ap.add_argument("--write-md", default="")
    args = ap.parse_args()

    root = Path(args.result_root) / args.case
    rows = []
    ok = False
    for rank in (0, args.victim_rank):
        c0p = find_rank(root, "C0_baseline", rank)
        c1p = find_rank(root, "C1_inject_none", rank)
        if not c0p or not c1p:
            rows.append(f"| rank{rank} | missing jsonl | |")
            continue
        c0 = load_steps(c0p, args.lo, args.hi)
        c1 = load_steps(c1p, args.lo, args.hi)
        if not c0 or not c1:
            rows.append(f"| rank{rank} | empty window | |")
            continue
        med_r = statistics.median(c1) / statistics.median(c0)
        p99_r = pct(c1, 0.99) / max(1e-9, pct(c0, 0.99))
        max_r = max(c1) / max(1e-9, max(c0))
        hit = (
            med_r >= args.min_median_ratio
            or p99_r >= args.min_p99_ratio
            or max_r >= args.min_max_ratio
        )
        ok = ok or (hit and rank == args.victim_rank)
        rows.append(
            f"| rank{rank} | med {statistics.median(c1):.1f}/{statistics.median(c0):.1f}={med_r:.2f} "
            f"| p99 {pct(c1,0.99):.1f}/{pct(c0,0.99):.1f}={p99_r:.2f} "
            f"| max {max(c1):.1f}/{max(c0):.1f}={max_r:.2f} | {'PASS' if hit else 'fail'} |"
        )

    md = [
        f"# {args.case} tip/p99/max acceptance (OUTLINE 1C intermittent)",
        "",
        f"- window measure [{args.lo},{args.hi}]",
        f"- pass if victim rank{args.victim_rank}: median≥{args.min_median_ratio} OR p99≥{args.min_p99_ratio} OR max≥{args.min_max_ratio}",
        f"- verdict: **{'BITE_OK' if ok else 'injection_ineffective'}**",
        "",
        "| rank | median | p99 | max | hit |",
        "|---|---|---|---|---|",
        *rows,
        "",
    ]
    text = "\n".join(md)
    print(text)
    if args.write_md:
        Path(args.write_md).write_text(text)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
