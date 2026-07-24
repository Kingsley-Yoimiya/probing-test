#!/usr/bin/env python3
"""pull_and_score_swb.py — 从 8 pod 拉 ranks 并算 C1/C0 中位比。"""
from __future__ import annotations

import json
import statistics
import subprocess
import sys
from pathlib import Path


def kubectl_tar(pod: str, remote_dir: str, dest: Path) -> bool:
    dest.mkdir(parents=True, exist_ok=True)
    cmd = [
        "kubectl", "--request-timeout=60s", "-n", "default", "exec", pod, "--",
        "bash", "-c", f"tar -C '{remote_dir}' -cf - .",
    ]
    try:
        raw = subprocess.check_output(cmd, stderr=subprocess.DEVNULL)
    except Exception:
        return False
    tar = dest / ".t.tar"
    tar.write_bytes(raw)
    subprocess.run(["tar", "-C", str(dest), "-xf", str(tar)], check=False)
    tar.unlink(missing_ok=True)
    return True


def medians(ranks_dir: Path, lo=100, hi=300):
    steps, comms = [], []
    for f in ranks_dir.glob("rank_*.jsonl"):
        for line in f.open():
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            if lo <= int(o.get("step", -1)) < hi:
                steps.append(float(o["step_ms"]))
                comms.append(float(o.get("comm_ms") or 0))
    if not steps:
        return None
    return {
        "n": len(steps),
        "step_med": statistics.median(steps),
        "comm_med": statistics.median(comms),
        "files": len(list(ranks_dir.glob("rank_*.jsonl"))),
    }


def main() -> int:
    case = sys.argv[1] if len(sys.argv) > 1 else "P2-SW-B"
    run_id = sys.argv[2] if len(sys.argv) > 2 else "20260724_171825-swb64-p2-s512"
    pods = [
        "yjr-swb-h145231", "yjr-swb-h145230", "yjr-swb-h144222", "yjr-swb-h145219",
        "yjr-swb-h144217", "yjr-swb-h145217", "yjr-swb-h145216", "yjr-swb-h144215",
    ]
    root = Path(f"/Users/yinjinrun/Codespace/myportal/results/muxi-h3c/{run_id}/{case}/round_1")
    for cfg in ("C0_baseline", "C1_inject_none", "C2_probing"):
        ranks = root / cfg / "ranks"
        ranks.mkdir(parents=True, exist_ok=True)
        for pod in pods:
            remote = f"/workspace/probe-bundle/swb/out/{case}/round_1/{cfg}/ranks"
            kubectl_tar(pod, remote, ranks)
        m = medians(ranks)
        print(cfg, m)
    c0 = medians(root / "C0_baseline" / "ranks")
    c1 = medians(root / "C1_inject_none" / "ranks")
    if c0 and c1 and c0["step_med"] > 0:
        out = {
            "case": case,
            "run_id": run_id,
            "c0": c0,
            "c1": c1,
            "step_ratio": c1["step_med"] / c0["step_med"],
            "comm_ratio": (c1["comm_med"] / c0["comm_med"]) if c0["comm_med"] > 0 else None,
        }
        path = root.parent / "verdict_ratio.json"
        path.write_text(json.dumps(out, indent=2))
        print("WROTE", path)
        print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
