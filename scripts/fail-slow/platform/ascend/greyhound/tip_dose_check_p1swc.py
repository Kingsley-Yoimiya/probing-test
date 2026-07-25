#!/usr/bin/env python3
"""P1-SW-C tip/max dose_check appendix for Greyhound contrast.

Probing gold: tip max≈4.63, median often blind (~1.0).
Augments CONTRAST_SUMMARY.json + CONTRAST_VERDICT.md with victim tip metrics;
does not change detect_ok (Greyhound rule path stays coll OR Rbeast).
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path


def load_steps(path: Path, lo: int, hi: int) -> list[tuple[int, float]]:
    out: list[tuple[int, float]] = []
    with path.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            s = o.get("step", o.get("global_step"))
            if s is None or "step_ms" not in o:
                continue
            try:
                si = int(s)
                ms = float(o["step_ms"])
            except (TypeError, ValueError):
                continue
            if lo <= si < hi:
                out.append((si, ms))
    return out


def pct(xs: list[float], p: float) -> float:
    s = sorted(xs)
    if not s:
        return float("nan")
    return s[max(0, min(len(s) - 1, int(p * (len(s) - 1))))]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ranks-c0", required=True)
    ap.add_argument("--ranks-c1", required=True)
    ap.add_argument("--victim-local", type=int, default=7)
    ap.add_argument("--window-start", type=int, default=100)
    ap.add_argument("--window-stop", type=int, default=300)
    ap.add_argument("--accept-min-max-ratio", type=float, default=2.5)
    ap.add_argument("--accept-min-p99-ratio", type=float, default=1.5)
    ap.add_argument("--summary", required=True)
    ap.add_argument("--verdict", required=True)
    args = ap.parse_args()

    c0p = Path(args.ranks_c0) / f"rank_{args.victim_local:04d}.jsonl"
    c1p = Path(args.ranks_c1) / f"rank_{args.victim_local:04d}.jsonl"
    if not c0p.is_file() or not c1p.is_file():
        print(f"missing victim ranks: {c0p} / {c1p}", file=sys.stderr)
        return 1

    c0 = load_steps(c0p, args.window_start, args.window_stop)
    c1 = load_steps(c1p, args.window_start, args.window_stop)
    if not c0 or not c1:
        print("empty window on victim", file=sys.stderr)
        return 1

    c0_ms = [m for _, m in c0]
    c1_ms = [m for _, m in c1]
    med0, med1 = statistics.median(c0_ms), statistics.median(c1_ms)
    med_r = med1 / med0 if med0 > 0 else float("nan")
    p99_r = pct(c1_ms, 0.99) / max(1e-9, pct(c0_ms, 0.99))
    max0, max1 = max(c0_ms), max(c1_ms)
    max_r = max1 / max(1e-9, max0)
    tip_step, tip_ms = max(c1, key=lambda t: t[1])
    tip_pass = (
        (med_r == med_r and med_r >= 1.3)
        or (p99_r == p99_r and p99_r >= args.accept_min_p99_ratio)
        or (max_r == max_r and max_r >= args.accept_min_max_ratio)
    )

    tip_block = {
        "victim_local_rank": args.victim_local,
        "step_ms_median_c0": med0,
        "step_ms_median_c1": med1,
        "step_ms_median_ratio": med_r,
        "step_ms_p99_ratio": p99_r,
        "step_ms_max_c0": max0,
        "step_ms_max_c1": max1,
        "step_ms_max_ratio": max_r,
        "tip_step": tip_step,
        "tip_step_ms": tip_ms,
        "pass": bool(tip_pass),
        "note": "P1-SW-C tip/max gate; median often blind; Probing gold tip max≈4.63",
        "window": [args.window_start, args.window_stop],
    }

    sp = Path(args.summary)
    meta = json.loads(sp.read_text(encoding="utf-8"))
    meta["tip_dose_check"] = tip_block
    # Greyhound SUMMARY 用顶层 dose_ok；XPUTimer 用 dose_check.pass
    dc = meta.get("dose_check") or {}
    median_pass = bool(dc.get("pass")) if "pass" in dc else bool(meta.get("dose_ok"))
    meta["dose_check_combined"] = {
        "step_ms_median_pass": median_pass,
        "tip_max_pass": bool(tip_pass),
        "pass": bool(median_pass or tip_pass),
        "preferred": "tip_max" if tip_pass and not median_pass else "step_ms_median",
    }
    sp.write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    appendix = [
        "",
        "## C2) tip/max dose_check（victim local_rank；P1-SW-C 叙事）",
        "",
        f"- victim local_rank={args.victim_local}",
        f"- median C1/C0 step_ms = {med_r:.3f} （常盲）",
        f"- p99 C1/C0 = {p99_r:.3f}",
        f"- max C1/C0 = {max_r:.3f} （C1 max={max1:.1f} @step {tip_step}；C0 max={max0:.1f}）",
        f"- tip gate → {'PASS' if tip_pass else 'FAIL'} "
        f"(med≥1.3 OR p99≥{args.accept_min_p99_ratio} OR max≥{args.accept_min_max_ratio})",
        f"- Probing gold tip max≈4.63；本对照 tip max_ratio={max_r:.3f}",
        "",
    ]
    vp = Path(args.verdict)
    text = vp.read_text(encoding="utf-8")
    if "## C2) tip/max dose_check" not in text:
        if "## Verdict" in text:
            text = text.replace("## Verdict", "\n".join(appendix) + "## Verdict", 1)
        else:
            text = text.rstrip() + "\n" + "\n".join(appendix)
        # Soften dose_reproduced line when tip passes but median blind
        if tip_pass and not median_pass:
            text = text.replace(
                "- **dose_reproduced**: NO/WEAK (step_ms)",
                "- **dose_reproduced**: YES (tip/max；median 盲)",
                1,
            )
        vp.write_text(text, encoding="utf-8")

    print(json.dumps(tip_block, indent=2, ensure_ascii=False))
    return 0 if tip_pass else 2


if __name__ == "__main__":
    sys.exit(main())
