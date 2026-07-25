#!/usr/bin/env python3
"""从 collect-min JSONL 还原 Greyhound ACF/Rbeast 所需的**真实**调用序列。

背景：Greyhound 自带 slow_detection 的两步——`find_period`（ACF 在 call_id
序列上找通信周期）与 `find_performance_drop`（在按 period 折叠的 iter 时长上
跑 Rbeast 变点）——都要求输入是**一个 rank 上真实的集合通信调用流**：
  - call_id：每次集合通信的“类别 id”，同一训练 step 内不同 collective 取不同
    id、step 间重复，ACF 才能量出“每 step 几个 collective”这个周期；
  - call_time：每次调用的真实起始时间（秒），Rbeast 据此还原每轮 iter 时长。

旧实现把 16 个 rank 的事件混在一起、且把 call_id 写成常量 0（run_s3_analyze）
或人造的 i%4（s4_verdict）——等于没让 ACF 看到任何真实周期。本模块改为：
  1. 按 pid 分 rank（collect-min 每 rank 一个 pid）；
  2. 用 (op, count) 作为 collective 的稳定签名 → 稳定 call_id（step 间同签名同 id）；
  3. call_time 用真实 t0（该 rank 的最早 t0 归零）。

这样喂给 Greyhound 的就是它论文/开源实现真正期望的输入——给对手它自己的
最佳算法。**不含任何 case 答案**（注入窗/target rank/PID 都不进来）。
"""
from __future__ import annotations

import json
from collections import defaultdict

# 本 collect 只 hook 这几类；顺序无关，签名用 (op,count) 动态建。
_COLL_OPS = ("AllReduce", "AllGather", "ReduceScatter", "Broadcast", "Reduce", "Send", "Recv")


def load_events(jsonl_path: str) -> list[dict]:
    """读 collect JSONL，返回带 op/count/pid/t0/dur_us 的事件列表（跳过坏行）。"""
    rows: list[dict] = []
    try:
        f = open(jsonl_path, encoding="utf-8", errors="replace")
    except OSError:
        return rows
    with f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            if o.get("op") in _COLL_OPS and "t0" in o:
                rows.append(o)
    return rows


def group_by_rank(rows: list[dict]) -> dict[int, list[dict]]:
    """按 pid 分组（collect-min 里每 rank 一个 pid），每组按真实 t0 排序。"""
    by_pid: dict[int, list[dict]] = defaultdict(list)
    for o in rows:
        by_pid[int(o.get("pid", 0))].append(o)
    for pid in by_pid:
        by_pid[pid].sort(key=lambda r: (float(r.get("t0", 0.0)), int(r.get("seq", 0))))
    return by_pid


def build_call_sequence(rank_rows: list[dict]) -> tuple[list[int], list[float]]:
    """把**单个 rank** 的事件流转成 (call_id, call_time)。

    call_id：对 (op, count) 签名做稳定映射（首次出现顺序编号）。同一 step 的
      各 collective 因签名不同拿到不同 id，step 间重复 → ACF 能量出 per-step 周期。
    call_time：真实 t0，减去该 rank 最早 t0（起点归零，单位秒）。
    """
    if not rank_rows:
        return [], []
    sig_to_id: dict[tuple, int] = {}
    call_id: list[int] = []
    call_time: list[float] = []
    t0_base = float(rank_rows[0].get("t0", 0.0))
    for o in rank_rows:
        sig = (o.get("op"), int(o.get("count", 0)))
        cid = sig_to_id.get(sig)
        if cid is None:
            cid = len(sig_to_id)
            sig_to_id[sig] = cid
        call_id.append(cid)
        call_time.append(float(o.get("t0", 0.0)) - t0_base)
    return call_id, call_time


def pick_busiest_rank(by_pid: dict[int, list[dict]]) -> int | None:
    """选事件最多的 rank 作代表（信息量最大；ACF 最稳）。"""
    if not by_pid:
        return None
    return max(by_pid, key=lambda pid: len(by_pid[pid]))


def sequences_per_rank(jsonl_path: str) -> dict[int, tuple[list[int], list[float]]]:
    """便捷入口：JSONL → {pid: (call_id, call_time)}，供逐 rank 分析。"""
    by_pid = group_by_rank(load_events(jsonl_path))
    return {pid: build_call_sequence(rows) for pid, rows in by_pid.items()}
