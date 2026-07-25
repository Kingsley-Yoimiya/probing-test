#!/usr/bin/env python3
"""Flight Recorder S4 verdict 骨架：per-case coverage_row.jsonl（喂 baseline_coverage_matrix）。

FR = trade-off "极轻极窄" 极点：只记 collective 元数据到环形缓冲。
  - P2（通信类）：有 collective timeline → 尝试 hang/desync 定位 → 上界 D1
  - P1（芯片）/ P3（主机）：**结构盲区**，环形缓冲无此类信号 → coverage_status=structural_na
FR 是 autonomous（环形缓冲常驻），进覆盖率表 A，但 P1/P3 记 N/A 而非 D0（PLAN §1）。

**红线 2**：case 属哪族（P1/P2/P3）是故障分类；本脚本不读注入窗/rank/PID 做检测。
判分期若要核验 hang 的 rank 对不对，才读 GT（此处骨架未接）。

用法（离线喂已回拉的 FR dump）:
  python3 s4_verdict.py --case P2-SW-B --fr-dump <dir> \\
      --out-row results/ascend-ais/baseline/flight_recorder/<run>/coverage_row.jsonl
"""
from __future__ import annotations

import argparse
import glob
import json
import os
from pathlib import Path

TOOL = "FlightRecorder"


def case_family(case_id: str) -> str:
    return case_id.split("-")[0]


def parse_fr_dump(fr_dump: str) -> dict:
    """解析 FR 环形缓冲 dump（fr_trace/JSON）。骨架：统计 collective 条目、找缺失序号。

    真实接入时对齐 `fr_trace` 输出：每 rank 的 (op, seq, state) → 找哪个 rank 少了一个
    collective（hang/desync 的定位依据）。这里先做存在性 + 计数占位。
    """
    files = sorted(glob.glob(os.path.join(fr_dump, "*.json"))) + sorted(
        glob.glob(os.path.join(fr_dump, "*fr_trace*"))
    )
    n_records = 0
    ranks_seen: set[int] = set()
    for p in files:
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        entries = data if isinstance(data, list) else data.get("entries", [])
        for e in entries:
            if not isinstance(e, dict):
                continue
            n_records += 1
            if "rank" in e:
                ranks_seen.add(int(e["rank"]))
    return {"n_records": n_records, "ranks": sorted(ranks_seen), "files": len(files)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", required=True)
    ap.add_argument("--fr-dump", default="", help="FR 环形缓冲 dump 目录（离线）")
    ap.add_argument("--out-row", required=True)
    args = ap.parse_args()

    fam = case_family(args.case)
    row = {
        "tool": TOOL,
        "case_id": args.case,
        "grid": fam,
        "trigger_type": "autonomous",
        "d_cap": "D1",
    }

    if fam in ("P1", "P3"):
        # 结构盲区：FR 环形缓冲不采 compute/芯片/host 信号
        row["coverage_status"] = "structural_na"
        row["d_level"] = "NA"
        row["notes"] = f"{fam} 结构盲区：FR 只记 collective 元数据，无此类信号"
    else:  # P2
        if not args.fr_dump or not os.path.isdir(args.fr_dump):
            row["coverage_status"] = "env_pending"
            row["d_level"] = ""
            row["notes"] = "P2：待接入 FR dump（红线 5：未穷尽≠D0/blocked）"
        else:
            info = parse_fr_dump(args.fr_dump)
            if info["n_records"] <= 0:
                # env 生效但内容空 → PENDING，不伪造 D（BASELINE_PORTING §3）
                row["coverage_status"] = "env_pending"
                row["d_level"] = ""
                row["notes"] = f"P2：FR dump 空（files={info['files']}）；env 生效待确认，不记 D"
            else:
                # 骨架：有 collective 记录 → 至多 D1（hang/desync）。
                # 真实判分：若能定位到少 collective 的 rank 且 = hang → D1；纯 fail-slow(慢不挂) → D0。
                # 具体 D0/D1 判据接入后按 fr_trace 的 desync 检测填，这里先标 detected+D1 占位。
                row["coverage_status"] = "detected"
                row["d_level"] = 1
                row["notes"] = (
                    f"P2：collective records={info['n_records']} ranks={len(info['ranks'])}；"
                    "上界 D1（只能说哪个 collective 卡了）；纯 fail-slow 慢不挂应回落 D0（待判据）"
                )

    Path(args.out_row).parent.mkdir(parents=True, exist_ok=True)
    with open(args.out_row, "a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(json.dumps(row, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
