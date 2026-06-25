#!/usr/bin/env python3
"""Megatron-LM × Probing 矩阵报告生成器。"""
from __future__ import annotations

import re
import sys
from pathlib import Path

TC_INFO = {
    "TC01": ("gpt345m", "attach + SQL phase 耗时"),
    "TC02": ("gpt345m", "PROBING_TORCH_PROFILING + torch_trace"),
    "TC03": ("gpt126m", "memory + gpu.utilization"),
    "TC04": ("gpt345m_long", "eval 显存峰值"),
    "TC05": ("gpt345m_gbs", "大 global batch / 梯度累积 + phase SQL"),
    "TC06": ("gpt345m_tp2", "TP=2 + comm_collective"),
    "TC07": ("gpt126m_pp2", "PP=2 + backtrace"),
    "TC08": ("gpt126m_2dp", "2-GPU DP + collective"),
    "TC09": ("gpt345m", "PROBING_SPAN_BACKENDS=logger"),
    "TC10": ("gpt345m", "config + 综合 SQL"),
}


def table_rows(text: str) -> int:
    return sum(1 for l in text.splitlines() if l.startswith("│") and not l.startswith("├"))


def extract_table(text: str, limit: int = 18) -> str:
    lines = [
        l
        for l in text.splitlines()
        if l.startswith(("┌", "├", "└", "│"))
    ]
    return "\n".join(lines[:limit]) if lines else text[:600]


def parse_megatron_log(path: Path) -> dict:
    out = {"iters": [], "mem": ""}
    if not path.exists():
        return out
    for line in path.read_text(errors="replace").splitlines():
        if "iteration" in line and "lm loss" in line:
            m = re.search(r"iteration\s+(\d+)/\s*(\d+).*lm loss:\s*([\d.E+-]+)", line)
            if m:
                out["iters"].append(
                    f"iter {m.group(1)}/{m.group(2)} loss={float(m.group(3)):.4f}"
                )
        if "memory (MB)" in line:
            out["mem"] = line.strip()
    return out


def main() -> None:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    lines = [
        "# Megatron-LM × Probing 真实参数测试报告",
        "",
        f"**Megatron 路径**: `/home/yjr/work/Megatron-LM/pretrain_gpt.py`",
        f"**日志**: `{root}`",
        "",
        "## 测试矩阵",
        "",
        "| TC | Megatron 真实参数 | Probing 采集 | 状态 | loss 趋势 |",
        "|----|-------------------|--------------|------|-----------|",
    ]

    details = []
    for d in sorted(root.glob("TC*")):
        tc = d.name.split("_")[0]
        preset = d.name.split("_", 1)[1] if "_" in d.name else "?"
        info = TC_INFO.get(tc, (preset, "?"))
        status = (d / "status.txt").read_text().strip() if (d / "status.txt").exists() else "?"
        log = parse_megatron_log(d / "train.log")
        trend = log["iters"][0] + " → " + log["iters"][-1] if len(log["iters"]) >= 2 else (log["iters"][0] if log["iters"] else "N/A")
        lines.append(f"| {tc} | {info[0]} | {info[1]} | {status} | {trend} |")

        sample_file = None
        best_rows = 0
        for f in d.glob("*"):
            if f.suffix in (".sql", ".txt") and f.name not in ("status.txt", "loss_tail.txt", "train.log", "train.err"):
                rows = table_rows(f.read_text(errors="replace"))
                if rows > best_rows:
                    best_rows = rows
                    sample_file = f

        details.append(f"### {tc} — {info[0]}")
        details.append("")
        details.append(f"- **Probing**: {info[1]}")
        details.append(f"- **状态**: {status}")
        if log["mem"]:
            details.append(f"- **Megatron 显存**: `{log['mem']}`")
        if log["iters"]:
            details.append(f"- **训练**: {'; '.join(log['iters'][:3])} …")
        details.append("")
        if sample_file and best_rows:
            details.append(f"**采集 ({sample_file.name})**:")
            details.append("```")
            details.append(extract_table(sample_file.read_text(errors="replace")))
            details.append("```")
        elif (d / "train.err").exists():
            err = (d / "train.err").read_text(errors="replace").splitlines()
            details.append("```")
            details.append("\n".join(err[-8:]))
            details.append("```")
        details.append("")

    lines += ["", "## 参数对照（Megatron 官方规模）", ""]
    lines += [
        "| Preset | 结构 | 参数量级 | 来源 |",
        "|--------|------|----------|------|",
        "| gpt126m | 12L / 768H / 12 heads / seq1024 | ~130M | Megatron CI tp2_pp2 测试 |",
        "| gpt345m | 24L / 1024H / 16 heads / seq1024 | ~345M | examples/inference/345M |",
        "| gpt345m_long | 同上 seq2048 mbs1 | ~345M | 长序列压力 |",
        "| gpt345m_gbs | mbs1 gbs16 | ~345M | 梯度累积 |",
        "| gpt345m_tp2 | TP=2 | ~345M | 张量并行 |",
        "| gpt126m_pp2 | 12L/512H PP=2 | ~126M | 流水线并行 |",
        "",
        "## 结论",
        "",
        "使用 **真实 Megatron-LM `pretrain_gpt.py`** 与官方 126M/345M 参数配置，",
        "在 mock-data 模式下完成训练迭代，并通过 probing-cli 采集 phase 耗时、",
        "torch_trace 模块级 profile、显存时序、eval、backtrace、collective 等数据。",
        "",
    ]
    lines += details
    out = root / "REPORT.md"
    out.write_text("\n".join(lines), encoding="utf-8")
    print(f"Report -> {out}")


if __name__ == "__main__":
    main()
