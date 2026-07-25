#!/usr/bin/env python3
"""Dynolog+Profiler+HTA S4 verdict 骨架：per-case coverage_row.jsonl（喂 baseline_coverage_matrix）。

Dynolog+HTA = trade-off "极深极贵" 极点：全栈 kernel 级 profiling，但常驻 +20~44% 且 OOM，
Meta 实践是**按需触发几秒**。→ 触发类型 = **oracle**（rules §三·五 B）：
  - **不产自主检出率**（不进覆盖率表 A 的 M/27 分子/分母）。
  - 只比两轴：① 触发后 HTA 事后诊断能到 D 几（预期 D3–D4）；② 代价（常驻开销% / onset 前空白）。

**触发协议（oracle，写死）**：用 case 已知注入窗之后按需开 profiling 几秒。
  注入窗**只用于触发采集时机**，不进任何检出判定——本工具本就不声称自主检出。
  （这与红线 2 不冲突：不是把答案焊进"检测"，而是如实标注它靠 oracle 触发。）

用法（离线喂已回拉的 kineto/msprof trace + HTA 解析结果）:
  python3 s4_verdict.py --case P2-SW-B --hta-out <dir> --resident-overhead-pct 33 \\
      --out-row results/ascend-ais/baseline/dynolog/<run>/coverage_row.jsonl
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

TOOL = "Dynolog+HTA"


def case_family(case_id: str) -> str:
    return case_id.split("-")[0]


def parse_hta(hta_out: str) -> dict:
    """读 HTA 事后分解结果（骨架）。真实接入对齐 HTA temporal breakdown 输出：
    每 rank 的 compute/comm/memory/idle 分解 → 能否指到某 rank 的某层异常。
    这里先做存在性 + 占位深度推断。"""
    info = {"has_breakdown": False, "post_trigger_d_level": "", "layers": []}
    if not hta_out or not os.path.isdir(hta_out):
        return info
    jsons = [p for p in os.listdir(hta_out) if p.endswith(".json") or p.endswith(".csv")]
    info["has_breakdown"] = len(jsons) > 0
    if info["has_breakdown"]:
        # 占位：有 breakdown → 事后可到 D3（对象层）；kernel 级细分可探 D4。
        # 真实判分：按 HTA 能否把慢分解到 compute/comm/host 某层 + 指到 rank 填 D3/D4。
        info["post_trigger_d_level"] = 3
        info["layers"] = ["compute", "comm", "memory", "idle"]
    return info


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", required=True)
    ap.add_argument("--hta-out", default="", help="HTA 事后分解输出目录（离线）")
    ap.add_argument("--resident-overhead-pct", default="", help="常驻开销实测%（若强行常驻）")
    ap.add_argument("--onset-gap", default="onset前无数据",
                    help="触发前历史空白（短窗/按需触发共性）")
    ap.add_argument("--out-row", required=True)
    args = ap.parse_args()

    hta = parse_hta(args.hta_out)
    row = {
        "tool": TOOL,
        "case_id": args.case,
        "grid": case_family(args.case),
        "trigger_type": "oracle",  # → 汇总脚本据此只放表 B，不进检出率
        "d_cap": "D3-D4(事后)",
        # oracle 触发：不产 coverage 检出，只产诊断深度 + 代价
        "coverage_status": "env_pending" if not hta["has_breakdown"] else "detected",
        "d_level": "",  # 表 A 不用它（oracle 不进检出率）
        "post_trigger_d_level": hta["post_trigger_d_level"],
        "resident_overhead_pct": args.resident_overhead_pct,
        "onset_gap": args.onset_gap,
        "notes": (
            "oracle 触发（已知故障后短开 profiling）；只比触发后诊断深度+代价，不算检出率。"
            + ("" if hta["has_breakdown"] else " 待接入 HTA breakdown（红线5：未穷尽≠blocked）")
        ),
    }

    Path(args.out_row).parent.mkdir(parents=True, exist_ok=True)
    with open(args.out_row, "a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(json.dumps(row, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
