#!/usr/bin/env python3
"""Baseline 覆盖率矩阵汇总：把各 baseline 的 per-case verdict 分流成两张表。

- 表 A · 在线自主检出覆盖率（M/27 口径）：Probing / Greyhound / XPUTimer / Flight Recorder
- 表 B · oracle 触发诊断深度 + 代价：Dynolog+HTA（不进检出率分母）

设计依据：`COVERAGE_MATRIX_PLAN.md`、`docs/fail-slow/rules.md` §三·五 B。

**红线 2 说明**：本文件内建的是每个 baseline 的**工具能力事实**（触发类型 autonomous/
oracle、结构上采不采某类信号）——这些对所有 case 一视同仁，不含任何 case 的答案
（注入窗 / target rank / PID）。哪个 case 属哪格（P1/P2/P3）是故障**分类**、非检测答案。

用法:
  # 各 baseline 产出 per-case verdict jsonl（字段见 PLAN §4）后：
  python3 baseline_coverage_matrix.py --verdict-glob 'results/ascend-ais/**/coverage_row.jsonl' \\
      --out results/ascend-ais/baseline/COVERAGE_MATRIX.md
  # 无输入时打印骨架（占位表 + 能力矩阵），便于先对齐口径
  python3 baseline_coverage_matrix.py --skeleton --out /tmp/cov.md
"""
from __future__ import annotations

import argparse
import glob
import json
from pathlib import Path

# ---- 27-case 网格：P{1,2,3} × {HW,SW,EXT} × {A,B,C} ----
FAMILIES = ["P1", "P2", "P3"]
KINDS = ["HW", "SW", "EXT"]
SLOTS = ["A", "B", "C"]
ALL_CASES = [f"{p}-{k}-{s}" for p in FAMILIES for k in KINDS for s in SLOTS]  # 27

# ---- baseline 能力事实（capability，非 case 答案）----
# trigger: autonomous=自主检出（进表 A）；oracle=已知故障后触发（进表 B，不算检出率）
# covers_families: 结构上能采到信号的族；不在此列 = structural_na（不是 D0）
# d_cap: 归因深度上界（outline §5.7），仅作报告标注
BASELINES = {
    "Probing": {
        "trigger": "autonomous",
        "covers_families": ["P1", "P2", "P3"],
        "d_cap": "D4-D5",
        "note": "本系统；分离判断/归因",
    },
    "Greyhound": {
        "trigger": "autonomous",
        "covers_families": ["P1", "P2", "P3"],  # 采得到，但无 PID/温频 → 深度受限
        "d_cap": "D3",
        "note": "训中变点+主动验证；无 PID/温频",
    },
    "XPUTimer": {
        "trigger": "autonomous",
        "covers_families": ["P1", "P2", "P3"],
        "d_cap": "D0-D1",
        "note": "只采信号；自动 RCA 未开源",
    },
    "FlightRecorder": {
        "trigger": "autonomous",
        "covers_families": ["P2"],  # 只 collective 元数据 → P1/P3 结构盲区
        "d_cap": "D1",
        "note": "极轻极窄；只 hang/desync，P1/P3 结构上看不到",
    },
    "Dynolog+HTA": {
        "trigger": "oracle",  # → 只进表 B
        "covers_families": ["P1", "P2", "P3"],
        "d_cap": "D3-D4(事后)",
        "note": "极深极贵；常驻 +20~44% 且 OOM；人触发",
    },
}

# coverage_status 取值（PLAN §4）
STATUS_DETECTED = "detected"        # 自主检出（进分子，看 d_level）
STATUS_D0 = "d0_no_bite"            # 跑了但没检出（进分母，D0）
STATUS_NA = "structural_na"         # 结构盲区：这类信号它不采（进分母记 N/A，≠D0）
STATUS_PENDING = "env_pending"      # 接入未趟通（红线 5：≠D0，≠ENV-BLOCKED 定谳）


def case_family(case_id: str) -> str:
    return case_id.split("-")[0]


def default_status(tool: str, case_id: str) -> str:
    """无 verdict 输入时，按能力事实给占位状态：不覆盖的族→N/A，其余→pending。"""
    fam = case_family(case_id)
    if fam not in BASELINES[tool]["covers_families"]:
        return STATUS_NA
    return STATUS_PENDING


def load_rows(verdict_glob: str) -> list[dict]:
    rows = []
    for p in glob.glob(verdict_glob, recursive=True):
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    rows.append(json.loads(line))
        except (OSError, json.JSONDecodeError):
            continue
    return rows


def build_grid(rows: list[dict]) -> dict[str, dict[str, dict]]:
    """{tool: {case_id: row}}；缺的格用能力事实补占位。"""
    grid: dict[str, dict[str, dict]] = {t: {} for t in BASELINES}
    for r in rows:
        tool = r.get("tool")
        case = r.get("case_id")
        if tool in grid and case in ALL_CASES:
            grid[tool][case] = r
    for tool in BASELINES:
        for case in ALL_CASES:
            if case not in grid[tool]:
                grid[tool][case] = {
                    "tool": tool,
                    "case_id": case,
                    "grid": case_family(case),
                    "trigger_type": BASELINES[tool]["trigger"],
                    "coverage_status": default_status(tool, case),
                    "d_level": "NA" if default_status(tool, case) == STATUS_NA else "",
                    "post_trigger_d_level": "",
                    "notes": "占位（无 verdict 输入）",
                }
    return grid


