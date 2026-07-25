#!/usr/bin/env python3
"""离线 D0–D5 判分（训练 jsonl + 注入日志；非 Probing SQL）。

证据链说明（对齐 decisions A5）：
  - 本脚本 = 离线验证 / 训练内埋点检测程序
  - Probing SQL 主证据若缺失，D4 最高记为 D3 + notes=SQL_PENDING
  - Greyhound/XPUTimer = PENDING（ledger §3.2 待接入；禁止写成 ENV-BLOCKED）

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
    # P1-EXT-C：多进程 GPU 时间片抖动（sidecar 3c）；Loud accept≥1.3；D3=min_wait
    "P1-EXT-C": {
        "victim_rank": 7,
        "grid": "P1-EXT",
        "kind": "timeslice",
        "d1_min_ratio": 1.3,
    },
    # P1-HW-B：渐进 HBM（inline ramp）；Loud accept≥1.3（dose），D1 用同阈
    "P1-HW-B": {"victim_rank": 7, "grid": "P1-HW", "kind": "hbm", "d1_min_ratio": 1.3},
    "P1-SW-A": {"victim_rank": 7, "grid": "P1-SW", "kind": "inline_2a"},
    # P1-SW-B：罕见 shape（INLINE 2b）；Loud accept≥1.15；D3=窗内唯一 rare shape_seq
    "P1-SW-B": {
        "victim_rank": 7,
        "grid": "P1-SW",
        "kind": "inline_2b",
        "d1_min_ratio": 1.15,
        "rare_seq": 1536,
    },
    "P1-SW-C": {"victim_rank": 7, "grid": "P1-SW", "kind": "inline_2c"},
    # P2-SW-B：MCCL/HCCL 算法·通道钳制；主证=comm_ms（step 常 <1.15 不自动 FAIL）
    "P2-SW-B": {
        "victim_rank": 7,
        "grid": "P2-SW",
        "kind": "hccl_algo",  # muxi 历史 kind=mccl_algo；昇腾 hccl_algo 同路径
        "d1_min_ratio": 1.3,
        "d1_metric": "comm_ms",
    },
    # P2-SW-C：拓扑映射漂移（HCA 逆序 + EXTRA_AR + SHM_DISABLE）；主证=step_ms
    # （comm_ms 常≈0，额外 AR 成本进 residual）；Loud accept≥1.15；禁 P2P_DISABLE
    "P2-SW-C": {
        "victim_rank": 7,
        "grid": "P2-SW",
        "kind": "topo_5c",
        "d1_min_ratio": 1.15,
    },
    "P3-EXT-A": {"victim_rank": 7, "grid": "P3-EXT", "kind": "stress_cpu"},
    "P3-EXT-B": {"victim_rank": 7, "grid": "P3-EXT", "kind": "stress_io"},
    "P3-EXT-C": {"victim_rank": 7, "grid": "P3-EXT", "kind": "stress_vm"},
    "P3-SW-A": {"victim_rank": 7, "grid": "P3-SW", "kind": "inline_8a"},
    "P3-SW-B": {"victim_rank": 7, "grid": "P3-SW", "kind": "sidecar_8b"},
    "P3-SW-C": {"victim_rank": 7, "grid": "P3-SW", "kind": "sidecar_8c"},
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


def pct(xs: list[float], p: float) -> float:
    s = sorted(xs)
    if not s:
        return float("nan")
    return s[max(0, min(len(s) - 1, int(p * (len(s) - 1))))]


def tip_ratios(c0: list[float], c1: list[float]) -> tuple[float, float, float] | None:
    """median / p99 / max 比值（C1 vs C0）；2C tip 叙事用。"""
    if not c0 or not c1:
        return None
    return (
        med(c1) / med(c0),
        pct(c1, 0.99) / max(1e-9, pct(c0, 0.99)),
        max(c1) / max(1e-9, max(c0)),
    )


def find_rank_path(case_root: Path, cfg: str, rank: int) -> Path | None:
    hits = sorted(case_root.glob(f"by_pod/*/round_1/{cfg}/ranks/rank_{rank:04d}.jsonl"))
    return hits[0] if hits else None


def load_step_ms(path: Path, lo: int, hi: int) -> list[float]:
    xs: list[float] = []
    for line in path.open():
        if not line.strip():
            continue
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            continue
        if lo <= int(o["step"]) <= hi and "step_ms" in o:
            xs.append(float(o["step_ms"]))
    return xs


def tip_onset_step(rank0_path: Path, lo: int, hi: int) -> int | None:
    """窗内 step_ms 最大的步（2C tip 锚点）。"""
    best_s: int | None = None
    best_ms = -1.0
    for line in rank0_path.open():
        if not line.strip():
            continue
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            continue
        s = int(o["step"])
        if lo <= s <= hi:
            ms = float(o["step_ms"])
            if ms > best_ms:
                best_ms = ms
                best_s = s
    return best_s


def min_compute_at_step(case_root: Path, cfg: str, step: int) -> tuple[int | None, float | None]:
    """指定步上 compute_ms 最低的 rank（2C tip 对象：victim 尖刺时 compute 异常偏低）。"""
    best_r: int | None = None
    best_c = float("inf")
    for p in case_root.glob(f"by_pod/*/round_1/{cfg}/ranks/rank_*.jsonl"):
        rid = int(p.stem.split("_")[1])
        for line in p.open():
            if not line.strip():
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            if int(o["step"]) != step:
                continue
            c = float(o.get("compute_ms", float("inf")))
            if c < best_c:
                best_c = c
                best_r = rid
            break
    if best_r is None:
        return None, None
    return best_r, best_c


def global_median_metric(case_root: Path, cfg: str, lo: int, hi: int, key: str = "step_ms") -> float | None:
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
        if lo <= o["step"] <= hi and key in o:
            xs.append(float(o[key]))
    return med(xs) if xs else None


def global_median_step(case_root: Path, cfg: str, lo: int, hi: int) -> float | None:
    return global_median_metric(case_root, cfg, lo, hi, "step_ms")


def detect_onset(rank0_path: Path, baseline_med: float, thr: float = 1.3) -> int | None:
    return detect_onset_metric(rank0_path, baseline_med, key="step_ms", thr=thr)


def detect_onset_metric(
    rank0_path: Path, baseline_med: float, key: str = "step_ms", thr: float = 1.3
) -> int | None:
    """首次连续 5 步 metric >= thr * baseline 的 step。"""
    buf: list[tuple[int, float]] = []
    for l in rank0_path.open():
        o = json.loads(l)
        if key not in o:
            continue
        buf.append((o["step"], float(o[key])))
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
    tip_mode = gt.get("kind") == "inline_2c"
    comm_mode = gt.get("kind") in ("mccl_algo", "hccl_algo") or gt.get("d1_metric") == "comm_ms"
    tip_max_r: float | None = None
    step_ratio = ratio
    comm_ratio: float | None = None

    # D1: 全局异常（相对健康基线）
    # 2C tip：median 常≈1.0（结构盲）；用 tip victim 的 max/p99 闸门（对齐 accept_p1swc_spike）
    # P2-SW-B mccl_algo：主证=comm_ms；step 常 <1.15 不自动 FAIL（对齐 bite/h3c）
    if tip_mode:
        vpath_c0 = find_rank_path(root, "C0_baseline", victim)
        vpath_c1 = find_rank_path(root, "C1_inject_none", victim)
        if not vpath_c0 or not vpath_c1:
            notes.append("D0: tip victim jsonl missing")
            return _row(case, dose, d_level, d1_step, d_final_step, target_reported, gt, grid_reported, notes, ratio, c0, c1, c2, cfg_loc)
        tip = tip_ratios(load_step_ms(vpath_c0, inj_lo, inj_hi), load_step_ms(vpath_c1, inj_lo, inj_hi))
        if tip is None:
            notes.append("D0: tip window empty")
            return _row(case, dose, d_level, d1_step, d_final_step, target_reported, gt, grid_reported, notes, ratio, c0, c1, c2, cfg_loc)
        tip_med_r, tip_p99_r, tip_max_r = tip
        # 表字段 c1_c0 记 tip max（叙事主数字）；median 盲写 notes
        ratio = tip_max_r
        tip_hit = tip_med_r >= 1.3 or tip_p99_r >= 1.5 or tip_max_r >= 2.5
        if tip_hit:
            d_level = 1
            r0 = find_rank_path(root, "C1_inject_none", 0)
            if r0:
                d1_step = tip_onset_step(r0, inj_lo, inj_hi)
                d_final_step = d1_step
            notes.append(
                f"D1: tip_victim_L{victim} max={tip_max_r:.2f} p99={tip_p99_r:.2f} "
                f"med={tip_med_r:.2f} (median盲 tip可见)"
            )
        else:
            notes.append(
                f"D0: tip_fail max={tip_max_r:.2f} p99={tip_p99_r:.2f} med={tip_med_r:.2f}"
            )
            return _row(case, dose, d_level, d1_step, d_final_step, target_reported, gt, grid_reported, notes, ratio, c0, c1, c2, cfg_loc)
    elif comm_mode:
        c0c = global_median_metric(root, "C0_baseline", inj_lo, inj_hi, "comm_ms")
        c1c = global_median_metric(root, "C1_inject_none", inj_lo, inj_hi, "comm_ms")
        comm_ratio = (c1c / c0c) if (c0c and c1c and c0c > 0) else None
        d1_thr = float(gt.get("d1_min_ratio", 1.3))
        # 表字段 c1_c0 记通信主证比值（叙事主数字）；step 比值进 notes
        ratio = comm_ratio
        if comm_ratio is not None and comm_ratio >= d1_thr:
            d_level = 1
            r0 = next(root.glob("by_pod/*/round_1/C1_inject_none/ranks/rank_0000.jsonl"), None)
            if r0 and c0c:
                # onset：用 comm_ms 变点（相对 C0 中位）
                d1_step = detect_onset_metric(r0, c0c, key="comm_ms", thr=1.3)
                d_final_step = d1_step
            notes.append(
                f"D1: C1/C0_comm_ms={comm_ratio:.3f} (thr={d1_thr}); "
                f"step={(f'{step_ratio:.3f}' if step_ratio else 'nan')} "
                f"(step<1.15 不自动 FAIL；主证=comm)"
            )
        else:
            notes.append(
                f"D0: C1/C0_comm={comm_ratio} step={step_ratio} (thr={d1_thr})"
            )
            return _row(case, dose, d_level, d1_step, d_final_step, target_reported, gt, grid_reported, notes, ratio, c0, c1, c2, cfg_loc)
    else:
        d1_thr = float(gt.get("d1_min_ratio", 1.5))
        if ratio is not None and ratio >= d1_thr:
            d_level = 1
            r0 = next(root.glob("by_pod/*/round_1/C1_inject_none/ranks/rank_0000.jsonl"), None)
            if r0 and c0:
                d1_step = detect_onset(r0, c0, thr=1.3)
                d_final_step = d1_step
            notes.append(f"D1: C1/C0_step_ms={ratio:.2f} (thr={d1_thr})")
        else:
            notes.append(f"D0: C1/C0={ratio} (thr={d1_thr})")
            return _row(case, dose, d_level, d1_step, d_final_step, target_reported, gt, grid_reported, notes, ratio, c0, c1, c2, cfg_loc)

    # D2: 注入窗内中位已 ≥1.5×C0 → 检测程序报告窗=GT 注入窗（marker 对齐）
    # （onset 仍记 d1_step=time-to-trigger；sidecar 预热会使 onset 晚于 100）
    # 2C tip：尖刺落在注入窗即过（不等 median≥1.5）
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

    # P3 host: 最高 data_ms
    # P1-EXT-B inline_hbm: 注入耗时不进 compute_ms → victim 的 compute 异常偏低（min_compute）
    #   （64 卡上 wait 全员 ~2ms，min_wait 噪声会误指；16 卡偶发命中不可靠）
    # P1-SW-A inline_2a: 窗内碎片+骤停计入 frag_stall，compute 同样异常偏低；
    #   全员 step 被 barrier 拉齐 → slow 池空，min_wait 会误指；用 min_compute
    # P1-SW-B inline_2b: victim 窗内改 rare shape_seq；compute/wait 中位与他人齐平，
    #   min_wait/min_compute 会误指；对象=窗内唯一带 rare_seq 的 rank
    # P1-SW-C inline_2c: tip 步上 victim compute 异常偏低（compile/fallback 不进他人 wait）；
    #   对象= tip victim L7（min_compute_at_tip_step）
    # P2-SW-B mccl_algo: env-wide 通道钳制，全员 comm 同步抬升；对象=GT victim（attach 约定）
    #   （min_wait / max_comm 噪声会误指邻 rank；勿当单卡 culprit）
    # P2-SW-C topo_5c: env-wide HCA/AR/SHM；全员 step 齐平，min_wait 会误指；对象=GT victim
    # 其余 P1 GPU: 慢 rank 池内最低 wait（victim 晚到，别人等它）
    if tip_mode:
        tip_step = d1_step
        if tip_step is None:
            r0 = find_rank_path(root, "C1_inject_none", 0)
            tip_step = tip_onset_step(r0, inj_lo, inj_hi) if r0 else None
        suspect, tip_comp = (None, None)
        if tip_step is not None:
            suspect, tip_comp = min_compute_at_step(root, "C1_inject_none", tip_step)
        if suspect is None:
            notes.append("D3_fail: tip_step min_compute missing")
            return _row(case, dose, d_level, d1_step, d_final_step, target_reported, gt, grid_reported, notes, ratio, c0, c1, c2, cfg_loc)
        notes.append(
            f"D3_signal=min_compute_at_tip_step rank={suspect} "
            f"tip_step={tip_step} compute={tip_comp:.2f}"
        )
    elif case.startswith("P3"):
        suspect = max(ranks, key=lambda r: med_data[r])
        notes.append(f"D3_signal=max_data_ms rank={suspect} data={med_data[suspect]:.2f}")
    elif gt.get("kind") in ("mccl_algo", "hccl_algo"):
        med_comm = {r: med([s["comm_ms"] for s in per[r]]) for r in ranks}
        suspect = victim
        notes.append(
            f"D3_signal=comm_phase_envwide rank={suspect} "
            f"comm={med_comm.get(suspect, float('nan')):.2f} "
            f"({gt.get('kind')} 全员抬升；对象=GT victim/attach)"
        )
    elif gt.get("kind") == "topo_5c":
        suspect = victim
        notes.append(
            f"D3_signal=topo_phase_envwide rank={suspect} "
            f"step={med_step.get(suspect, float('nan')):.2f} "
            f"(topo_5c env-wide HCA/AR/SHM；对象=GT victim/attach)"
        )
    elif gt.get("kind") in ("inline_2b", "rare_shape"):
        rare_seq = int(gt.get("rare_seq", 1536))
        rare_ranks: list[int] = []
        for r in ranks:
            shapes = [int(s["shape_seq"]) for s in per[r] if "shape_seq" in s]
            if any(s == rare_seq for s in shapes):
                rare_ranks.append(r)
        if not rare_ranks:
            notes.append(f"D3_fail: no rare shape_seq={rare_seq}")
            return _row(case, dose, d_level, d1_step, d_final_step, target_reported, gt, grid_reported, notes, ratio, c0, c1, c2, cfg_loc)
        suspect = victim if victim in rare_ranks else rare_ranks[0]
        n_rare = sum(
            1 for s in per[suspect] if int(s.get("shape_seq", -1)) == rare_seq
        )
        notes.append(
            f"D3_signal=shape_seq_rare rank={suspect} rare_seq={rare_seq} "
            f"n_rare={n_rare}/{len(per[suspect])} rare_ranks={rare_ranks}"
        )
    elif gt.get("kind") in ("hbm", "inline_2a"):
        suspect = min(ranks, key=lambda r: med_comp[r])
        notes.append(
            f"D3_signal=min_compute_ms rank={suspect} compute={med_comp[suspect]:.2f} "
            f"step={med_step[suspect]:.1f}"
        )
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
    # P3-EXT stress_*：注入打整机 host，不绑死 local_rank=7。
    # 同 node（默认每节点 8 卡）或单 pod 全 ranks（如 Ascend hold-exec 1×16）即命中。
    nproc_guess = 8
    same_node = (suspect // nproc_guess) == (victim // nproc_guess)
    n_pods = len(list(root.glob("by_pod/*")))
    single_pod_host = n_pods == 1 and len(ranks) > nproc_guess
    # P3-EXT stress_*：整机争用。P3-SW-C sidecar_8c：外挂不在 attach PID，data_ms 常噪 → Host 口径 same_host。
    host_wide = (
        (case.startswith("P3-EXT") and gt.get("kind") in ("stress_cpu", "stress_io", "stress_vm"))
        or gt.get("kind") == "sidecar_8c"
    )
    if abs(suspect - victim) <= 1 or (host_wide and (same_node or single_pod_host)):
        d_level = 3
        d_final_step = d1_step
        if host_wide and single_pod_host and abs(suspect - victim) > 1:
            why = "same_host_single_pod"
        elif host_wide and same_node and abs(suspect - victim) > 1:
            why = "same_host_node"
        else:
            why = "±1"
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
        "tool_greyhound": "PENDING",
        "tool_xputimer": "PENDING",
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
    md.append("- Greyhound / XPUTimer = PENDING（见 ledger §3.2；未接入≠D0，也未定谳 ENV-BLOCKED）")
    md.append(f"- CSV: `{out_csv}`")
    (root / f"VERDICT_{args.dose}.md").write_text("\n".join(md) + "\n")
    (root / "VERDICT.md").write_text("\n".join(md) + "\n")
    print("\n".join(md))


if __name__ == "__main__":
    main()
