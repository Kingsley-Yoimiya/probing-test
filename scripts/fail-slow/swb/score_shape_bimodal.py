#!/usr/bin/env python3
"""score_shape_bimodal.py — P1-SW-B 离线 scorer（shape_seq + compute_ms 双峰）。

读 rank jsonl，检查:
  - shape_seq 是否在注入窗出现罕见值（相对 base）
  - compute_ms 是否呈双峰（两个众数簇）

用法:
  python3 score_shape_bimodal.py --result-root results/muxi-h3c/<run> --case P1-SW-B
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import Counter
from pathlib import Path


def find_victim_jsonl(case_root: Path, cfg: str, victim_local: int = 7) -> Path | None:
    """优先找 node0 victim local_rank；退化到任意含 shape_seq 的 rank。"""
    # rank = node_rank * nproc + local；默认 nproc=8 → victim global = 7
    prefer = sorted(case_root.glob(f"by_pod/*/round_1/{cfg}/ranks/rank_0007.jsonl"))
    if prefer:
        return prefer[0]
    for p in sorted(case_root.glob(f"by_pod/*/round_1/{cfg}/ranks/rank_*.jsonl")):
        return p
    _ = victim_local
    return None


def load_rows(path: Path, lo: int, hi: int) -> list[dict]:
    rows = []
    with path.open() as f:
        for line in f:
            if not line.strip():
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            if lo <= int(o.get("step", -1)) <= hi:
                rows.append(o)
    return rows


def bimodality_hint(values: list[float], gap_ratio: float = 1.2) -> dict:
    """极简双峰：按中位分成低/高两簇，看高簇中位 / 低簇中位。"""
    if len(values) < 10:
        return {"bimodal": False, "reason": "too_few"}
    med = statistics.median(values)
    low = [v for v in values if v <= med]
    high = [v for v in values if v > med]
    if not low or not high:
        return {"bimodal": False, "reason": "single_side"}
    ml, mh = statistics.median(low), statistics.median(high)
    ratio = mh / ml if ml > 0 else float("inf")
    return {
        "bimodal": ratio >= gap_ratio,
        "low_med": round(ml, 3),
        "high_med": round(mh, 3),
        "high_low_ratio": round(ratio, 3),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--result-root", required=True)
    ap.add_argument("--case", default="P1-SW-B")
    ap.add_argument("--cfg", default="C1_inject_none")
    ap.add_argument("--lo", type=int, default=100, help="GT/稀有 shape 统计窗")
    ap.add_argument("--hi", type=int, default=300)
    ap.add_argument("--bi-lo", type=int, default=0, help="双峰检测窗（默认含窗外 base）")
    ap.add_argument("--bi-hi", type=int, default=10**9)
    ap.add_argument("--base-seq", type=int, default=1024)
    ap.add_argument("--rare-seq", type=int, default=1536)
    ap.add_argument("--victim-local", type=int, default=7)
    ap.add_argument("--write-json", default="")
    args = ap.parse_args()

    case_root = Path(args.result_root) / args.case
    path = find_victim_jsonl(case_root, args.cfg, args.victim_local)
    if not path:
        print(f"no jsonl under {case_root}", file=sys.stderr)
        return 2

    rows_win = load_rows(path, args.lo, args.hi)
    rows_bi = load_rows(path, args.bi_lo, args.bi_hi)
    shapes = [int(r["shape_seq"]) for r in rows_win if "shape_seq" in r]
    computes = [float(r["compute_ms"]) for r in rows_bi if "compute_ms" in r]
    shape_counts = Counter(shapes)

    rare_frac = (
        sum(1 for s in shapes if s == args.rare_seq) / len(shapes) if shapes else 0.0
    )
    has_rare = args.rare_seq in shape_counts
    has_base = args.base_seq in shape_counts or any(s != args.rare_seq for s in shapes)
    # 也看全序列是否同时出现 base+rare
    all_shapes = {int(r["shape_seq"]) for r in rows_bi if "shape_seq" in r}
    has_shape_mix = args.rare_seq in all_shapes and (
        args.base_seq in all_shapes or len(all_shapes) >= 2
    )
    bi = bimodality_hint(computes)

    if not shapes:
        d_hint = "D0_no_shape_seq"
    elif has_rare and bi.get("bimodal"):
        d_hint = "D3_shape_and_compute_bimodal"
    elif has_rare and (has_base or has_shape_mix):
        d_hint = "D2_shape_bimodal"
    elif has_rare:
        d_hint = "D1_rare_shape_only"
    else:
        d_hint = "D0_no_rare_shape"

    out = {
        "case": args.case,
        "cfg": args.cfg,
        "path": str(path),
        "n_steps_window": len(rows_win),
        "shape_counts_window": dict(shape_counts),
        "rare_seq": args.rare_seq,
        "rare_frac_in_window": round(rare_frac, 4),
        "shape_values_all": sorted(all_shapes),
        "compute_bimodality": bi,
        "d_hint": d_hint,
    }
    text = json.dumps(out, indent=2, ensure_ascii=False)
    print(text)
    if args.write_json:
        Path(args.write_json).write_text(text + "\n")
    return 0 if d_hint.startswith("D") and not d_hint.startswith("D0") else 1


if __name__ == "__main__":
    raise SystemExit(main())
