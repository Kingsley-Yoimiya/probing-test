#!/usr/bin/env python3
"""P2-SW-C comm_ms primary dose_check appendix for XPUTimer contrast.

Probing gold: C1/C0_comm≈49.86; step≈5.06 (both strong; primary still comm).
Augments CONTRAST_SUMMARY.json + CONTRAST_VERDICT.md; does not change detect_ok
(XPUTimer rule path stays autonomous OR cross-run coll).
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import statistics
import sys
from pathlib import Path


def load_metric(ranks_dir: str, key: str, lo: int, hi: int) -> list[float]:
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
                step = o.get("step", o.get("global_step"))
                if step is None or key not in o:
                    continue
                try:
                    s = int(step)
                    v = float(o[key])
                except (TypeError, ValueError):
                    continue
                if lo <= s < hi:
                    out.append(v)
    return out


def med(xs: list[float]) -> float:
    return float(statistics.median(xs)) if xs else float("nan")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ranks-c0", required=True)
    ap.add_argument("--ranks-c1", required=True)
    ap.add_argument("--window-start", type=int, default=100)
    ap.add_argument("--window-stop", type=int, default=300)
    ap.add_argument("--accept-min-ratio", type=float, default=1.15)
    ap.add_argument("--summary", required=True)
    ap.add_argument("--verdict", required=True)
    args = ap.parse_args()

    lo, hi = args.window_start, args.window_stop
    c0_comm = load_metric(args.ranks_c0, "comm_ms", lo, hi)
    c1_comm = load_metric(args.ranks_c1, "comm_ms", lo, hi)
    c0_step = load_metric(args.ranks_c0, "step_ms", lo, hi)
    c1_step = load_metric(args.ranks_c1, "step_ms", lo, hi)

    m0c, m1c = med(c0_comm), med(c1_comm)
    m0s, m1s = med(c0_step), med(c1_step)
    comm_r = (m1c / m0c) if m0c == m0c and m0c > 0 else float("nan")
    step_r = (m1s / m0s) if m0s == m0s and m0s > 0 else float("nan")
    comm_pass = comm_r == comm_r and comm_r >= args.accept_min_ratio
    step_pass = step_r == step_r and step_r >= args.accept_min_ratio
    # Primary = comm; step alone does not fail dose when comm PASS.
    dose_pass = bool(comm_pass)
    preferred = "comm_ms" if comm_pass else ("step_ms" if step_pass else "comm_ms_fail")

    block = {
        "primary": "comm_ms",
        "comm_ms_median_c0": m0c,
        "comm_ms_median_c1": m1c,
        "comm_ms_ratio": comm_r,
        "comm_ms_pass": bool(comm_pass),
        "step_ms_median_c0": m0s,
        "step_ms_median_c1": m1s,
        "step_ms_ratio": step_r,
        "step_ms_pass": bool(step_pass),
        "pass": dose_pass,
        "preferred": preferred,
        "n_comm_c0": len(c0_comm),
        "n_comm_c1": len(c1_comm),
        "window": [lo, hi],
        "note": "P2-SW-C 主证 comm_ms；金标 C1/C0_comm≈49.86；step≈5.06 旁证不单独 FAIL",
        "accept_min_ratio": args.accept_min_ratio,
    }

    sp = Path(args.summary)
    meta = json.loads(sp.read_text(encoding="utf-8"))
    # Preserve original step-only dose_check; overlay combined + primary.
    step_only = meta.get("dose_check") or {}
    meta["dose_check_step_only"] = step_only
    meta["dose_check_comm"] = block
    meta["dose_check"] = {
        "primary": "comm_ms",
        "comm_ms_median_c0": m0c,
        "comm_ms_median_c1": m1c,
        "comm_ms_ratio": comm_r,
        "step_ms_median_c0": m0s,
        "step_ms_median_c1": m1s,
        "step_ms_ratio": step_r,
        "pass": dose_pass,
        "n_c0": len(c0_comm),
        "n_c1": len(c1_comm),
        "window": [lo, hi],
        "note": block["note"],
    }
    meta["dose_check_combined"] = {
        "comm_pass": bool(comm_pass),
        "step_pass": bool(step_pass),
        "pass": dose_pass,
        "preferred": preferred,
    }
    sp.write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    appendix = [
        "",
        "## C2) dose_check 主证=comm_ms（P2-SW-C；step 旁证不单独 FAIL）",
        "",
        f"- window: [{lo}, {hi})",
        f"- C0 median comm_ms: {m0c:.3f} (n={len(c0_comm)})",
        f"- C1 median comm_ms: {m1c:.3f} (n={len(c1_comm)})",
        f"- **C1/C0 comm_ms = {comm_r:.3f}** → "
        f"{'PASS' if comm_pass else 'FAIL'} (thr {args.accept_min_ratio})",
        f"- C1/C0 step_ms = {step_r:.3f} "
        f"（旁证；金标≈5.06；本对照 step "
        f"{'PASS' if step_pass else 'WEAK/FAIL'}）",
        f"- Probing gold C1/C0_comm≈49.86；dose_check 主证 → "
        f"{'PASS' if dose_pass else 'FAIL'}",
        "",
    ]
    vp = Path(args.verdict)
    text = vp.read_text(encoding="utf-8")
    if "## C2) dose_check 主证=comm_ms" not in text:
        if "## Verdict" in text:
            text = text.replace("## Verdict", "\n".join(appendix) + "## Verdict", 1)
        else:
            text = text.rstrip() + "\n" + "\n".join(appendix)
        # Soften Verdict dose_check line to reflect primary=comm
        old = None
        for line in text.splitlines():
            if line.startswith("- **dose_check**:"):
                old = line
                break
        if old:
            new = (
                f"- **dose_check**: {'PASS' if dose_pass else 'FAIL/NA'} "
                f"(comm_ms C1/C0={comm_r:.3f} 主证；step_ms={step_r:.3f} 旁证)"
            )
            text = text.replace(old, new, 1)
        vp.write_text(text, encoding="utf-8")

    print(json.dumps(block, indent=2, ensure_ascii=False))
    return 0 if dose_pass else 2


if __name__ == "__main__":
    sys.exit(main())
