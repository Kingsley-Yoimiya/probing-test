#!/usr/bin/env python3
"""S3：用 Greyhound 自带 slow_detection（ACF + Rbeast）跑一次短窗分析。

输入：collect-min JSONL（S2 产物）或合成序列。
侧写：可选写入 Redis（对齐 control_plane 键约定的最小子集）。

用法:
  PYTHONPATH=.../Greyhound/detector \\
    python3 run_s3_analyze.py \\
      --jsonl /path/hcclprobe.collect.jsonl \\
      --redis-host 127.0.0.1 --redis-port 16379 \\
      --out /path/s3_analyze/
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path


def load_durations_from_jsonl(path: Path) -> list[float]:
    """按 pid 聚合 AllReduce，取全局按时间排序的 dur_us → 伪 call_time 序列。"""
    rows = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            o = json.loads(line)
            if o.get("op") != "AllReduce":
                continue
            rows.append(o)
    if not rows:
        raise SystemExit(f"no AllReduce rows in {path}")
    rows.sort(key=lambda r: (r.get("t0", 0.0), r.get("pid", 0), r.get("seq", 0)))
    # call_time：累积起点（秒）；call_id：固定 0 表示同一类集合通信
    call_time = []
    call_id = []
    t_cursor = 0.0
    for r in rows:
        dur_s = float(r.get("dur_us", 0.0)) * 1e-6
        call_time.append(t_cursor)
        call_id.append(0)
        t_cursor += max(dur_s, 1e-6)
    return call_id, call_time


def synthesize_with_changepoint(n_before: int = 40, n_after: int = 40, period: int = 4):
    """合成：前半快、后半慢（≥1.2×），供 Rbeast 短窗自检。"""
    import numpy as np

    call_id = []
    call_time = []
    t = 0.0
    rng = np.random.default_rng(42)
    for i in range(n_before + n_after):
        slow = i >= n_before
        # period 个 AllReduce 构成一轮；轮间间隔决定 iter duration
        for k in range(period):
            call_id.append(k)  # 模式重复 → ACF 找得到 period
            call_time.append(t)
            t += 0.001 + float(rng.normal(0, 1e-5))
        gap = 0.010 if not slow else 0.014  # 1.4× 变慢
        t += gap + float(rng.normal(0, 1e-4))
    return call_id, call_time


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--jsonl", type=str, default="", help="S2 collect JSONL；空则用合成变点")
    ap.add_argument("--redis-host", default=os.environ.get("REDIS_HOST", "127.0.0.1"))
    ap.add_argument("--redis-port", type=int, default=int(os.environ.get("REDIS_PORT", "16379")))
    ap.add_argument("--out", required=True)
    ap.add_argument("--skip-redis", action="store_true")
    ap.add_argument("--thresh-prob", type=float, default=0.5)
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    import ctypes
    import importlib.util
    import types

    import numpy as np

    # aarch64 官方 wheel 缺 ELF 符号 __builtin_readcyclecounter（clang builtin 被当外部符号）
    stub_so = os.environ.get(
        "GREYHOUND_RBEAST_STUB",
        "/data/yinjinrun.p-huawei/opt/rbeast-fix/libbuiltin_readcyclecounter.so",
    )
    if Path(stub_so).is_file():
        ctypes.CDLL(stub_so, mode=ctypes.RTLD_GLOBAL)

    rbeast_ok = False
    rbeast_err = None
    try:
        import Rbeast as _rb  # noqa: F401

        rbeast_ok = True
    except Exception as e:
        rbeast_err = f"{type(e).__name__}: {e}"
        stub = types.ModuleType("Rbeast")

        def _beast(*_a, **_k):
            raise RuntimeError(f"Rbeast unavailable: {rbeast_err}")

        stub.beast = _beast
        sys.modules["Rbeast"] = stub

    # 勿 `import control_plane`（__init__ 会拉 global_controller→cvxpy）。
    # 直接加载 slow_detection.py（无相对依赖）。
    sd_path = os.environ.get(
        "GREYHOUND_SLOW_DETECTION",
        "",
    )
    if not sd_path:
        for cand in [
            Path(__file__).resolve().parent.parent / "detector" / "control_plane" / "slow_detection.py",
            Path("/data/yinjinrun.p-huawei/probe-bundle/greyhound/detector/control_plane/slow_detection.py"),
        ]:
            if cand.is_file():
                sd_path = str(cand)
                break
    if not sd_path or not Path(sd_path).is_file():
        raise SystemExit("slow_detection.py not found; set GREYHOUND_SLOW_DETECTION")

    spec = importlib.util.spec_from_file_location("gh_slow_detection", sd_path)
    sd = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(sd)
    find_period = sd.find_period
    find_performance_drop = sd.find_performance_drop

    if args.jsonl:
        call_id, call_time = load_durations_from_jsonl(Path(args.jsonl))
        source = "jsonl"
    else:
        call_id, call_time = synthesize_with_changepoint()
        source = "synthetic_changepoint"

    call_id = np.asarray(call_id, dtype=np.int64)
    call_time = np.asarray(call_time, dtype=np.float64)

    summary = {
        "tool": "greyhound",
        "phase": "S3_RULE",
        "source": source,
        "n_calls": int(len(call_id)),
        "redis": f"{args.redis_host}:{args.redis_port}",
        "ts": time.time(),
        "rbeast_ok": rbeast_ok,
        "rbeast_error": rbeast_err,
        "oracle_trigger": source == "synthetic_changepoint",
    }

    start, period = find_period(call_id, nlags=min(200, max(10, len(call_id) // 2)))
    summary["acf_start"] = int(start) if start is not None else None
    summary["acf_period"] = int(period) if period is not None else None

    cp_df = None
    last_avg = None
    if period is not None and period > 0 and start >= 0 and rbeast_ok:
        cp_df, last_avg = find_performance_drop(
            call_id,
            call_time,
            period=int(period),
            start=int(start),
            thresh_prob=args.thresh_prob,
            plot=False,
        )
        summary["rbeast_last10_avg_ts"] = float(last_avg) if last_avg is not None else None
        summary["n_changepoints"] = int(len(cp_df)) if cp_df is not None else 0
        if cp_df is not None and len(cp_df):
            cps = []
            for _, r in cp_df.iterrows():
                cid = r["ids"] if "ids" in cp_df.columns else r.ids
                cval = r["values"] if "values" in cp_df.columns else r.values
                # pandas Series.values is ndarray; prefer column access
                if hasattr(cval, "__len__") and not isinstance(cval, (str, bytes)):
                    try:
                        cval = float(cval) if np.ndim(cval) == 0 else float(np.asarray(cval).ravel()[0])
                    except Exception:
                        cval = float(np.asarray(cval).ravel()[0])
                cps.append({"id": int(cid), "t": float(cval)})
            summary["changepoints"] = cps
        else:
            summary["changepoints"] = []
    else:
        summary["n_changepoints"] = 0
        summary["changepoints"] = []
        if not rbeast_ok:
            summary["note"] = "ACF ok; Rbeast ImportError → PENDING（未改判据）"
        else:
            summary["note"] = "ACF period not found; Rbeast skipped"

    # 对齐 control_plane：写最小 Redis 键（不改判据语义）
    redis_ok = False
    if not args.skip_redis:
        try:
            import redis

            cli = redis.StrictRedis(
                host=args.redis_host, port=args.redis_port, db=0, decode_responses=True
            )
            cli.ping()
            status = "S3_ANALYZE_OK" if rbeast_ok else "S3_ACF_OK_RBEAST_PENDING"
            cli.set("global_controller", status)
            cli.set("control_state", "0")  # MONITOR
            cli.set("greyhound_s3_summary", json.dumps(summary))
            cli.rpush("greyhound_s3_events", json.dumps(summary))
            cli.delete("failslow_ranks")
            if summary.get("n_changepoints", 0) > 0:
                cli.rpush("failslow_ranks", "s3_synthetic_or_replay")
            redis_ok = True
            summary["redis_keys"] = [
                "global_controller",
                "control_state",
                "greyhound_s3_summary",
                "greyhound_s3_events",
                "failslow_ranks",
            ]
        except Exception as e:
            summary["redis_error"] = str(e)

    summary["redis_ok"] = redis_ok
    # S3 最小：ACF 跑通 + Redis 可写；完整变点需 rbeast_ok
    summary["s3_ok"] = bool(period is not None and period > 0 and redis_ok)
    summary["s3_full_rbeast"] = bool(rbeast_ok and summary.get("n_changepoints", 0) >= 0 and period)

    (out / "SUMMARY.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    if not summary.get("s3_ok"):
        raise SystemExit(3)
    if not args.skip_redis and not redis_ok:
        raise SystemExit(4)


if __name__ == "__main__":
    main()
