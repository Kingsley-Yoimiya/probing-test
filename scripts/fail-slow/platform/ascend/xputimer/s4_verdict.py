#!/usr/bin/env python3
"""XPUTimer contrast verdict: split autonomous prom flags vs cross-run median ratio.

Autonomous (no external baseline needed):
  XPUTimer's own ascend_metrics.*.prom hang_flags / slow_flags on C1.

Cross-run (needs healthy C0 baseline; NOT autonomous):
  ratio = median(C1 dur_us) / median(C0 dur_us) for HcclAllReduce (fallback AllGather)
  PASS if ratio >= accept_min_ratio.

Never label detect_mode=autonomous when only the cross-run ratio fires.
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
    """Sum XPUTimer's own hang/slow flags + coll events across .prom files.

    These are the tool's autonomous detect signals (hang poller + SLOW threshold).
    Distinct from cross-run median ratio which needs an external healthy C0.
    Returns (hang_flags, slow_flags, coll_events).
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


def load_step_ms_window(
    ranks_dir: str, start: int = 100, stop: int = 300
) -> list[float]:
    """Collect step_ms in measure window from rank_*.jsonl (dose_check only)."""
    out: list[float] = []
    if not ranks_dir or not os.path.isdir(ranks_dir):
        return out
    for p in sorted(glob.glob(os.path.join(ranks_dir, "rank_*.jsonl"))):
        with open(p, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                except json.JSONDecodeError:
                    continue
                step = o.get("step")
                if step is None:
                    step = o.get("global_step")
                if step is None:
                    continue
                try:
                    s = int(step)
                except (TypeError, ValueError):
                    continue
                if start <= s < stop and "step_ms" in o:
                    try:
                        out.append(float(o["step_ms"]))
                    except (TypeError, ValueError):
                        pass
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--c0", required=True, help="C0 xputimer dump dir")
    ap.add_argument("--c1", required=True, help="C1 xputimer dump dir")
    ap.add_argument("--ranks-c0", default="", help="C0 ranks/ for step_ms dose_check")
    ap.add_argument("--ranks-c1", default="", help="C1 ranks/ for step_ms dose_check")
    ap.add_argument("--case-id", default="P3-EXT-A")
    ap.add_argument("--case-ref", default="")
    ap.add_argument("--dose", default="loud", help="loud|quiet|masked (SUMMARY field only)")
    ap.add_argument("--dose-desc", default="")
    ap.add_argument("--accept-min-ratio", type=float, default=1.3)
    ap.add_argument("--window-start", type=int, default=100)
    ap.add_argument("--window-stop", type=int, default=300)
    ap.add_argument("--out", required=True, help="VERDICT markdown path")
    ap.add_argument(
        "--summary",
        default="",
        help="SUMMARY json path (default: sibling CONTRAST_SUMMARY.json or S4_SUMMARY.json)",
    )
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
    # Cross-run: C1/C0 median. NOT XPUTimer autonomous — needs external healthy C0.
    contrast_ok = ratio == ratio and ratio >= args.accept_min_ratio

    # XPUTimer autonomous: its own .prom hang/slow flags (no external baseline)
    hang0, slow0, ev0 = load_flag_totals(args.c0)
    hang1, slow1, ev1 = load_flag_totals(args.c1)
    autonomous_flag = (hang1 + slow1) > 0

    # detect_mode: never call it "autonomous" when only cross-run fires
    if autonomous_flag and contrast_ok:
        detect_mode = "autonomous+cross_run"
    elif autonomous_flag:
        detect_mode = "autonomous"
    else:
        detect_mode = "cross_run_contrast"

    # dose_check via step_ms (not XPUTimer detect rule)
    sm0 = load_step_ms_window(args.ranks_c0, args.window_start, args.window_stop)
    sm1 = load_step_ms_window(args.ranks_c1, args.window_start, args.window_stop)
    med_sm0, med_sm1 = med(sm0), med(sm1)
    step_ratio = (
        (med_sm1 / med_sm0)
        if med_sm0 and med_sm0 == med_sm0 and med_sm0 > 0
        else float("nan")
    )
    dose_ok = step_ratio == step_ratio and step_ratio >= args.accept_min_ratio

    case_ref = args.case_ref or "(unset)"
    dose_desc = args.dose_desc or "(see manifest)"
    detect_ok = bool(autonomous_flag or contrast_ok)

    lines = [
        f"# XPUTimer contrast · {args.case_id} {args.dose}",
        "",
        f"- case_id: `{args.case_id}`",
        f"- case_ref: `{case_ref}`",
        f"- dose: `{args.dose}` — {dose_desc}",
        f"- detect_mode: **{detect_mode}** "
        f"（自主=prom hang/slow flags；跨-run=C1/C0 中位比≥{args.accept_min_ratio}，需外部健康基线 C0）",
        f"- metric: jsonl `dur_us` of `{name}` (host-wall around Hccl*)",
        "",
        "## A) XPUTimer 自主信号（.prom hang/slow flags；无需外部基线）",
        "",
        "| arm | coll_events | hang_flags | slow_flags |",
        "|-----|-----------:|-----------:|-----------:|",
        f"| C0  | {ev0} | {hang0} | {slow0} |",
        f"| C1  | {ev1} | {hang1} | {slow1} |",
        "",
        f"**autonomous_flag (C1 hang+slow>0) = {autonomous_flag}** "
        f"（SLOW_REPORT_US=0 关、HANG_TIMEOUT_MS=60000；未开 oracle INJECT_STALL）",
        "",
        "## B) cross-run 中位对照（需外部健康基线 C0，非自主）",
        "",
        "| arm | n | median dur_us | ≥1.5×C0med（噪声诊断，非判据） |",
        "|-----|--:|-------------:|------------------------------:|",
        f"| C0  | {len(c0)} | {m0:.1f} | {slow_c0} |",
        f"| C1  | {len(c1)} | {m1:.1f} | {slow_c1} |",
        "",
        f"**C1/C0 coll ratio = {ratio:.3f}** → "
        f"{'PASS' if contrast_ok else 'FAIL'} (thr {args.accept_min_ratio})",
        "",
        f"> ⚠️ `≥1.5×C0med` 计数仅作噪声诊断：C0 健康线自身就有 {slow_c0} 个，"
        "说明该线在集合通信 host-wall 上可能大面积误报，**不作判据**。",
        "",
        "## C) dose_check（step_ms 窗内中位；非 XPUTimer 规则）",
        "",
        f"- window: [{args.window_start}, {args.window_stop})",
        f"- C0 median step_ms: {med_sm0:.3f} (n={len(sm0)})",
        f"- C1 median step_ms: {med_sm1:.3f} (n={len(sm1)})",
        f"- C1/C0 step_ms = {step_ratio:.3f} → "
        f"{'PASS' if dose_ok else 'FAIL/NA'} (thr {args.accept_min_ratio})",
        "",
        "## Verdict",
        "",
        f"- **autonomous_detect**: {'YES' if autonomous_flag else 'NO'} "
        f"(XPUTimer 自己的 hang/slow flags)",
        f"- **cross_run_contrast**: {'PASS' if contrast_ok else 'FAIL'} "
        f"(C1/C0={ratio:.3f}；需外部基线)",
        f"- **dose_check**: {'PASS' if dose_ok else 'FAIL/NA'} "
        f"(step_ms C1/C0={step_ratio:.3f})",
        f"- **detect_ok**: {str(detect_ok).lower()} "
        f"(autonomous OR cross_run；dose_check 单独记)",
        f"- **detect_mode**: `{detect_mode}`",
        "",
        "Note: 如实记能力边界；无咬合也是 DONE。不改对手阈值、不覆盖 Probing 分。",
        "",
    ]
    text = "\n".join(lines)
    out_dir = os.path.dirname(args.out) or "."
    os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(text)

    summary_path = args.summary
    if not summary_path:
        base = os.path.basename(args.out)
        if "CONTRAST" in base.upper():
            summary_path = os.path.join(out_dir, "CONTRAST_SUMMARY.json")
        else:
            summary_path = os.path.join(out_dir, "S4_SUMMARY.json")

    meta = {
        "case_id": args.case_id,
        "tool": "xputimer",
        "dose": args.dose,
        "case_ref": case_ref,
        "metric_name": name,
        "median_c0": m0,
        "median_c1": m1,
        "coll_ratio": ratio,
        "cross_run_contrast_pass": contrast_ok,
        "detect_mode": detect_mode,
        "autonomous_flag": autonomous_flag,
        "autonomous_detect": autonomous_flag,
        "hang_flags": {"c0": hang0, "c1": hang1},
        "slow_flags": {"c0": slow0, "c1": slow1},
        "coll_events": {"c0": ev0, "c1": ev1},
        "noise_diag_slow_ge_1p5xc0": {"c0": slow_c0, "c1": slow_c1},
        "dose_check": {
            "step_ms_median_c0": med_sm0,
            "step_ms_median_c1": med_sm1,
            "step_ms_ratio": step_ratio,
            "pass": dose_ok,
            "n_c0": len(sm0),
            "n_c1": len(sm1),
            "window": [args.window_start, args.window_stop],
        },
        "accept_min_ratio": args.accept_min_ratio,
        "detect_ok": detect_ok,
    }
    with open(summary_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(text)
    return 0 if detect_ok else 2


if __name__ == "__main__":
    sys.exit(main())