def coverage_numerator(grid: dict, tool: str) -> tuple[int, int, int]:
    """返回 (检出且定位到根因层≥D3 的数, 参与分母的格数, 结构N/A格数)。

    分子 = coverage_status=detected 且 d_level>=3（对齐 M/27 的"检出并定位"）。
    分母 = 27 - 结构N/A（N/A 不算它失败，也不算它成功——那类它不采）。
    """
    num = na = 0
    for case in ALL_CASES:
        row = grid[tool].get(case, {})
        st = row.get("coverage_status")
        if st == STATUS_NA:
            na += 1
            continue
        dl = row.get("d_level")
        try:
            if st == STATUS_DETECTED and int(dl) >= 3:
                num += 1
        except (TypeError, ValueError):
            pass
    denom = len(ALL_CASES) - na
    return num, denom, na


def render(grid: dict, out: str) -> None:
    A_tools = [t for t in BASELINES if BASELINES[t]["trigger"] == "autonomous"]
    B_tools = [t for t in BASELINES if BASELINES[t]["trigger"] == "oracle"]

    md = ["# Baseline 覆盖率矩阵（双表分列）", ""]
    md.append("> 自动生成。口径见 `COVERAGE_MATRIX_PLAN.md`。N/A=结构盲区（不采该类信号）≠ D0。")
    md.append("> oracle 触发工具不进表 A 检出率，只进表 B。")
    md.append("")

    # ---- 能力矩阵（先摆客观事实）----
    md.append("## 能力矩阵（工具事实，非 case 答案）")
    md.append("")
    md.append("| tool | 触发 | 覆盖族 | 深度上界 | 备注 |")
    md.append("|---|---|---|---|---|")
    for t, c in BASELINES.items():
        md.append(
            f"| {t} | {c['trigger']} | {','.join(c['covers_families'])} "
            f"| {c['d_cap']} | {c['note']} |"
        )
    md.append("")

    # ---- 表 A ----
    md.append("## 表 A · 在线自主检出覆盖率（M/27 口径）")
    md.append("")
    md.append("| tool | 检出定位(≥D3) | 分母 | 结构N/A | 覆盖率 |")
    md.append("|---|---:|---:|---:|---|")
    for t in A_tools:
        num, denom, na = coverage_numerator(grid, t)
        frac = f"{num}/{denom}" + (f"（+{na} N/A）" if na else "")
        md.append(f"| {t} | {num} | {denom} | {na} | **{frac}** |")
    md.append("")
    md.append("> Flight Recorder 覆盖率按 P2-only 读；P1/P3 计入 N/A 而非 D0。")
    md.append("")

    # ---- 表 A 明细（逐格）----
    md.append("### 表 A 逐格明细")
    md.append("")
    md.append("| case | " + " | ".join(A_tools) + " |")
    md.append("|---|" + "---|" * len(A_tools))
    for case in ALL_CASES:
        cells = []
        for t in A_tools:
            row = grid[t].get(case, {})
            st = row.get("coverage_status", "")
            dl = row.get("d_level", "")
            if st == STATUS_NA:
                cells.append("N/A")
            elif st == STATUS_DETECTED:
                cells.append(f"D{dl}")
            elif st == STATUS_D0:
                cells.append("D0")
            elif st == STATUS_PENDING:
                cells.append("pend")
            else:
                cells.append(str(dl or "-"))
        md.append(f"| {case} | " + " | ".join(cells) + " |")
    md.append("")

    # ---- 表 B ----
    md.append("## 表 B · oracle 触发诊断深度 + 代价（不进检出率）")
    md.append("")
    md.append("| tool | case | 触发后诊断(D) | 常驻开销% | onset前空白 | notes |")
    md.append("|---|---|---|---|---|---|")
    for t in B_tools:
        for case in ALL_CASES:
            row = grid[t].get(case, {})
            if row.get("coverage_status") == STATUS_NA:
                continue
            ptd = row.get("post_trigger_d_level", "")
            cost = row.get("resident_overhead_pct", "")
            gap = row.get("onset_gap", "")
            note = str(row.get("notes", ""))[:40]
            if ptd == "" and row.get("coverage_status") == STATUS_PENDING:
                continue  # 占位空行不铺满
            md.append(f"| {t} | {case} | {ptd} | {cost} | {gap} | {note} |")
    md.append("")
    md.append("> Dynolog+HTA：oracle 触发（已知故障后短开 profiling），只比触发后诊断深度 + 代价；"
              "不声称自主检出率（rules §三·五 B）。")
    md.append("")

    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_text("\n".join(md) + "\n", encoding="utf-8")
    print("\n".join(md))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verdict-glob", default="", help="各 baseline per-case verdict jsonl（PLAN §4 schema）")
    ap.add_argument("--skeleton", action="store_true", help="无输入，打印占位骨架")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    rows = [] if args.skeleton else load_rows(args.verdict_glob)
    if not rows and not args.skeleton:
        print("[warn] no verdict rows matched; rendering skeleton. 用 --skeleton 显式生成占位。")
    grid = build_grid(rows)
    render(grid, args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
