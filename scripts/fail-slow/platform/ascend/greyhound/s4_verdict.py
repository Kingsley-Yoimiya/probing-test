#!/usr/bin/env python3
"""Greyhound S4 verdict · P3-EXT-A Loud 同剂量对照.

两轴分开记（不把 Case step_ms 答案焊进 Greyhound 判据）:
  A) autonomous_coll: C1/C0 median HcclAllReduce dur_us（collect-min JSONL）
  B) autonomous_rbeast: 对 C1 collect 跑 find_period+find_performance_drop（允许无变点）
  C) dose_check (oracle-aligned): rank jsonl step_ms C1/C0（验证剂量；非 Greyhound 规则）
  D) oracle_window: 注入窗 [inject_start, inject_stop] 仅作对照标注

detect_ok=yes 若 A 咬合≥1.3 或 B 检出变点；否则如实记无咬合（仍可 S4_DETECT）。
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import statistics
import sys
from pathlib import Path


def load_coll_durs(jsonl: str) -> list[float]:
    out = []
    if not os.path.isfile(jsonl):
        return out
    with open(jsonl, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            if o.get("op") == "AllReduce" and "dur_us" in o:
                out.append(float(o["dur_us"]))
    return out


def load_step_ms(ranks_dir: str, rank: int = 0) -> list[tuple[int, float]]:
    paths = sorted(glob.glob(os.path.join(ranks_dir, f"rank_{rank:04d}.jsonl")))
    if not paths:
        paths = sorted(glob.glob(os.path.join(ranks_dir, "rank_*.jsonl")))[:1]
    rows = []
    for p in paths:
        with open(p, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if "step" in o and "step_ms" in o:
                    rows.append((int(o["step"]), float(o["step_ms"])))
    rows.sort()
    return rows


def med(xs: list[float]) -> float:
    return float(statistics.median(xs)) if xs else float("nan")


def window_med(steps: list[tuple[int, float]], lo: int, hi: int) -> float:
    xs = [v for s, v in steps if lo <= s <= hi]
    return med(xs)


def try_rbeast(jsonl: str, out_dir: str) -> dict:
    """Run Greyhound slow_detection on collect JSONL; return summary dict."""
    summary = {"ran": False, "n_changepoints": 0, "changepoints": [], "error": None}
    try:
        import ctypes
        import importlib.util

        stub = os.environ.get(
            "GREYHOUND_RBEAST_STUB",
            "/data/yinjinrun.p-huawei/opt/rbeast-fix/libbuiltin_readcyclecounter.so",
        )
        if os.path.isfile(stub):
            ctypes.CDLL(stub, mode=ctypes.RTLD_GLOBAL)
        sd_path = (
            Path(__file__).resolve().parent.parent
            / "detector"
            / "control_plane"
            / "slow_detection.py"
        )
        # pod layout
        alt = Path(
            "/data/yinjinrun.p-huawei/probe-bundle/greyhound/detector/control_plane/slow_detection.py"
        )
        if not sd_path.is_file():
            sd_path = alt
        if not sd_path.is_file():
            summary["error"] = f"slow_detection missing"
            return summary

        # load rows → call_id/call_time like run_s3_analyze
        rows = []
        with open(jsonl, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                o = json.loads(line)
                if o.get("op") == "AllReduce":
                    rows.append(o)
        if len(rows) < 20:
            summary["error"] = f"too few AllReduce rows: {len(rows)}"
            return summary
        rows.sort(key=lambda r: (r.get("t0", 0.0), r.get("pid", 0), r.get("seq", 0)))
        # Build repeating call_id pattern by seq%4 for ACF (collect has no op-id diversity)
        import numpy as np

        call_id, call_time = [], []
        t = 0.0
        for i, r in enumerate(rows):
            call_id.append(i % 4)
            call_time.append(t)
            t += max(float(r.get("dur_us", 1.0)) * 1e-6, 1e-6)

        spec = importlib.util.spec_from_file_location("gh_sd", str(sd_path))
        sd = importlib.util.module_from_spec(spec)
        assert spec.loader
        spec.loader.exec_module(sd)
        start, period = sd.find_period(np.asarray(call_id), nlags=min(200, len(call_id) // 2))
        summary["acf_start"] = int(start) if start is not None else None
        summary["acf_period"] = int(period) if period is not None else None
        summary["ran"] = True
        if period and period > 0 and start is not None and start >= 0:
            cp_df, last_avg = sd.find_performance_drop(
                np.asarray(call_id),
                np.asarray(call_time, dtype=float),
                period=int(period),
                start=int(start),
                thresh_prob=0.5,
                plot=False,
            )
            summary["rbeast_last10_avg_ts"] = float(last_avg) if last_avg is not None else None
            if cp_df is not None and len(cp_df):
                cps = []
                for _, r in cp_df.iterrows():
                    cid = r["ids"]
                    cval = r["values"]
                    cval = float(np.asarray(cval).ravel()[0])
                    cps.append({"id": int(cid), "t": cval})
                summary["changepoints"] = cps
                summary["n_changepoints"] = len(cps)
        Path(out_dir).mkdir(parents=True, exist_ok=True)
        (Path(out_dir) / "rbeast_c1.json").write_text(
            json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
    except Exception as e:
        summary["error"] = f"{type(e).__name__}: {e}"
    return summary


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump-root", required=True)
    ap.add_argument("--inject-start", type=int, default=100)
    ap.add_argument("--inject-stop", type=int, default=300)
    ap.add_argument("--accept-min-ratio", type=float, default=1.3)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    root = args.dump_root
    c0_jsonl = os.path.join(root, "C0_baseline", "greyhound", "hcclprobe.collect.jsonl")
    c1_jsonl = os.path.join(root, "C1_inject_none", "greyhound", "hcclprobe.collect.jsonl")
    c0_ranks = os.path.join(root, "C0_baseline", "ranks")
    c1_ranks = os.path.join(root, "C1_inject_none", "ranks")

    c0 = load_coll_durs(c0_jsonl)
    c1 = load_coll_durs(c1_jsonl)
    m0, m1 = med(c0), med(c1)
    coll_ratio = (m1 / m0) if m0 and m0 == m0 and m0 > 0 else float("nan")
    coll_pass = coll_ratio == coll_ratio and coll_ratio >= args.accept_min_ratio

    s0 = load_step_ms(c0_ranks)
    s1 = load_step_ms(c1_ranks)
    # dose window medians (oracle-aligned check)
    w0 = window_med(s0, args.inject_start, args.inject_stop)
    w1 = window_med(s1, args.inject_start, args.inject_stop)
    step_ratio = (w1 / w0) if w0 and w0 == w0 and w0 > 0 else float("nan")
    dose_ok = step_ratio == step_ratio and step_ratio >= args.accept_min_ratio

    rb = try_rbeast(c1_jsonl, os.path.join(root, "C1_inject_none", "greyhound"))
    rbeast_hit = int(rb.get("n_changepoints") or 0) > 0

    # autonomous detect: Greyhound-owned signals only
    auto_ok = bool(coll_pass or rbeast_hit)
    detect_mode = "autonomous" if auto_ok else "no_bite"
    oracle_note = (
        f"注入窗 [{args.inject_start},{args.inject_stop}] 仅标注；"
        f"step_ms 窗比={step_ratio:.3f}（剂量核对，非 Greyhound 规则）"
    )

    lines = [
        "# Greyhound S4 · P3-EXT-A Loud contrast",
        "",
        f"- case_ref: `20260724_231918-yjr-as-c-p3exta-loud` (C1/C0 step_ms=1.97)",
        f"- dose: stress-ng `--cpu $(nproc) --cpu-load 90`；窗对齐 Case [{args.inject_start},{args.inject_stop}]",
        f"- detect_mode: **{detect_mode}**（自主= coll 比≥{args.accept_min_ratio} 或 Rbeast 变点）",
        f"- oracle_trigger: **no**（未把注入窗写入判定）；{oracle_note}",
        f"- preload: cyclecounter stub + libhcclprobe.so；Redis :16379",
        "",
        "## A) autonomous · collect-min AllReduce host-wall",
        "",
        f"| arm | n | median dur_us |",
        f"|-----|--:|-------------:|",
        f"| C0  | {len(c0)} | {m0:.1f} |",
        f"| C1  | {len(c1)} | {m1:.1f} |",
        "",
        f"**C1/C0 coll ratio = {coll_ratio:.3f}** → "
        f"{'PASS' if coll_pass else 'FAIL'} (thr {args.accept_min_ratio})",
        "",
        "## B) autonomous · Greyhound Rbeast on C1 collect",
        "",
        f"- ran: {rb.get('ran')} period={rb.get('acf_period')} n_cp={rb.get('n_changepoints')}",
        f"- changepoints: {rb.get('changepoints')}",
        f"- error: {rb.get('error')}",
        "",
        "## C) dose check · step_ms in oracle window (not Greyhound rule)",
        "",
        f"| arm | window median step_ms |",
        f"|-----|----------------------:|",
        f"| C0  | {w0:.2f} |",
        f"| C1  | {w1:.2f} |",
        f"| C1/C0 | {step_ratio:.3f} → {'dose_OK' if dose_ok else 'dose_WEAK'} |",
        "",
        "## Verdict",
        "",
        f"- **autonomous_detect**: {'YES' if auto_ok else 'NO'} "
        f"(coll_pass={coll_pass}, rbeast_hit={rbeast_hit})",
        f"- **dose_reproduced**: {'YES' if dose_ok else 'NO/WEAK'} (step_ms)",
        "",
        "Note: P3-EXT-A 是 host CPU 抢占；Greyhound 主路径是 CCL 时间戳+变点。"
        "若 coll/Rbeast 无咬合而 step_ms 有抬升，记能力边界（同 XPUTimer S4），不焊 D4。",
        "",
    ]
    text = "\n".join(lines)
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(text)
    meta = {
        "coll_ratio": coll_ratio,
        "coll_pass": coll_pass,
        "step_ratio": step_ratio,
        "dose_ok": dose_ok,
        "rbeast": rb,
        "autonomous_detect": auto_ok,
        "detect_mode": detect_mode,
        "oracle_trigger": False,
    }
    with open(os.path.join(root, "S4_SUMMARY.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
