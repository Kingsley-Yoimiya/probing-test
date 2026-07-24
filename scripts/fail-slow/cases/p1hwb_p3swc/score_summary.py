#!/usr/bin/env python3
"""隔离判分入口：合并 score_cases.py 到离线评分（不改共享 score_dlevel_*.py）。"""
from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from score_cases import CASES  # noqa: E402

# 可选复用共享离线逻辑
SHARED = HERE.parents[1]
sys.path.insert(0, str(SHARED))


def median_step(root: Path, cfg: str, lo=150, hi=350) -> float | None:
    files = list(root.glob(f"**/round_*/{cfg}/ranks/rank_*.jsonl"))
    vals = []
    for f in files:
        for line in f.open():
            o = json.loads(line)
            if lo <= o["step"] < hi:
                vals.append(o["step_ms"])
    return statistics.median(vals) if vals else None


def main():
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} <result_root> <CASE_ID>", file=sys.stderr)
        sys.exit(2)
    result_root = Path(sys.argv[1])
    case = sys.argv[2]
    meta = CASES.get(case)
    if not meta:
        print(f"unknown case {case}", file=sys.stderr)
        sys.exit(2)
    root = result_root / case
    c0 = median_step(root, "C0_baseline")
    c1 = median_step(root, "C1_inject_none")
    c2 = median_step(root, "C2_probing")
    ratio = (c1 / c0) if (c0 and c1) else None
    out = {
        "case": case,
        "meta": meta,
        "C0_median_step_ms": c0,
        "C1_median_step_ms": c1,
        "C2_median_step_ms": c2,
        "C1_C0": round(ratio, 3) if ratio else None,
        "notes": "D-level 全量请再跑共享 score_dlevel_sql.py（登记本战役 score_cases）",
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))
    md = result_root / f"score_summary_{case}.md"
    md.write_text(
        f"# Score summary {case}\n\n"
        f"- grid={meta['grid']} kind={meta['kind']} outline={meta.get('outline')}\n"
        f"- C1/C0={out['C1_C0']}\n"
        f"- victim_rank={meta['victim_rank']}\n",
        encoding="utf-8",
    )
    print(f"wrote {md}")


if __name__ == "__main__":
    main()
