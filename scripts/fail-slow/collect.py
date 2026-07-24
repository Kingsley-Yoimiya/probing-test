#!/usr/bin/env python3
"""collect.py — 汇总 within-step 分解数据, 出 bottleneck-frequency + wait-based 定位表。

相对旧版(只读 step_ms)的升级:
  - 读新字段 compute_ms / comm_ms / wait_ms / data_ms
  - bottleneck-frequency: 每步 argmax_rank(compute_ms), 统计各 rank 当"最慢算"的频率;
    victim rank 显著高于 1/world 均匀期望 → 穿透 AllReduce 掩蔽的空间定位证据
  - wait-based: victim 的 wait_ms 应显著低于 healthy(victim 晚到, 别人等它) → 交叉验证
  - step_ms 仍统计, 用于证明"仅看 step_ms 无法定位"(各 rank 被 barrier 拉平)

用法:
  python3 collect.py <run_dir> [--victim-node 0] [--nproc 8] [--output report.md]

目录布局(v4 pipeline):
  <run_dir>/<case>/round_<r>/<config>/ranks/rank_XXXX.jsonl
或扁平:
  <run_dir>/ranks/rank_XXXX.jsonl
"""
from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path


def load_ranks(ranks_dir: Path) -> dict[int, list[dict]]:
    per_rank: dict[int, list[dict]] = {}
    for f in sorted(ranks_dir.glob("rank_*.jsonl")):
        rid = int(f.stem.split("_")[1])
        steps = []
        for line in f.read_text().strip().split("\n"):
            if line.strip():
                try:
                    steps.append(json.loads(line))
                except json.JSONDecodeError:
                    pass  # 容忍最后一行残缺(掉机)
        if steps:
            per_rank[rid] = steps
    return per_rank


def analyze(per_rank: dict[int, list[dict]], victim_ranks: set[int]) -> dict:
    """返回一份 config 的分析结果。"""
    if not per_rank:
        return {"n_ranks": 0}
    ranks = sorted(per_rank)
    world = len(ranks)
    iters = min(len(v) for v in per_rank.values())
    has_decomp = any("compute_ms" in per_rank[r][0] for r in ranks)

    def field_mean(rank_subset, key):
        vals = [s[key] for r in rank_subset if r in per_rank for s in per_rank[r] if key in s]
        return statistics.mean(vals) if vals else 0.0

    healthy = [r for r in ranks if r not in victim_ranks]
    res = {
        "n_ranks": world, "iters": iters, "has_decomp": has_decomp,
        "victim_ranks": sorted(victim_ranks & set(ranks)),
        "step_ms_all": round(field_mean(ranks, "step_ms"), 2),
        "step_ms_victim": round(field_mean(victim_ranks, "step_ms"), 2),
        "step_ms_healthy": round(field_mean(healthy, "step_ms"), 2),
    }

    if has_decomp:
        # bottleneck-frequency: 每步谁的 compute_ms 最大
        bn_count = {r: 0 for r in ranks}
        for i in range(iters):
            row = {r: per_rank[r][i].get("compute_ms", 0) for r in ranks if i < len(per_rank[r])}
            if row:
                bn_count[max(row, key=row.get)] += 1
        res["bn_freq"] = {r: round(bn_count[r] / iters, 3) for r in ranks}
        res["uniform_expect"] = round(1.0 / world, 3)
        res["victim_bn_freq"] = round(
            statistics.mean([res["bn_freq"][r] for r in victim_ranks if r in res["bn_freq"]] or [0]), 3)
        # wait/compute 分解
        for seg in ("compute_ms", "comm_ms", "wait_ms", "data_ms"):
            res[f"{seg}_victim"] = round(field_mean(victim_ranks, seg), 3)
            res[f"{seg}_healthy"] = round(field_mean(healthy, seg), 3)
    return res


