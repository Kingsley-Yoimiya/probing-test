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


def load_flag_totals(dump_dir: str) -> tuple[int, int, int]:
    """从 XPUTimer 自己的 .prom 汇总它**自主**报的 hang/slow flags 与事件数。

    这些是 XPUTimer 论文里真正的自主检出信号（hang poller + SLOW 阈值），跨所有
    rank 的 .prom 求和。与「跨-run 中位比」不同——后者要外部健康基线才成立。
    返回 (hang_flags, slow_flags, coll_events)。
    """
    hang = slow = events = 0
    for p in sorted(glob.glob(os.path.join(dump_dir, "ascend_metrics.*.prom"))):
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                txt = f.read()
        except OSError:
            continue
        for line in txt.splitlines():
            parts = line.split()
            if len(parts) != 2:
                continue
            key, val = parts[0], parts[1]
            try:
                v = int(float(val))
            except ValueError:
                continue
            if key == "xpu_timer_ascend_hang_flags_total":
                hang += v
            elif key == "xpu_timer_ascend_slow_flags_total":
                slow += v
            elif key == "xpu_timer_ascend_coll_events_total":
                events += v
    return hang, slow, events


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
    # 跨-run 对照：C1/C0 中位比。这**不是** XPUTimer 自主检出——需外部健康基线 C0。
    contrast_ok = ratio == ratio and ratio >= args.accept_min_ratio

    # XPUTimer **自主**信号：它自己 .prom 里的 hang/slow flags（无需外部基线）
    hang0, slow0, ev0 = load_flag_totals(args.c0)
    hang1, slow1, ev1 = load_flag_totals(args.c1)
    autonomous_flag = (hang1 + slow1) > 0  # C1 上 XPUTimer 自己报了 hang/slow 才算自主检出

    lines = [
        "# XPUTimer S4 · P3-EXT-A Loud contrast",
        "",
        f"- case_ref: `20260724_231918-yjr-as-c-p3exta-loud` (C1/C0 step_ms=1.97)",
        f"- dose: stress-ng `--cpu $(nproc) --cpu-load 90`；窗对齐 Case [100,300]",
        f"- detect_mode: **cross_run_contrast**（C1/C0 中位比≥{args.accept_min_ratio}；"
        "需外部健康基线 C0，非 run 内自主判据）",
        f"- metric: jsonl `dur_us` of `{name}` (host-wall around Hccl*)",
        "",
        "## A) XPUTimer 自主信号（它自己 .prom 的 hang/slow flags；无需外部基线）",
        "",
        f"| arm | coll_events | hang_flags | slow_flags |",
        f"|-----|-----------:|-----------:|-----------:|",
        f"| C0  | {ev0} | {hang0} | {slow0} |",
        f"| C1  | {ev1} | {hang1} | {slow1} |",
        "",
        f"**autonomous_flag (C1 hang+slow>0) = {autonomous_flag}** "
        f"（S4 配置 SLOW_REPORT_US=0 关、HANG_TIMEOUT_MS=60000；host CPU 抢占够不到 hang 阈）",
        "",
        "## B) cross-run 中位对照（需外部健康基线 C0，非自主）",
        "",
        f"| arm | n | median dur_us | ≥1.5×C0med（噪声诊断，非判据） |",
        f"|-----|--:|-------------:|------------------------------:|",
        f"| C0  | {len(c0)} | {m0:.1f} | {slow_c0} |",
        f"| C1  | {len(c1)} | {m1:.1f} | {slow_c1} |",
        "",
        f"**C1/C0 coll ratio = {ratio:.3f}** → "
        f"{'PASS' if contrast_ok else 'FAIL'} (thr {args.accept_min_ratio})",
        "",
        f"> ⚠️ `≥1.5×C0med` 计数仅作噪声诊断：C0 健康线自身就有 {slow_c0} 个，"
        "说明该线在集合通信 host-wall 上大面积误报，**不作判据**。",
        "",
        "## Verdict",
        "",
        f"- **autonomous_detect**: {'YES' if autonomous_flag else 'NO'} "
        f"(XPUTimer 自己的 hang/slow flags)",
        f"- **cross_run_contrast**: {'PASS' if contrast_ok else 'FAIL'} "
        f"(C1/C0={ratio:.3f}；需外部基线)",
        "",
        "Note: P3-EXT-A 是 host CPU 抢占；XPUTimer 天花板多为 D0–D1 信号。"
        "它自主检出=0（hang/slow 未触发）；集合通信 host-wall 也未随 Loud 抬升。"
        "能力范围内如实记「无咬合」，不声称 D4 RCA。",
        "",
    ]
    text = "\n".join(lines)
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(text)
    meta = {
        "metric_name": name,
        "median_c0": m0,
        "median_c1": m1,
        "coll_ratio": ratio,
        "cross_run_contrast_pass": contrast_ok,
        "detect_mode": "cross_run_contrast",
        "autonomous_flag": autonomous_flag,
        "hang_flags": {"c0": hang0, "c1": hang1},
        "slow_flags": {"c0": slow0, "c1": slow1},
        "coll_events": {"c0": ev0, "c1": ev1},
        "noise_diag_slow_ge_1p5xc0": {"c0": slow_c0, "c1": slow_c1},
    }
    with open(os.path.join(os.path.dirname(args.out) or ".", "S4_SUMMARY.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(text)
    return 0 if (autonomous_flag or contrast_ok) else 2


if __name__ == "__main__":
    sys.exit(main())
