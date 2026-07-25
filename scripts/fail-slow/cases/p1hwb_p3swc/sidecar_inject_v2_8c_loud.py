#!/usr/bin/env python3
"""隔离：P3-SW-C Loud 监控泄漏（专供 host_bound 咬合）。

不改共享 sidecar_inject_v2.py。pipeline 仍调用 sidecar_inject_v2.py ——
run_abc 在 P3-SW-C 时把本文件同步为 sidecar_inject_v2.py。

剂量演进：
- v1 默认共享：1MB/3s + sleep 线程 → 短窗咬不动
- v2 8c_loud（h3c）：8MB/0.2s + 短忙 → mohe attempt1 C1/C0≈0.92 仍咬空
- v3 8c_loud2：≈1.5×nproc 忙等 + 8MB/0.2s 泄漏 → attempt2 **OOMKilled master**
- v4 8c_loud3（本文件）：≈1.0×nproc 纯忙等；泄漏降到 1MB/1s 且仅主进程，防 OOM
"""
from __future__ import annotations

import argparse
import multiprocessing as mp
import os
import sys
import threading
import time


def _busy_worker(t_end: float):
    """子进程：常驻忙循环（不泄漏内存），抢 host_bound 核。"""
    while time.time() < t_end:
        busy_end = time.perf_counter() + 0.02
        acc = 0
        while time.perf_counter() < busy_end:
            acc += sum(range(80))
        # 故意不 sleep


def case_8c(seconds: float):
    """监控进程泄漏 Loud3：多进程 CPU 忙等 + 轻量主进程泄漏。"""
    nproc = os.cpu_count() or 64
    # attempt2 OOM：1.5×nproc×8MB/0.2s；改为 1.0×nproc 且子进程不泄漏
    n_workers = max(64, int(nproc * float(os.environ.get("SIDECAR_8C_WORKERS_FRAC", "1.0"))))
    chunk_mb = int(os.environ.get("SIDECAR_8C_MB", "1"))
    leak_every = float(os.environ.get("SIDECAR_8C_LEAK_EVERY", "1.0"))
    max_leak_chunks = int(os.environ.get("SIDECAR_8C_MAX_CHUNKS", "64"))
    print("SIDECAR_START kind=8c_loud3", flush=True)
    print(
        f"SIDECAR_8C_START: monitoring overhead LOUD3 workers={n_workers} "
        f"chunk_mb={chunk_mb}/{leak_every}s max_chunks={max_leak_chunks} nproc={nproc}",
        flush=True,
    )
    t_end = time.time() + seconds
    procs: list[mp.Process] = []
    for _ in range(n_workers):
        p = mp.Process(target=_busy_worker, args=(t_end,), daemon=True)
        p.start()
        procs.append(p)

    leaked_threads = []
    leaked_data = []

    def dummy_collector():
        while time.time() < t_end:
            busy_end = time.perf_counter() + 0.01
            while time.perf_counter() < busy_end:
                _ = sum(range(50))
            time.sleep(0.01)

    while time.time() < t_end:
        t = threading.Thread(target=dummy_collector, daemon=True)
        t.start()
        leaked_threads.append(t)
        if len(leaked_data) < max_leak_chunks:
            leaked_data.append(bytearray(chunk_mb * 1024 * 1024))
        time.sleep(leak_every)
    for p in procs:
        p.join(timeout=1)
        if p.is_alive():
            p.terminate()
    print(
        f"SIDECAR_8C_STOP workers={n_workers} threads={len(leaked_threads)} "
        f"mem≈{len(leaked_data) * chunk_mb}MB_est",
        flush=True,
    )
    print("SIDECAR_STOP kind=8c_loud3", flush=True)


def main():
    try:
        mp.set_start_method("fork")
    except RuntimeError:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", required=True)
    ap.add_argument("--seconds", type=float, default=600)
    ap.add_argument("--frac", type=float, default=0.7)
    ap.add_argument("--target-host", default="")
    ap.add_argument("--hca", default="xscale_0")
    args = ap.parse_args()
    if args.case != "8c":
        print(f"WARN: isolated loud shim only supports 8c, got {args.case}", flush=True)
    case_8c(args.seconds)


if __name__ == "__main__":
    main()
