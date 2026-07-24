#!/usr/bin/env python3
"""score_comm_phase.py — P2-SW-B 离线 scorer（comm_ms / step_ms）。

两种模式:
  detect — 不知道 GT 注入窗：对 C1 rank0 的 comm_ms 做简单变点检测，输出 D 级提示
  score  — detect 之后可用 GT 窗算 IoU（验收/复盘）

用法:
  python3 score_comm_phase.py --result-root results/muxi-h3c/<run> --case P2-SW-B --mode detect
  python3 score_comm_phase.py --result-root results/muxi-h3c/<run> --case P2-SW-B --mode score \\
      --gt-lo 100 --gt-hi 300
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path


def find_rank0(case_root: Path, cfg: str) -> Path | None:
    hits = sorted(case_root.glob(f"by_pod/*/round_1/{cfg}/ranks/rank_0000.jsonl"))
    return hits[0] if hits else None


def load_series(path: Path, key: str = "comm_ms") -> list[tuple[int, float]]:
    rows: list[tuple[int, float]] = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            if key not in o:
                continue
            rows.append((int(o["step"]), float(o[key])))
    rows.sort()
    return rows


def median_in(rows: list[tuple[int, float]], lo: int, hi: int) -> float | None:
    xs = [v for s, v in rows if lo <= s <= hi]
    return float(statistics.median(xs)) if xs else None


def iou(a0: int, a1: int, b0: int, b1: int) -> float:
    inter = max(0, min(a1, b1) - max(a0, b0) + 1)
    union = (a1 - a0 + 1) + (b1 - b0 + 1) - inter
    return inter / union if union else 0.0


def detect_changepoint(
    rows: list[tuple[int, float]],
    baseline_med: float,
    thr: float = 1.3,
    min_run: int = 5,
) -> tuple[int | None, int | None]:
    """返回 (onset, offset)：首次连续 min_run 步 >= thr*baseline，到恢复前最后一步。"""
    if not rows or baseline_med <= 0:
        return None, None
    onset = None
    run = 0
    last_hot = None
    for step, ms in rows:
        hot = ms >= thr * baseline_med
        if hot:
            run += 1
            last_hot = step
            if onset is None and run >= min_run:
                onset = step - min_run + 1
        else:
            if onset is not None:
                return onset, last_hot
            run = 0
    if onset is not None:
        return onset, last_hot
    return None, None


def d_hint(c0: float | None, c1: float | None, onset: int | None, iou_v: float | None) -> str:
    """粗糙 D 级提示（离线埋点，非 Probing SQL）。"""
    if c0 is None or c1 is None or c0 <= 0:
        return "D0_insufficient_data"
    ratio = c1 / c0
    if ratio < 1.1:
        return "D0_no_slowdown"
    if onset is None:
        return "D1_slowdown_no_onset"
    if iou_v is not None and iou_v >= 0.5:
        return "D2_onset_aligned" if ratio < 1.5 else "D3_comm_phase_strong"
    if iou_v is not None:
        return "D1_onset_misaligned"
    return "D2_onset_detected"  # detect 模式无 GT


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--result-root", required=True)
    ap.add_argument("--case", default="P2-SW-B")
    ap.add_argument("--mode", choices=["detect", "score"], default="detect")
    ap.add_argument("--lo", type=int, default=100, help="对齐比较窗（score 用；detect 也做 C0/C1 中位）")
    ap.add_argument("--hi", type=int, default=300)
    ap.add_argument("--gt-lo", type=int, default=100)
    ap.add_argument("--gt-hi", type=int, default=300)
    ap.add_argument("--thr", type=float, default=1.3)
    ap.add_argument("--metric", default="comm_ms", choices=["comm_ms", "step_ms"])
    ap.add_argument("--write-json", default="")
    args = ap.parse_args()

    case_root = Path(args.result_root) / args.case
    p0 = find_rank0(case_root, "C0_baseline")
    p1 = find_rank0(case_root, "C1_inject_none")
    if not p0 or not p1:
        print(f"missing rank0 jsonl under {case_root}", file=sys.stderr)
        return 2

    s0 = load_series(p0, args.metric)
    s1 = load_series(p1, args.metric)
    c0 = median_in(s0, args.lo, args.hi)
    c1 = median_in(s1, args.lo, args.hi)
    # detect：用 C0 全窗中位作 baseline，在 C1 全序列上找变点（不读 GT）
    base = median_in(s0, 0, 10**9) or c0
    onset, offset = detect_changepoint(s1, base or 0.0, thr=args.thr)

    out: dict = {
        "case": args.case,
        "mode": args.mode,
        "metric": args.metric,
        "c0_median": c0,
        "c1_median": c1,
        "ratio_c1_c0": (c1 / c0) if (c0 and c1 and c0 > 0) else None,
        "detect_onset": onset,
        "detect_offset": offset,
    }

    iou_v = None
    if args.mode == "score" and onset is not None and offset is not None:
        iou_v = iou(onset, offset, args.gt_lo, args.gt_hi)
        out["gt_window"] = [args.gt_lo, args.gt_hi]
        out["iou"] = round(iou_v, 4)

    out["d_hint"] = d_hint(c0, c1, onset, iou_v if args.mode == "score" else None)

    text = json.dumps(out, indent=2, ensure_ascii=False)
    print(text)
    if args.write_json:
        Path(args.write_json).write_text(text + "\n")
    return 0 if out["d_hint"] not in ("D0_insufficient_data", "D0_no_slowdown") else 1


if __name__ == "__main__":
    raise SystemExit(main())
