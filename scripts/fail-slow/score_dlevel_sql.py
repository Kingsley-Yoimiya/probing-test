#!/usr/bin/env python3
"""D0–D5 判分：离线训练埋点 + C2 Probing SQL dump。

D4 规则（decisions A5）：
  - 必须先离线到 D3
  - 读 probing/query_manifest.json
  - 缺 EXT 所需表 → 停 D3，tool_probing_sql=TABLE_MISSING
  - 表在但无外部争用信号 → 停 D3，SQL_NO_EXT_EVIDENCE
  - 表在且信号命中且 grid 对 → D4
  - P3-EXT：cpu.tasks 含 stress 优先；否则 dump 同窗 host_pressure.json
    （/proc/pressure CPU rate）hit → D4（host_psi_cpu）
  - P3-SW：cpu.utilization 进程 scope 的 rss_kb 超阈或窗内明显抬升 → D4（cpu.utilization_rss）
  - P1-EXT：优先 process.gpu_users / gpu.utilization；MetaX 缺表时 dump 同窗
    mx-smi（host_gpu.json）→ D4（host_mx_smi_hbm_bw / host_mx_smi_gpu_util）
  - P1-HW-B：同窗 mx-smi → D4（host_mx_smi_hbm_bw）；格 P1-HW
绝不把 injection.log / 裸 pgrep 升为 D4。
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from score_dlevel_offline import GT, score_case  # noqa: E402


def _host_psi_evidence(root: Path, case: str, manifest: dict) -> tuple[bool, str]:
    """Read case-appropriate dump-time /proc/pressure evidence."""
    hp = manifest.get("host_pressure") or {}
    paths = list(root.glob(f"{case}/**/C2_probing/probing/host_pressure.json"))
    blob: dict = {}
    if paths:
        paths.sort(key=lambda p: (0 if "h14410" in str(p) else 1, str(p)))
        try:
            blob = json.loads(paths[0].read_text())
        except Exception as exc:  # noqa: BLE001
            return False, f"SQL_NO_EXT_EVIDENCE:host_pressure_unreadable:{exc}"
    if not blob and hp:
        blob = dict(hp)
    if not blob:
        return False, "SQL_NO_EXT_EVIDENCE:no_host_pressure"
    if blob.get("hit"):
        if case == "P3-EXT-B":
            rate = blob.get("io_some_rate_us_s")
            return True, f"host_psi_io:rate={rate}"
        if case == "P3-EXT-C":
            rate = blob.get("memory_some_rate_us_s")
            return True, f"host_psi_memory:rate={rate}"
        rate = blob.get("cpu_some_rate_us_s")
        return True, f"host_psi_cpu:rate={rate}"
    if case == "P3-EXT-B":
        rate = blob.get("io_some_rate_us_s")
        thr = blob.get("threshold_io_rate_us_s")
        return False, f"SQL_NO_EXT_EVIDENCE:host_psi_io_no_hit:rate={rate}:thresh={thr}"
    if case == "P3-EXT-C":
        rate = blob.get("memory_some_rate_us_s")
        thr = blob.get("threshold_mem_rate_us_s") or blob.get("threshold_rate_us_s")
        return False, f"SQL_NO_EXT_EVIDENCE:host_psi_memory_no_hit:rate={rate}:thresh={thr}"
    rate = blob.get("cpu_some_rate_us_s")
    thr = blob.get("threshold_cpu_rate_us_s")
    return False, f"SQL_NO_EXT_EVIDENCE:host_psi_no_hit:rate={rate}:thresh={thr}"


def _host_gpu_evidence(root: Path, case: str, manifest: dict) -> tuple[bool, str]:
    """MetaX：dump 同窗 mx-smi（host_gpu.json），绕过缺失的 gpu.utilization。"""
    hg = manifest.get("host_gpu") or {}
    paths = list(root.glob(f"{case}/**/C2_probing/probing/host_gpu.json"))
    blob: dict = {}
    if paths:
        paths.sort(key=lambda p: (0 if "h14410" in str(p) else 1, str(p)))
        try:
            blob = json.loads(paths[0].read_text())
        except Exception as exc:  # noqa: BLE001
            return False, f"SQL_NO_EXT_EVIDENCE:host_gpu_unreadable:{exc}"
    if not blob and hg:
        blob = dict(hg)
    if not blob:
        return False, "SQL_NO_EXT_EVIDENCE:no_host_gpu"
    evid = str(blob.get("evidence") or "host_mx_smi")
    if blob.get("hit"):
        if case in ("P1-EXT-B", "P1-HW-B"):
            return True, f"{evid}:hbm_bw_mbs={blob.get('hbm_bw_mbs')}"
        return True, (
            f"{evid}:util={blob.get('gpu_util_pct')}"
            f":n_procs={blob.get('n_procs')}"
        )
    if case in ("P1-EXT-B", "P1-HW-B"):
        return False, (
            f"SQL_NO_EXT_EVIDENCE:{evid}"
            f":hbm_bw_mbs={blob.get('hbm_bw_mbs')}"
            f":thresh={blob.get('threshold_hbm_bw_mbs')}"
        )
    return False, (
        f"SQL_NO_EXT_EVIDENCE:{evid}"
        f":util={blob.get('gpu_util_pct')}"
        f":thresh={blob.get('threshold_gpu_util_pct')}"
    )


def load_manifest(root: Path, case: str) -> dict | None:
    paths = list(root.glob(f"{case}/by_pod/*/round_*/C2_probing/probing/query_manifest.json"))
    if not paths:
        paths = list(root.glob(f"{case}/**/C2_probing/probing/query_manifest.json"))
    if not paths:
        return None
    paths.sort(key=lambda p: (0 if "h14410" in str(p) else 1, str(p)))
    return json.loads(paths[0].read_text())


def read_query_ok(root: Path, case: str, name: str) -> tuple[bool, str]:
    paths = list(root.glob(f"{case}/**/C2_probing/probing/query_{name}.txt"))
    if not paths:
        return False, "missing_file"
    text = paths[0].read_text(errors="ignore")
    if "error=" in text or "not found" in text.lower() or "QueryError" in text:
        return False, text[-400:]
    lines = [l for l in text.splitlines() if l.strip() and not l.startswith("SQL:") and l != "----"]
    return (len(lines) > 2), text[:800]


def ext_evidence(case: str, manifest: dict, root: Path) -> tuple[bool, str]:
    present = manifest.get("tables_present") or {}
    missing = manifest.get("tables_missing") or []

    if case.startswith("P1-EXT") or case == "P1-HW-B":
        # 理想路径：Probing GPU 表
        if present.get("process.gpu_users"):
            ok, _ = read_query_ok(root, case, "process_gpu_users")
            return (ok, "process.gpu_users_rows" if ok else "process.gpu_users_empty")
        if present.get("gpu.utilization"):
            ok, snippet = read_query_ok(root, case, "gpu_util")
            if ok and re.search(r"\b([5-9]\d|100)(\.\d+)?\b", snippet):
                return True, "gpu.utilization_high"
            # 表在但行弱：仍可回落 mx-smi
        # MetaX 旁路：同窗 mx-smi（CudaBackend 起不来时表永不出现）
        # P1-HW-B / P1-EXT-B：host_mx_smi_hbm_bw；P1-EXT-A：host_mx_smi_gpu_util
        hg_hit, hg_note = _host_gpu_evidence(root, case, manifest)
        if hg_hit:
            return True, hg_note
        if present.get("gpu.utilization"):
            return False, hg_note or "SQL_NO_EXT_EVIDENCE:gpu.utilization_present_but_weak"
        miss = [t for t in ("gpu.utilization", "process.gpu_users") if not present.get(t)]
        if hg_note and "no_host_gpu" not in hg_note:
            return False, hg_note
        return False, "TABLE_MISSING:" + ",".join(miss)

    if case.startswith("P3-EXT"):
        # 优先 process.cpu_stats / cpu.tasks 指名 stress
        if present.get("process.cpu_stats"):
            ok, snippet = read_query_ok(root, case, "process_cpu_stats")
            if ok and re.search(r"stress", snippet, re.I):
                return True, "process.cpu_stats_stress"
        for qname in ("p3_cpu_tasks_stress", "cpu_tasks"):
            ok, snippet = read_query_ok(root, case, qname)
            if ok and re.search(r"stress", snippet, re.I):
                return True, f"{qname}_stress"
        # 其次：dump 同窗 host PSI（P3-EXT-A=CPU，P3-EXT-B=IO）
        hp_hit, hp_note = _host_psi_evidence(root, case, manifest)
        if hp_hit:
            return True, hp_note
        if present.get("cpu.tasks") or present.get("cpu.utilization") or hp_note:
            return False, hp_note or "SQL_NO_EXT_EVIDENCE:no_stress_in_cpu.tasks"
        return False, "TABLE_MISSING:process.cpu_stats,cpu.tasks,cpu.utilization"

    if case.startswith("P1-SW"):
        # 2A 碎片化：探索冻结指望 cuda_frag_gap 趋势；实测 C1−C0 gap 常为 0
        # （reserved−alloc 基线已高）。MetaX 缺 gpu.* 表；mx-smi 非 2A 主证
        # （host_mx_smi_unused）。无合法 Probing SQL/旁路升 D4 → 停 D3+dump。
        # 2C tip：compile one-shot 无稳定 SQL 根因表；dump 后续常 connection closed。
        # 勿记 ENV-BLOCKED（工具未接入≠环境封死）。
        hg = manifest.get("host_gpu") or {}
        qstat = manifest.get("query_status") or {}
        sql_closed = any("connection closed" in str(v).lower() or "query_rc_1" in str(v) for v in qstat.values())
        gap_note = "gap_flat_expected" if case == "P1-SW-A" else "tip_no_sql_rootcause"
        if case == "P1-SW-B":
            # rare shape：训练埋点 shape_seq 可到 D3；无稳定 SQL/旁路升 D4
            # （mx-smi unused；缺 gpu 表；非 PSI/RSS 路径）
            gap_note = "rare_shape_no_sql_rootcause"
        if case == "P1-SW-C":
            gap_note = "tip_no_sql_rootcause"
            if sql_closed:
                gap_note += ":sql_connection_closed"
        if hg.get("evidence"):
            gap_note += f":host_gpu={hg.get('evidence')}"
        miss = [t for t in ("gpu.utilization", "process.gpu_users") if not present.get(t)]
        if miss:
            return False, f"SQL_NO_EXT_EVIDENCE:p1sw_no_d4_path:{gap_note}:missing={','.join(miss)}"
        return False, f"SQL_NO_EXT_EVIDENCE:p1sw_no_d4_path:{gap_note}"

    if case.startswith("P2-SW"):
        # P2-SW-B：主证 Loud=comm_ratio+标定；D4 期望 python.comm_collective 时长抬升归因。
        # P2-SW-C（topo_5c）：主证 Loud=step；tables 可见 comm_collective / rdma.mlx_hca，
        # 但 dump 无 duration / HCA-order 归因查询；mx-smi/PSI 非 P2 主证。
        # 表在 ≠ 根因证据 → 停 D3；勿 ENV-BLOCKED。
        tables_txt = list(root.glob(f"{case}/**/C2_probing/probing/tables.txt"))
        has_comm = False
        has_mlx = False
        if tables_txt:
            blob = tables_txt[0].read_text(errors="ignore")
            has_comm = "comm_collective" in blob
            has_mlx = "mlx_hca" in blob
        hg = manifest.get("host_gpu") or {}
        if case == "P2-SW-C":
            note = "topo_5c_no_sql_rootcause"
            if has_comm:
                note += ":comm_collective_present_no_duration_query"
            if has_mlx:
                note += ":mlx_hca_present_no_order_query"
        else:
            note = "comm_collective_present_no_duration_query" if has_comm else "comm_collective_not_listed"
        if hg.get("evidence"):
            note += f":host_gpu={hg.get('evidence')}"
        return False, f"SQL_NO_EXT_EVIDENCE:p2sw_no_d4_path:{note}"

    if case.startswith("P3-SW"):
        # 训练进程内泄漏：Probing 无 process.memory；用 cpu.utilization.rss_kb
        # 绝对阈（~700 MiB）或窗内抬升（≥50 MiB）均可；短 dump 窗常达不到绝对阈
        if not present.get("cpu.utilization"):
            return False, "TABLE_MISSING:cpu.utilization"
        rss_thr_kb = 700_000
        rss_rise_thr_kb = 50_000
        last_low = ""
        for qname in ("p3sw_rss_window", "cpu_util"):
            paths = list(root.glob(f"{case}/**/C2_probing/probing/query_{qname}.txt"))
            if not paths:
                continue
            paths.sort(key=lambda p: (0 if "C2_probing/probing" in str(p).replace("by_pod", "") else 1, str(p)))
            # 必须读全文：read_query_ok 截断 800 字会丢掉窗末低 rss，抬升假阴性
            snippet = paths[0].read_text(errors="ignore")
            if "error=" in snippet or "not found" in snippet.lower() or "QueryError" in snippet:
                continue
            # 列序 A（p3sw_rss_window）：ts | scope | rss_kb | ...
            rss_cands = [
                int(x)
                for x in re.findall(
                    r"│\s*\d+\s*│\s*process\s*│\s*(\d{5,})\s*│",
                    snippet,
                )
            ]
            if not rss_cands:
                # 列序 B（cpu_util）：ts | scope | cpu_pct | rss_kb | ...
                rss_cands = [
                    int(x)
                    for x in re.findall(
                        r"│\s*\d+\s*│\s*process\s*│\s*[\d.]+\s*│\s*(\d{5,})\s*│",
                        snippet,
                    )
                ]
            if not rss_cands:
                continue
            mx, mn = max(rss_cands), min(rss_cands)
            if mx >= rss_thr_kb:
                return True, f"cpu.utilization_rss:max_kb={mx}:{qname}"
            rise = mx - mn
            if rise >= rss_rise_thr_kb:
                return True, (
                    f"cpu.utilization_rss:rise_kb={rise}"
                    f":max_kb={mx}:min_kb={mn}:{qname}"
                )
            last_low = (
                f"SQL_NO_EXT_EVIDENCE:rss_low:max_kb={mx}"
                f":rise_kb={rise}:thr={rss_thr_kb}:rise_thr={rss_rise_thr_kb}"
            )
        return False, last_low or "SQL_NO_EXT_EVIDENCE:cpu.utilization_rss_unparsed"

    _ = missing
    return False, "unsupported_case"


def score_with_sql(root: Path, case: str, dose: str) -> dict:
    base = score_case(root, case, dose)
    # normalize d_level to int then string label
    d_num = int(base.get("d_level") or 0)
    manifest = load_manifest(root, case)
    notes = [base.get("notes") or ""]

    if manifest is None:
        base["tool_probing_sql"] = "SQL_PENDING"
        notes.append("D4_pending: no probing/query_manifest.json")
        base["notes"] = "; ".join(x for x in notes if x)
        base["d_level"] = f"D{d_num}"
        return base

    missing = manifest.get("tables_missing") or []
    base["tool_probing_sql"] = "DUMP_OK"
    notes.append("sql_dump=ok")
    if missing:
        notes.append("tables_missing=" + ",".join(missing))

    if d_num < 3:
        notes.append(f"D4_skipped: offline_d_level=D{d_num}")
        base["notes"] = "; ".join(x for x in notes if x)
        base["d_level"] = f"D{d_num}"
        return base

    hit, evid = ext_evidence(case, manifest, root)
    notes.append(evid)
    if evid.startswith("TABLE_MISSING"):
        base["tool_probing_sql"] = "TABLE_MISSING"
        base["notes"] = "; ".join(x for x in notes if x)
        base["d_level"] = "D3"
        return base
    if not hit:
        base["tool_probing_sql"] = "SQL_NO_EXT_EVIDENCE"
        base["notes"] = "; ".join(x for x in notes if x)
        base["d_level"] = "D3"
        return base

    grid = GT.get(case, {}).get("grid", "")
    base["d_level"] = "D4"
    base["grid_reported"] = grid
    base["tool_probing_sql"] = "PASS_D4"
    notes.append(f"D4 grid={grid}")
    base["notes"] = "; ".join(x for x in notes if x)
    return base


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--result-root", required=True)
    ap.add_argument("--cases", default="P1-EXT-A,P1-EXT-B,P3-EXT-A")
    ap.add_argument("--dose", default="Loud")
    args = ap.parse_args()
    root = Path(args.result_root)
    run_id = root.name
    cases = [c.strip() for c in args.cases.split(",") if c.strip()]

    rows = []
    for case in cases:
        r = score_with_sql(root, case, args.dose)
        r["run_id"] = run_id
        r["case"] = r.get("case_id", case)
        rows.append(r)

    csv_path = root / f"scoring_table_SQL_{args.dose}.csv"
    fields = [
        "run_id", "dose", "case", "d_level", "c1_c0", "target_reported", "target_truth",
        "grid_reported", "grid_truth", "tool_probing_sql", "tool_greyhound", "tool_xputimer", "notes",
    ]
    with csv_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow(r)

    md = [f"# Verdict SQL — {run_id} ({args.dose})", ""]
    md.append("| case | C1/C0 | d_level | SQL | notes |")
    md.append("|---|---:|---|---|---|")
    for r in rows:
        note = (r.get("notes") or "")[:140].replace("|", "/")
        md.append(
            f"| {r['case']} | {r.get('c1_c0') or '—'} | **{r['d_level']}** | "
            f"{r['tool_probing_sql']} | {note} |"
        )
    md.append("")
    md.append("- 主证据：C2 `probing/query_manifest.json`；训练 jsonl 仅离线验证到 D3。")
    md.append("- Greyhound / XPUTimer = PENDING（见 ledger §3.2；未接入≠D0，也未定谳 ENV-BLOCKED）。")
    md.append(f"- CSV: `{csv_path}`")
    (root / f"VERDICT_SQL_{args.dose}.md").write_text("\n".join(md) + "\n")
    print("\n".join(md))


if __name__ == "__main__":
    main()
