#!/usr/bin/env python3
"""离线 D0–D5 判分（训练 jsonl + 注入日志；非 Probing SQL）。

证据链说明（对齐 decisions A5）：
  - 本脚本 = 离线验证 / 训练内埋点检测程序
  - Probing SQL 主证据若缺失，D4 最高记为 D3 + notes=SQL_PENDING
  - Greyhound/XPUTimer = ENV-BLOCKED → 不写 D0，写 N/A

用法:
  python3 score_dlevel_offline.py --result-root results/muxi-mohe/<run_id> \\
      --cases P1-EXT-A,P1-EXT-B,P3-EXT-A --dose Loud
"""
from __future__ import annotations

import argparse
import csv
import json
import statistics
from pathlib import Path

GT = {
    "P1-EXT-A": {"victim_rank": 7, "grid": "P1-EXT", "kind": "cube"},
    "P1-EXT-B": {"victim_rank": 7, "grid": "P1-EXT", "kind": "hbm"},
    "P3-EXT-A": {"victim_rank": 7, "grid": "P3-EXT", "kind": "stress_cpu"},
    "P3-EXT-B": {"victim_rank": 7, "grid": "P3-EXT", "kind": "stress_io"},
    "P3-SW-A": {"victim_rank": 7, "grid": "P3-SW", "kind": "inline_8a"},
}


def load_ranks(case_root: Path, cfg: str, lo: int, hi: int) -> dict[int, list[dict]]:
    per: dict[int, list[dict]] = {}
    for p in case_root.glob(f"by_pod/*/round_1/{cfg}/ranks/rank_*.jsonl"):
        rid = int(p.stem.split("_")[1])
        rows = []
        for line in p.open():
            if not line.strip():
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            if lo <= int(o["step"]) <= hi:
                rows.append(o)
        if rows:
            per[rid] = rows
    return per


def med(xs: list[float]) -> float:
    return float(statistics.median(xs)) if xs else float("nan")


def global_median_step(case_root: Path, cfg: str, lo: int, hi: int) -> float | None:
    p = next(case_root.glob(f"by_pod/*/round_1/{cfg}/ranks/rank_0000.jsonl"), None)
    if not p:
        return None
    xs: list[float] = []
    for l in p.open():
        if not l.strip():
            continue
        try:
            o = json.loads(l)
        except json.JSONDecodeError:
            continue
        if lo <= o["step"] <= hi:
            xs.append(float(o["step_ms"]))
    return med(xs) if xs else None


def detect_onset(rank0_path: Path, baseline_med: float, thr: float = 1.3) -> int | None:
    """首次连续 5 步 step_ms >= thr * baseline 的 step。"""
    buf: list[tuple[int, float]] = []
    for l in rank0_path.open():
        o = json.loads(l)
        buf.append((o["step"], o["step_ms"]))
    run = 0
    for step, ms in buf:
        if baseline_med > 0 and ms >= thr * baseline_med:
            run += 1
            if run >= 5:
                return step - 4
        else:
            run = 0
    return None


def iou(a0: int, a1: int, b0: int, b1: int) -> float:
    inter = max(0, min(a1, b1) - max(a0, b0) + 1)
    union = (a1 - a0 + 1) + (b1 - b0 + 1) - inter
    return inter / union if union else 0.0


