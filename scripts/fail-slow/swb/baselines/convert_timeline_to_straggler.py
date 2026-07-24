#!/usr/bin/env python3
"""convert_timeline_to_straggler.py — StragglerAnalysis 离线转换 stub。

把 train_bench_swb.jsonl 映射为最小「timeline / straggler」表。
若本机有 pyarrow/pandas 则写 parquet；否则写 CSV + 打印目标 schema TODO。

目标最小 schema（若无法满足则保留 TODO，不假装完成）:
  step:int, rank:int, event:str, dur_ms:float, category:str

用法:
  python3 convert_timeline_to_straggler.py \\
      --jsonl path/to/rank_0000.jsonl --out /tmp/straggler_timeline
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path


# StragglerAnalysis 期望的最小列（接口约定；真实库 schema 可能更宽）
TARGET_SCHEMA = [
    "step",
    "rank",
    "event",       # compute | comm | wait | data | step
    "dur_ms",
    "category",    # timeline
    "shape_seq",   # optional
]


def rows_from_jsonl(path: Path) -> list[dict]:
    out: list[dict] = []
    with path.open() as f:
        for line in f:
            if not line.strip():
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            step = int(o.get("step", -1))
            rank = int(o.get("rank", -1))
            shape = o.get("shape_seq")
            for event, key in (
                ("data", "data_ms"),
                ("compute", "compute_ms"),
                ("comm", "comm_ms"),
                ("wait", "wait_ms"),
                ("step", "step_ms"),
            ):
                if key not in o:
                    continue
                rec = {
                    "step": step,
                    "rank": rank,
                    "event": event,
                    "dur_ms": float(o[key]),
                    "category": "timeline",
                    "shape_seq": shape if shape is not None else "",
                }
                out.append(rec)
    return out


def try_write_parquet(rows: list[dict], out_base: Path) -> bool:
    try:
        import pandas as pd  # type: ignore
    except ImportError:
        return False
    df = pd.DataFrame(rows, columns=TARGET_SCHEMA)
    path = out_base.with_suffix(".parquet")
    try:
        df.to_parquet(path, index=False)
    except Exception as exc:  # noqa: BLE001 — 缺 pyarrow 等
        print(f"parquet failed ({exc}); will fall back to CSV", file=sys.stderr)
        return False
    print(f"wrote {path} rows={len(df)}")
    return True


def write_csv(rows: list[dict], out_base: Path) -> Path:
    path = out_base.with_suffix(".csv")
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=TARGET_SCHEMA)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in TARGET_SCHEMA})
    print(f"wrote {path} rows={len(rows)}")
    return path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--jsonl", default="", help="单个 rank_*.jsonl")
    ap.add_argument("--ranks-dir", default="", help="含多个 rank_*.jsonl 的目录")
    ap.add_argument("--out", required=True, help="输出路径前缀（无后缀）或 .parquet/.csv")
    ap.add_argument("--meta-out", default="", help="可选：写最小 meta yaml")
    ap.add_argument("--print-schema-only", action="store_true")
    args = ap.parse_args()

    if args.print_schema_only:
        print("TARGET_SCHEMA:", ",".join(TARGET_SCHEMA))
        print("TODO: map to upstream StragglerAnalysis parquet if column names differ")
        return 0

    paths: list[Path] = []
    if args.ranks_dir:
        paths = sorted(Path(args.ranks_dir).glob("rank_*.jsonl"))
    elif args.jsonl:
        paths = [Path(args.jsonl)]
    else:
        print("need --jsonl or --ranks-dir", file=sys.stderr)
        return 2

    rows: list[dict] = []
    for path in paths:
        if not path.is_file():
            print(f"missing {path}", file=sys.stderr)
            continue
        rows.extend(rows_from_jsonl(path))
    if not rows:
        print("no rows parsed", file=sys.stderr)
        return 1

    out_base = Path(args.out)
    if out_base.suffix in {".parquet", ".csv"}:
        out_base = out_base.with_suffix("")
    out_base.parent.mkdir(parents=True, exist_ok=True)
    if not try_write_parquet(rows, out_base):
        write_csv(rows, out_base)
        print(
            "TODO: install pandas+pyarrow for parquet; "
            "verify column names against StragglerAnalysis loader before feeding.",
            file=sys.stderr,
        )
    if args.meta_out:
        meta = Path(args.meta_out)
        meta.parent.mkdir(parents=True, exist_ok=True)
        ranks = sorted({int(r["rank"]) for r in rows if r.get("rank", -1) >= 0})
        meta.write_text(
            "world_size: {}\ndp_size: {}\npp_size: 1\ntp_size: 1\n"
            "note: stub meta for StragglerAnalysis offline path\n".format(
                len(ranks) or "null", len(ranks) or "null"
            )
        )
        print(f"wrote {meta}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
