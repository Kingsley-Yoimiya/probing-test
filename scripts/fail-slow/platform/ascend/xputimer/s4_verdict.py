#!/usr/bin/env python3
"""S4 verdict: compare XPUTimer coll host-wall C0 vs C1 under P3-EXT-A Loud dose.

Autonomous rule (no INJECT_STALL / no fixed SLOW us):
  ratio = median(C1 dur_us) / median(C0 dur_us) for HcclAllReduce (fallback AllGather)
  PASS if ratio >= accept_min_ratio (default 1.3, same Loud bite as Case).

Also counts events with dur_us >= 1.5 * C0_median as rule-SLOW.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import statistics
import sys


def load_durs(dump_dir: str, name: str) -> list[float]:
    out = []
    for p in sorted(glob.glob(os.path.join(dump_dir, "ascend_trace.*.jsonl"))):
        with open(p, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if o.get("name") == name and "dur_us" in o:
                    out.append(float(o["dur_us"]))
    return out


def med(xs: list[float]) -> float:
    return float(statistics.median(xs)) if xs else float("nan")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--c0", required=True)
    ap.add_argument("--c1", required=True)
    ap.add_argument("--accept-min-ratio", type=float, default=1.3)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    name = "HcclAllReduce"
    c0 = load_durs(args.c0, name)
    c1 = load_durs(args.c1, name)
    if len(c0) < 5 or len(c1) < 5:
        name = "HcclAllGather"
        c0 = load_durs(args.c0, name)
        c1 = load_durs(args.c1, name)

    m0, m1 = med(c0), med(c1)
    ratio = (m1 / m0) if m0 and m0 == m0 and m0 > 0 else float("nan")
    thr = 1.5 * m0 if m0 == m0 else float("nan")
    slow_c0 = sum(1 for x in c0 if x >= thr) if thr == thr else 0
    slow_c1 = sum(1 for x in c1 if x >= thr) if thr == thr else 0
    ok = ratio == ratio and ratio >= args.accept_min_ratio

    lines = [
        "# XPUTimer S4 · P3-EXT-A Loud contrast",
        "",
        f"- case_ref: `20260724_231918-yjr-as-c-p3exta-loud` (C1/C0 step_ms=1.97)",
        f"- dose: stress-ng `--cpu $(nproc) --cpu-load 90`；窗对齐 Case [100,300]",
        f"- detect_mode: **autonomous**（C0 中位 ×1.5 作 SLOW 线；咬合比≥{args.accept_min_ratio}）",
        f"- metric: jsonl `dur_us` of `{name}` (host-wall around Hccl*)",
        "",
        f"| arm | n | median dur_us | rule-SLOW (≥1.5×C0 med) |",
        f"|-----|--:|-------------:|------------------------:|",
        f"| C0  | {len(c0)} | {m0:.1f} | {slow_c0} |",
        f"| C1  | {len(c1)} | {m1:.1f} | {slow_c1} |",
        "",
        f"**C1/C0 coll ratio = {ratio:.3f}** → "
        f"{'PASS' if ok else 'FAIL'} (thr {args.accept_min_ratio})",
        "",
        "Note: P3-EXT-A 是 host CPU 抢占；XPUTimer 天花板多为 D0–D1 信号。"
        "本对照看集合通信 host-wall 是否随 Loud 抬升，不声称 D4 RCA。",
        "",
    ]
    text = "\n".join(lines)
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(text)
    print(text)
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
