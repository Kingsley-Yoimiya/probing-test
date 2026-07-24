#!/usr/bin/env python3
"""隔离：P3-SW-C Loud 监控泄漏（比 sidecar_inject_v2.case_8c 更猛，专供 host_bound 咬合）。

不改共享 sidecar_inject_v2.py。pipeline 仍调用 sidecar_inject_v2.py ——
run_abc 在 P3-SW-C 时把本文件同步为 sidecar_inject_v2.py。
"""
from __future__ import annotations

import argparse
import os
import sys
import threading
import time


def case_8c(seconds: float):
    """监控进程泄漏 Loud：每 0.2s +8MB + 新线程（默认版 3s/1MB 在短窗咬不动）。"""
    print("SIDECAR_START kind=8c_loud", flush=True)
    print("SIDECAR_8C_START: monitoring overhead LOUD", flush=True)
    leaked_threads = []
    leaked_data = []
    t_end = time.time() + seconds

    def dummy_collector():
        while time.time() < t_end:
            time.sleep(0.05)

    while time.time() < t_end:
        t = threading.Thread(target=dummy_collector, daemon=True)
        t.start()
        leaked_threads.append(t)
        leaked_data.append(bytearray(8 * 1024 * 1024))  # 8MB
        # 偶发忙循环抢 GIL / CPU
        busy_end = time.perf_counter() + 0.05
        while time.perf_counter() < busy_end:
            _ = sum(range(200))
        time.sleep(0.15)
    print(
        f"SIDECAR_8C_STOP threads={len(leaked_threads)} mem={len(leaked_data)*8}MB",
        flush=True,
    )
    print("SIDECAR_STOP kind=8c_loud", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", required=True)
    ap.add_argument("--seconds", type=float, default=600)
    ap.add_argument("--frac", type=float, default=0.7)
    ap.add_argument("--target-host", default="")
    ap.add_argument("--hca", default="xscale_0")
    args = ap.parse_args()
    if args.case != "8c":
        # 兼容 pipeline 传 --case 8c；其它 case 退回共享实现提示
        print(f"WARN: isolated loud shim only supports 8c, got {args.case}", flush=True)
    case_8c(args.seconds)


if __name__ == "__main__":
    main()