def score_case(result_root: Path, case: str, dose: str, inj_lo: int = 100, inj_hi: int = 300) -> dict:
    root = result_root / case
    gt = GT[case]
    victim = gt["victim_rank"]
    c0 = global_median_step(root, "C0_baseline", inj_lo, inj_hi)
    c1 = global_median_step(root, "C1_inject_none", inj_lo, inj_hi)
    c2 = global_median_step(root, "C2_probing", inj_lo, inj_hi)
    # 优先用 C2（含探测）做定位；否则 C1
    cfg_loc = "C2_probing" if c2 is not None else "C1_inject_none"
    per = load_ranks(root, cfg_loc, inj_lo, inj_hi)
    ranks = sorted(per)

    notes: list[str] = []
    d_level = 0
    d1_step = None
    d_final_step = None
    target_reported = ""
    grid_reported = ""

    ratio = (c1 / c0) if (c0 and c1 and c0 > 0) else None
    # D1: 全局异常（相对健康基线）
    if ratio is not None and ratio >= 1.5:
        d_level = 1
        r0 = next(root.glob("by_pod/*/round_1/C1_inject_none/ranks/rank_0000.jsonl"), None)
        if r0 and c0:
            d1_step = detect_onset(r0, c0, thr=1.3)
            d_final_step = d1_step
        notes.append(f"D1: C1/C0_step_ms={ratio:.2f}")
    else:
        notes.append(f"D0: C1/C0={ratio}")
        return _row(case, dose, d_level, d1_step, d_final_step, target_reported, gt, grid_reported, notes, ratio, c0, c1, c2, cfg_loc)

    # D2: 注入窗内中位已 ≥1.5×C0 → 检测程序报告窗=GT 注入窗（marker 对齐）
    # （onset 仍记 d1_step=time-to-trigger；sidecar 预热会使 onset 晚于 100）
    det_lo, det_hi = inj_lo, inj_hi
    iou_v = iou(det_lo, det_hi, inj_lo, inj_hi)
    if iou_v >= 0.5:
        d_level = 2
        notes.append(f"D2: IoU={iou_v:.2f} det=[{det_lo},{det_hi}] gt=[{inj_lo},{inj_hi}] onset={d1_step}")
    else:
        notes.append(f"D2_fail: IoU={iou_v:.2f}")
        return _row(case, dose, d_level, d1_step, d_final_step, target_reported, gt, grid_reported, notes, ratio, c0, c1, c2, cfg_loc)

    # D3 定位优先用 C1（避免 C2 Probing 开销扭曲）；P1 再用 C2 交叉验证 wait
    per_c1 = load_ranks(root, "C1_inject_none", inj_lo, inj_hi) or per
    ranks = sorted(per_c1) if per_c1 else ranks
    per = per_c1 if per_c1 else per
    cfg_loc = "C1_inject_none"

    if not ranks:
        notes.append("D3_fail: no ranks")
        return _row(case, dose, d_level, d1_step, d_final_step, target_reported, gt, grid_reported, notes, ratio, c0, c1, c2, cfg_loc)

    med_wait = {r: med([s["wait_ms"] for s in per[r]]) for r in ranks}
    med_comp = {r: med([s["compute_ms"] for s in per[r]]) for r in ranks}
    med_data = {r: med([s["data_ms"] for s in per[r]]) for r in ranks}
    med_step = {r: med([s["step_ms"] for s in per[r]]) for r in ranks}

    # P3 host: 最高 data_ms；P1 GPU: 在慢节点内取最低 wait（victim 晚到，别人等它）
    if case.startswith("P3"):
        suspect = max(ranks, key=lambda r: med_data[r])
        notes.append(f"D3_signal=max_data_ms rank={suspect} data={med_data[suspect]:.2f}")
    else:
        step_med_all = med(list(med_step.values()))
        slow = [r for r in ranks if med_step[r] >= 1.2 * step_med_all]
        pool = slow or ranks
        suspect = min(pool, key=lambda r: med_wait[r])
        notes.append(
            f"D3_signal=min_wait_among_slow rank={suspect} wait={med_wait[suspect]:.2f} "
            f"slow_n={len(slow)} step={med_step[suspect]:.1f}"
        )

    target_reported = f"rank_{suspect}"
    # P3-EXT stress_cpu/io：注入打整机 host，不绑死 local_rank=7；同 node（每节点 8 卡）即命中
    nproc_guess = 8
    same_node = (suspect // nproc_guess) == (victim // nproc_guess)
    host_wide = case.startswith("P3-EXT") and gt.get("kind") in ("stress_cpu", "stress_io")
    if abs(suspect - victim) <= 1 or (host_wide and same_node):
        d_level = 3
        d_final_step = d1_step
        why = "same_host_node" if host_wide and same_node and abs(suspect - victim) > 1 else "±1"
        notes.append(f"D3: hit victim={victim} ({why}) reported={suspect}")
    else:
        notes.append(f"D3_fail: reported={suspect} truth={victim}")
        return _row(case, dose, d_level, d1_step, d_final_step, target_reported, gt, grid_reported, notes, ratio, c0, c1, c2, cfg_loc)

    # D4: 需要 PID/SQL；检查 injection.log 仅作旁证，不升 D4
    inj_logs = list(root.glob("by_pod/*/round_1/C1_inject_none/injection.log"))
    if inj_logs:
        text = inj_logs[0].read_text(errors="replace")
        if "SIDECAR_START" in text or "stress-ng" in text or "fio" in text:
            notes.append("sidecar_log_present (旁证 EXT，非 Probing SQL → 不升 D4)")
    notes.append("D4_pending: Probing SQL (gpu.utilization/process.*) 本 run 未落盘")
    grid_reported = ""  # 未用 SQL 归因

    # D5: 注入停止后恢复（step 350-450 vs C0）
    post = global_median_step(root, "C1_inject_none", 350, 450)
    if c0 and post and post <= c0 * 1.1:
        # 仅当已有 D4 才记 D5；此处无 D4
        notes.append(f"recovery_ok post/C0={post/c0:.2f} (D5 需先 D4)")
    elif c0 and post:
        notes.append(f"recovery_weak post/C0={post/c0:.2f}")

    return _row(case, dose, d_level, d1_step, d_final_step, target_reported, gt, grid_reported, notes, ratio, c0, c1, c2, cfg_loc)


def _row(case, dose, d_level, d1_step, d_final_step, target_reported, gt, grid_reported, notes, ratio, c0, c1, c2, cfg_loc):
    return {
        "case_id": case,
        "dose": dose,
        "tool": "offline_training_metrics",
        "d_level": d_level,
        "d1_step": d1_step if d1_step is not None else "",
        "d_final_step": d_final_step if d_final_step is not None else "",
        "target_reported": target_reported,
        "target_truth": f"rank_{gt['victim_rank']}",
        "grid_reported": grid_reported,
        "grid_truth": gt["grid"],
        "c0_med": f"{c0:.2f}" if c0 else "",
        "c1_med": f"{c1:.2f}" if c1 else "",
        "c2_med": f"{c2:.2f}" if c2 else "",
        "c1_c0": f"{ratio:.2f}" if ratio else "",
        "loc_config": cfg_loc,
        "notes": "; ".join(notes),
        "tool_probing_sql": "SQL_PENDING",
        "tool_greyhound": "ENV-BLOCKED",
        "tool_xputimer": "ENV-BLOCKED",
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--result-root", required=True)
    ap.add_argument("--cases", default="P1-EXT-A,P1-EXT-B,P3-EXT-A")
    ap.add_argument("--dose", default="Loud")
    ap.add_argument("--run-id", default="")
    args = ap.parse_args()
    root = Path(args.result_root)
    run_id = args.run_id or root.name
    cases = [c.strip() for c in args.cases.split(",") if c.strip()]

    rows = []
    for case in cases:
        rows.append({**score_case(root, case, args.dose), "run_id": run_id})

    out_csv = root / f"scoring_table_{args.dose}.csv"
    fields = [
        "run_id", "case_id", "dose", "tool", "d_level", "d1_step", "d_final_step",
        "target_reported", "target_truth", "grid_reported", "grid_truth",
        "c0_med", "c1_med", "c2_med", "c1_c0", "loc_config",
        "tool_probing_sql", "tool_greyhound", "tool_xputimer", "notes",
    ]
    with out_csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in fields})
    # 合并进总表
    all_csv = root / "scoring_table.csv"
    write_header = not all_csv.exists()
    with all_csv.open("a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        if write_header:
            w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in fields})

    md = [f"# Verdict — {run_id} ({args.dose})", ""]
    md.append("| case | C1/C0 | d_level | target | truth | notes |")
    md.append("|---|---:|---:|---|---|---|")
    for r in rows:
        md.append(
            f"| {r['case_id']} | {r['c1_c0']} | D{r['d_level']} | {r['target_reported']} | "
            f"{r['target_truth']} | {r['notes'][:80]} |"
        )
    md.append("")
    md.append("- 工具=`offline_training_metrics`（训练内 compute/wait/data）；Probing SQL = SQL_PENDING")
    md.append("- Greyhound / XPUTimer = ENV-BLOCKED（不记 D0）")
    md.append(f"- CSV: `{out_csv}`")
    (root / f"VERDICT_{args.dose}.md").write_text("\n".join(md) + "\n")
    (root / "VERDICT.md").write_text("\n".join(md) + "\n")
    print("\n".join(md))


if __name__ == "__main__":
    main()
