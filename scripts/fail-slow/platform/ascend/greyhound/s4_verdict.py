#!/usr/bin/env python3
"""Greyhound S4 verdict · P3-EXT-A Loud 同剂量对照.

两轴分开记（不把 Case step_ms 答案焊进 Greyhound 判据）:
  A) autonomous_coll: C1/C0 median HcclAllReduce dur_us（collect-min JSONL）
  B) autonomous_rbeast: 用**真实 per-rank 序列**跑 find_period+find_performance_drop；
     健康线 C0 同跑作假阳性对照（C1 有变点、C0 无 才算检出）
  C) dose_check (oracle-aligned): rank jsonl step_ms C1/C0（验证剂量；非 Greyhound 规则）
  D) oracle_window: 注入窗 [inject_start, inject_stop] 仅作对照标注

detect_ok=yes 若 A 咬合≥1.3 或 B 检出变点（排除 C0 假阳性）；否则如实记无咬合。
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import statistics
import sys
from pathlib import Path

# 让 `import collect_seq` 找到同目录的 helper（contrast 脚本用绝对路径调本文件）
sys.path.insert(0, str(Path(__file__).resolve().parent))


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


def _find_slow_detection() -> "Path | None":
    """定位 Greyhound 自带 slow_detection.py（仓内 detector/ 或 pod bundle）。"""
    cands = [
        Path(__file__).resolve().parent.parent / "detector" / "control_plane" / "slow_detection.py",
        Path(
            "/data/yinjinrun.p-huawei/probe-bundle/greyhound/detector/control_plane/slow_detection.py"
        ),
    ]
    env = os.environ.get("GREYHOUND_SLOW_DETECTION", "")
    if env:
        cands.insert(0, Path(env))
    for c in cands:
        if c.is_file():
            return c
    return None


def try_rbeast(jsonl: str, out_dir: str, out_name: str = "rbeast.json") -> dict:
    """在 collect JSONL 上跑 Greyhound 自带 slow_detection（ACF + Rbeast）。

    用**真实 per-rank 集合通信序列**（`collect_seq`：按 pid 分 rank，(op,count)
    签名→call_id，真实 t0→call_time），跑 Greyhound 论文的 find_period +
    find_performance_drop——给对手它自己的最佳算法。选事件最多的 rank 作代表。
    不含任何 case 答案（注入窗/rank/PID 都不进来）。
    """
    summary = {"ran": False, "n_changepoints": 0, "changepoints": [], "error": None}
    try:
        import ctypes
        import importlib.util

        import numpy as np

        import collect_seq as cs

        stub = os.environ.get(
            "GREYHOUND_RBEAST_STUB",
            "/data/yinjinrun.p-huawei/opt/rbeast-fix/libbuiltin_readcyclecounter.so",
        )
        if os.path.isfile(stub):
            ctypes.CDLL(stub, mode=ctypes.RTLD_GLOBAL)

        sd_path = _find_slow_detection()
        if sd_path is None:
            summary["error"] = "slow_detection missing"
            return summary

        # 真实 per-rank 序列：选事件最多的 rank 作代表
        by_pid = cs.group_by_rank(cs.load_events(jsonl))
        rep_pid = cs.pick_busiest_rank(by_pid)
        if rep_pid is None:
            summary["error"] = "no collective events"
            return summary
        call_id, call_time = cs.build_call_sequence(by_pid[rep_pid])
        summary["rep_rank_pid"] = int(rep_pid)
        summary["n_ranks"] = len(by_pid)
        summary["n_calls"] = len(call_id)
        summary["n_uniq_sig"] = len(set(call_id))
        if len(call_id) < 20:
            summary["error"] = f"too few collective calls on rep rank: {len(call_id)}"
            return summary

        spec = importlib.util.spec_from_file_location("gh_sd", str(sd_path))
        sd = importlib.util.module_from_spec(spec)
        assert spec.loader
        spec.loader.exec_module(sd)
        cid = np.asarray(call_id, dtype=np.int64)
        ctime = np.asarray(call_time, dtype=float)
        start, period = sd.find_period(cid, nlags=min(200, len(call_id) // 2))
        summary["acf_start"] = int(start) if start is not None else None
        summary["acf_period"] = int(period) if period is not None else None
        summary["ran"] = True
        if period and period > 0 and start is not None and start >= 0:
            cp_df, last_avg = sd.find_performance_drop(
                cid,
                ctime,
                period=int(period),
                start=int(start),
                thresh_prob=0.5,
                plot=False,
            )
            summary["rbeast_last10_avg_ts"] = float(last_avg) if last_avg is not None else None
            if cp_df is not None and len(cp_df):
                cps = []
                for _, r in cp_df.iterrows():
                    cid_row = r["ids"]
                    cval = r["values"]
                    cval = float(np.asarray(cval).ravel()[0])
                    cps.append({"id": int(cid_row), "t": cval})
                summary["changepoints"] = cps
                summary["n_changepoints"] = len(cps)
        Path(out_dir).mkdir(parents=True, exist_ok=True)
        (Path(out_dir) / out_name).write_text(
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

    rb1 = try_rbeast(c1_jsonl, os.path.join(root, "C1_inject_none", "greyhound"), "rbeast_c1.json")
    # C0 假阳性对照：健康线上也跑 Rbeast。只有 C1 报变点而 C0 不报，才算真检出。
    rb0 = try_rbeast(c0_jsonl, os.path.join(root, "C0_baseline", "greyhound"), "rbeast_c0.json")
    cp1 = int(rb1.get("n_changepoints") or 0)
    cp0 = int(rb0.get("n_changepoints") or 0)
    # Rbeast 自主检出：C1 报变点 且 C0 未报（同 seed 同结构，C0 报了说明是假阳性）
    rbeast_hit = cp1 > 0 and cp0 == 0
    rbeast_fp = cp1 > 0 and cp0 > 0  # 两边都报 → 假阳性，不算检出

    # autonomous detect: Greyhound-owned signals only（coll 比 或 排除假阳性的 Rbeast 变点）
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
        f"- detect_mode: **{detect_mode}**（自主= coll 比≥{args.accept_min_ratio} 或 Rbeast 变点[C1有/C0无]）",
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
        "## B) autonomous · Greyhound Rbeast（真实 per-rank 序列；C0 假阳性对照）",
        "",
        "> call_id 用真实 (op,count) 签名序列、call_time 用真实 t0（`collect_seq`），"
        "跑 Greyhound 自带 find_period+find_performance_drop。健康线 C0 同跑作对照。",
        "",
        f"| arm | rep_rank | n_calls | uniq_sig | acf_period | n_changepoints |",
        f"|-----|---------:|--------:|---------:|-----------:|---------------:|",
        f"| C0  | {rb0.get('rep_rank_pid')} | {rb0.get('n_calls')} | {rb0.get('n_uniq_sig')} "
        f"| {rb0.get('acf_period')} | {cp0} |",
        f"| C1  | {rb1.get('rep_rank_pid')} | {rb1.get('n_calls')} | {rb1.get('n_uniq_sig')} "
        f"| {rb1.get('acf_period')} | {cp1} |",
        "",
        f"- C1 changepoints: {rb1.get('changepoints')}",
        f"- C0 changepoints: {rb0.get('changepoints')}",
        f"- rbeast_hit (C1有/C0无): **{rbeast_hit}**"
        + ("  ⚠️ 两边都报变点=假阳性，不计检出" if rbeast_fp else ""),
        f"- error: C1={rb1.get('error')} C0={rb0.get('error')}",
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
        f"(coll_pass={coll_pass}, rbeast_hit={rbeast_hit}, rbeast_fp={rbeast_fp})",
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
        "rbeast_c1": rb1,
        "rbeast_c0": rb0,
        "rbeast_hit": rbeast_hit,
        "rbeast_fp": rbeast_fp,
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
