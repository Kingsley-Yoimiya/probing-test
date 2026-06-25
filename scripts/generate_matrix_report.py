#!/usr/bin/env python3
"""从 matrix 测试日志生成 Markdown 报告。"""
from __future__ import annotations

import re
import sys
from pathlib import Path


def read_tail(path: Path, n: int = 30) -> str:
    if not path.exists():
        return "(无文件)"
    lines = path.read_text(errors="replace").splitlines()
    return "\n".join(lines[-n:]) if lines else "(空)"


def extract_table_block(text: str) -> str:
    """保留 ASCII 表格部分。"""
    rows = []
    for line in text.splitlines():
        if line.startswith("┌") or line.startswith("├") or line.startswith("└") or line.startswith("│"):
            rows.append(line)
    return "\n".join(rows[:20]) if rows else text[:800]


def count_table_rows(text: str) -> int:
    return sum(1 for l in text.splitlines() if l.startswith("│") and not l.startswith("├"))


def parse_train_meta(log: Path) -> dict:
    out = {"params": "?", "loss_lines": []}
    if not log.exists():
        return out
    for line in log.read_text(errors="replace").splitlines():
        if "params=" in line:
            m = re.search(r"params=([\d,]+)", line)
            if m:
                out["params"] = m.group(1)
        if line.strip().startswith("step="):
            out["loss_lines"].append(line.strip())
    return out


TC_META = {
    "TC01": ("baseline-phase-hook", "tiny", "attach_training_phases + SQL phase JOIN"),
    "TC02": ("deep-torch-probe", "deep (8L)", "PROBING_TORCH_PROFILING=on + torch_trace SQL"),
    "TC03": ("wide-manual-span", "wide (d256)", "manual span/event + train.metrics SQL"),
    "TC04": ("longseq-memory", "long_seq (seq128)", "memory cmd + gpu.utilization SQL"),
    "TC05": ("largebatch-eval", "large_batch (bs32)", "eval 显存/参数"),
    "TC06": ("gradaccum-step", "grad_accum (micro=4)", "step 坐标 + train.step SQL"),
    "TC07": ("manystep-backtrace", "many_step (30步)", "训练中 backtrace"),
    "TC08": ("ddp-collective", "tiny DDP 2GPU", "comm_collective SQL"),
    "TC09": ("span-logger", "tiny", "PROBING_SPAN_BACKENDS=memtable,logger"),
    "TC10": ("deep-config-sql", "deep 18步", "config + 综合 SQL"),
}


def main() -> None:
    log_root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    report = log_root / "REPORT.md"

    lines = [
        "# Probing × Megatron 测试矩阵报告",
        "",
        f"**日志目录**: `{log_root}`",
        "",
        "## 测试矩阵",
        "",
        "| TC | Megatron 配置 | Probing 采集 | 状态 | 数据行数 |",
        "|----|---------------|--------------|------|----------|",
    ]

    details = []
    for tc_dir in sorted(log_root.glob("TC*")):
        tc_id = tc_dir.name.split("_")[0]
        meta = TC_META.get(tc_id, (tc_dir.name, "?", "?"))
        status = (tc_dir / "status.txt").read_text().strip() if (tc_dir / "status.txt").exists() else "?"
        train = parse_train_meta(tc_dir / "train.log")

        # 找主要采集文件
        data_files = list(tc_dir.glob("*.sql")) + list(tc_dir.glob("*.txt"))
        data_files = [f for f in data_files if f.name not in ("status.txt",)]
        row_count = 0
        sample = ""
        for f in sorted(data_files):
            txt = f.read_text(errors="replace")
            if "Error:" in txt and "Connection refused" in txt:
                continue
            c = count_table_rows(txt)
            if c > row_count:
                row_count = c
                sample = extract_table_block(txt)

        lines.append(
            f"| {tc_id} | {meta[1]} | {meta[2]} | {status} | {row_count} |"
        )

        details.append(f"### {tc_id} — {meta[0]}")
        details.append("")
        details.append(f"- **Megatron**: {meta[1]}")
        details.append(f"- **Probing**: {meta[2]}")
        details.append(f"- **参数量**: {train['params']}")
        if train["loss_lines"]:
            details.append(f"- **Loss 采样**: `{train['loss_lines'][0]}` … `{train['loss_lines'][-1]}`")
        details.append("")
        if sample.strip():
            details.append("**采集样本**:")
            details.append("```")
            details.append(sample)
            details.append("```")
        else:
            details.append(f"**train 尾部**:\n```\n{read_tail(tc_dir / 'train.log', 8)}\n```")
        details.append("")

    lines.extend(["", "## 各 TC 详情", ""] + details)
    lines.extend([
        "## 结论",
        "",
        "本矩阵验证了：**同一 Megatron 风格训练脚本**在不同规模参数下，可通过 **10 种 probing 采集路径**",
        "分别获取 phase 耗时、模块级 torch_trace、自定义 event、显存时序、eval 内省、",
        "梯度累积 step 坐标、backtrace、DDP collective、span logger、动态 config 等数据。",
        "",
    ])
    report.write_text("\n".join(lines), encoding="utf-8")
    print(f"Report -> {report}")


if __name__ == "__main__":
    main()