def find_configs(run_dir: Path):
    """产出 [(label, ranks_dir)]。支持嵌套 round/config 或扁平。"""
    out = []
    flat = run_dir / "ranks"
    if flat.is_dir():
        out.append((run_dir.name, flat))
        return out
    for rd in sorted(run_dir.glob("round_*")):
        for cfg in sorted(p for p in rd.iterdir() if p.is_dir()):
            rk = cfg / "ranks"
            if rk.is_dir():
                out.append((f"{rd.name}/{cfg.name}", rk))
    # 再兜底: 任意深度的 ranks/
    if not out:
        for rk in sorted(run_dir.rglob("ranks")):
            if rk.is_dir():
                out.append((str(rk.relative_to(run_dir).parent), rk))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--victim-node", type=int, default=-1, help="victim 所在 node_rank(整节点 victim)")
    ap.add_argument("--victim-rank", type=int, default=-1, help="victim 单 rank(sidecar 打单卡时用, 优先)")
    ap.add_argument("--nproc", type=int, default=8, help="每节点 GPU 数")
    ap.add_argument("--output", type=Path, default=None)
    args = ap.parse_args()

    if args.victim_rank >= 0:
        victim_ranks = {args.victim_rank}
    elif args.victim_node >= 0:
        victim_ranks = set(range(args.victim_node * args.nproc, (args.victim_node + 1) * args.nproc))
    else:
        # 默认: sidecar 打 node0 的最后一张卡 = rank (nproc-1)
        victim_ranks = {args.nproc - 1}

    configs = find_configs(args.run_dir)
    if not configs:
        print(f"No ranks/ dirs under {args.run_dir}")
        return

    lines = [f"# Within-Step 分解报告: {args.run_dir.name}", ""]
    lines.append(f"victim ranks = {sorted(victim_ranks)}")
    lines.append("")
    lines.append("## step_ms 掩蔽证据(各 config victim vs healthy 应接近 → 单看 step_ms 无法定位)")
    lines.append("")
    lines.append("| Config | ranks | iters | step_all | step_victim | step_healthy |")
    lines.append("|---|---|---|---|---|---|")
    analyses = []
    for label, rk in configs:
        a = analyze(load_ranks(rk), victim_ranks)
        analyses.append((label, a))
        if a["n_ranks"]:
            lines.append(f"| {label} | {a['n_ranks']} | {a['iters']} | {a['step_ms_all']} "
                         f"| {a['step_ms_victim']} | {a['step_ms_healthy']} |")

    # within-step 定位
    lines += ["", "## Within-step 定位证据(compute/wait 穿透掩蔽)", ""]
    lines.append("| Config | victim BN% | 均匀期望 | compute victim/healthy | wait victim/healthy | 定位? |")
    lines.append("|---|---|---|---|---|---|")
    for label, a in analyses:
        if a.get("has_decomp"):
            vbn, ue = a["victim_bn_freq"], a["uniform_expect"]
            localized = "✅" if vbn > 2 * ue else ("〜" if vbn > 1.3 * ue else "✗")
            lines.append(
                f"| {label} | {vbn:.1%} | {ue:.1%} "
                f"| {a['compute_ms_victim']}/{a['compute_ms_healthy']} "
                f"| {a['wait_ms_victim']}/{a['wait_ms_healthy']} | {localized} |")
        elif a["n_ranks"]:
            lines.append(f"| {label} | (无分解数据) | — | — | — | — |")

    # 每 config 的 per-rank BN 频率(详)
    lines += ["", "## Per-rank Bottleneck Frequency(诊断细节)", ""]
    for label, a in analyses:
        if a.get("has_decomp"):
            top = sorted(a["bn_freq"].items(), key=lambda kv: -kv[1])[:5]
            lines.append(f"- **{label}**: " + ", ".join(f"r{r}={p:.1%}" for r, p in top))

    report = "\n".join(lines)
    print(report)
    if args.output:
        args.output.write_text(report)
        print(f"\n→ {args.output}")


if __name__ == "__main__":
    main()
