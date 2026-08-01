#!/usr/bin/env python3
"""注入验收：比较 C0 vs C1（及可选 C2）rank0 step_ms 中位（measure 100–300）。

阈值按 ``--dose`` 从 dose_recipes.yaml 取对应档 ``accept_min_ratio``
（loud≈1.3 / quiet≈1.15 / masked≈1.05；见 dose_util.py）。

退出码：0=达标；1=未达标 / 数据不足；2=用法错误。
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path

from dose_util import normalize_dose, recipe_accept_min_ratio, resolve_recipes_path

# 无 recipes 时的 Loud 历史硬编码（仅 fallback）
DEFAULT_THRESH = {
    "P1-EXT-A": 1.8,
    "P1-EXT-B": 1.6,
    "P3-EXT-A": 1.3,
    "P3-EXT-B": 1.3,
    "P3-SW-A": 1.3,
}


def find_rank0(case_root: Path, cfg: str) -> Path | None:
    hits = sorted(case_root.glob(f"by_pod/*/round_1/{cfg}/ranks/rank_0000.jsonl"))
    return hits[0] if hits else None


def median_step_ms(path: Path, lo: int = 100, hi: int = 300) -> float | None:
    xs: list[float] = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            s = o.get("step")
            if s is None or not (lo <= int(s) <= hi):
                continue
            if "step_ms" in o:
                xs.append(float(o["step_ms"]))
    if not xs:
        return None
    return float(statistics.median(xs))


def injection_log_ok(case_root: Path, cfg: str = "C1_inject_none") -> str:
    logs = list(case_root.glob(f"by_pod/*/round_1/{cfg}/injection.log"))
    if not logs:
        return "no_log"
    text = logs[0].read_text(errors="replace")
    if "SIDECAR_WARMUP" in text and "SIDECAR_START" in text:
        return "warmup+start"
    if "SIDECAR_START" in text or "fio" in text.lower() or "stress-ng" in text.lower():
        return "started"
    if "inline" in text.lower():
        return "inline"
    return "log_present"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--result-root", required=True)
    ap.add_argument("--case", required=True)
    ap.add_argument(
        "--dose",
        default="loud",
        help="loud|quiet|masked；从 recipes 取该档 accept_min_ratio（可被 --min-ratio 覆盖）",
    )
    ap.add_argument(
        "--recipes",
        default="",
        help="dose_recipes.yaml 路径；默认 FS_DOSE_RECIPES 或本目录 dose_recipes.yaml",
    )
    ap.add_argument("--min-ratio", type=float, default=None,
                    help="显式阈值；若给则覆盖 recipes / dose 默认")
    ap.add_argument("--lo", type=int, default=100)
    ap.add_argument("--hi", type=int, default=300)
    ap.add_argument("--configs", default="C0_baseline,C1_inject_none,C2_probing")
    ap.add_argument("--write-md", default="")
    ap.add_argument("--ineffective-below", type=float, default=1.1,
                    help="比值低于此记 injection_ineffective（仅写表，不单独改退出码语义）")
    args = ap.parse_args()

    case = args.case
    try:
        dose = normalize_dose(args.dose)
    except ValueError as e:
        print(f"usage error: {e}", file=sys.stderr)
        return 2

    recipes_path = args.recipes or None
    if args.min_ratio is not None:
        min_ratio = float(args.min_ratio)
        thr_src = f"cli:--min-ratio={min_ratio}"
    else:
        fb = DEFAULT_THRESH.get(case) if dose == "loud" else None
        min_ratio, thr_src = recipe_accept_min_ratio(
            case, dose, recipes_path=recipes_path, fallback=fb
        )

    root = Path(args.result_root) / case
    cfgs = [c.strip() for c in args.configs.split(",") if c.strip()]
    recipes_resolved = resolve_recipes_path(recipes_path)

    meds: dict[str, float | None] = {}
    for cfg in cfgs:
        p = find_rank0(root, cfg)
        meds[cfg] = median_step_ms(p, args.lo, args.hi) if p else None

    c0 = meds.get("C0_baseline")
    c1 = meds.get("C1_inject_none")
    c2 = meds.get("C2_probing")
    ratio = (c1 / c0) if (c0 and c1 and c0 > 0) else None
    ratio2 = (c2 / c0) if (c0 and c2 and c0 > 0) else None

    if ratio is None:
        verdict = "DATA_MISSING"
        ok = False
    elif ratio >= min_ratio:
        verdict = "PASS"
        ok = True
    elif ratio < args.ineffective_below:
        verdict = "injection_ineffective"
        ok = False
    else:
        verdict = "FAIL_WEAK"
        ok = False

    inj_log = injection_log_ok(root) if root.exists() else "no_case_dir"

    lines = [
        f"# Acceptance ({dose}): {case}",
        "",
        f"- window: measure step [{args.lo}, {args.hi}] rank0 `step_ms` median",
        f"- dose: `{dose}`",
        f"- threshold C1/C0 ≥ **{min_ratio}** ({thr_src})",
        f"- recipes: `{recipes_resolved or 'n/a'}`",
        f"- injection.log: `{inj_log}`",
        f"- verdict: **{verdict}**",
        "",
        "| config | median step_ms | vs C0 |",
        "|---|---:|---:|",
    ]
    for cfg in cfgs:
        m = meds.get(cfg)
        if m is None:
            lines.append(f"| {cfg} | — | — |")
        elif cfg == "C0_baseline" or c0 is None or c0 <= 0:
            lines.append(f"| {cfg} | {m:.2f} | 1.00 |")
        else:
            lines.append(f"| {cfg} | {m:.2f} | {m/c0:.2f} |")
    lines.append("")
    lines.append(f"C1/C0 = {ratio:.3f}" if ratio is not None else "C1/C0 = n/a")
    if ratio2 is not None:
        lines.append(f"C2/C0 = {ratio2:.3f}")

    text = "\n".join(lines) + "\n"
    print(text)
    if args.write_md:
        out = Path(args.write_md)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)

    # 汇总行便于 campaign 追加
    summary = Path(args.result_root) / "acceptance_table.md"
    def fmt(x: float | None) -> str:
        return f"{x:.2f}" if x is not None else "—"

    row = (
        f"| {case} | {dose} | {fmt(c0)} | {fmt(c1)} | {fmt(c2)} | {fmt(ratio)} | "
        f"{min_ratio} | {verdict} | {inj_log} |"
    )
    header = (
        "# Acceptance table\n\n"
        "| case | dose | C0 med | C1 med | C2 med | C1/C0 | thr | verdict | inj_log |\n"
        "|---|---|---:|---:|---:|---:|---:|---|---|\n"
    )
    if summary.exists():
        prev = summary.read_text()
        # 替换同 case+dose 旧行
        kept = [
            ln for ln in prev.splitlines()
            if not ln.startswith(f"| {case} | {dose} |")
        ]
        if not any(ln.startswith("| case |") for ln in kept):
            summary.write_text(header + row + "\n")
        else:
            summary.write_text("\n".join(kept).rstrip() + "\n" + row + "\n")
    else:
        summary.write_text(header + row + "\n")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
