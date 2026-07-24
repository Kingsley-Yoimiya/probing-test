#!/usr/bin/env python3
"""sidecar_inject_v2.py — 多 case 外部注入 sidecar（通用版）。

支持所有可外部注入的 case:
  --case 1b: 渐进 HBM 带宽衰减（duty 从 0.1 逐步升到 0.9）
  --case 2b: 动态 shape GEMM（随机变换 matrix size 触发次优 kernel）
  --case 2c: torch.compile cache thrash（周期性清编译缓存）
  --case 3c: 多进程 GPU 时间片抖动（spawn 4 个竞争进程）
  --case 5b: 大小 AllReduce 混合（占用 MCCL 通道带宽）
  --case 8a: 外部 Python GC 压力（大量 alloc + gc）
  --case 8b: 内存渐进泄漏（模拟 DataLoader worker leak）
  --case 8c: 监控进程泄漏（模拟 metric collector overhead）

用法:
  CUDA_VISIBLE_DEVICES=7 python3 sidecar_inject_v2.py --case 1b --seconds 300
"""
from __future__ import annotations

import argparse
import gc
import os
import time
import sys
import threading


def case_1b(seconds: float):
    """渐进 HBM 带宽衰减: duty 从 0.1 逐步升到 0.9"""
    import torch
    torch.cuda.set_device(0)
    N = 32 * 1024 * 1024  # 128MB fp16
    src = torch.randn(N, device="cuda:0", dtype=torch.float16)
    dst = torch.empty_like(src)
    for _ in range(3):
        dst.copy_(src)
    torch.cuda.synchronize()

    print("SIDECAR_1B_START: gradual HBM ramp", flush=True)
    t_start = time.time()
    period = 0.2
    while time.time() - t_start < seconds:
        elapsed = time.time() - t_start
        duty = min(0.9, 0.1 + 0.8 * elapsed / seconds)  # ramp 0.1 → 0.9
        t0 = time.perf_counter()
        while time.perf_counter() - t0 < period * duty:
            dst.copy_(src)
        torch.cuda.synchronize()
        remaining = period - (time.perf_counter() - t0)
        if remaining > 0:
            time.sleep(remaining)
    print(f"SIDECAR_1B_STOP", flush=True)


def case_2b(seconds: float):
    """动态 shape: 随机大小 GEMM 触发 kernel recompile/suboptimal dispatch"""
    import torch
    torch.cuda.set_device(0)
    print("SIDECAR_2B_START: dynamic shape GEMM", flush=True)
    import random
    t_end = time.time() + seconds
    sizes = [1024, 1536, 2048, 2560, 3072, 3584, 4096, 5120, 6144, 7168, 8192]
    while time.time() < t_end:
        N = random.choice(sizes)
        A = torch.randn(N, N, device="cuda:0", dtype=torch.float16)
        B = torch.randn(N, N, device="cuda:0", dtype=torch.float16)
        torch.mm(A, B)
        torch.cuda.synchronize()
        del A, B
    print("SIDECAR_2B_STOP", flush=True)


def case_2c(seconds: float):
    """编译缓存 thrash: 周期性清 torch inductor cache 强制 recompile"""
    import torch
    torch.cuda.set_device(0)
    print("SIDECAR_2C_START: compile cache thrash", flush=True)
    import shutil
    cache_dir = os.path.expanduser("~/.cache/torch_inductor")
    t_end = time.time() + seconds
    while time.time() < t_end:
        # Thrash: do varying shape compiles
        for N in [1024, 2048, 4096]:
            x = torch.randn(N, N, device="cuda:0")
            y = torch.mm(x, x)
            del x, y
        torch.cuda.synchronize()
        # Clear cache every 10s
        if os.path.exists(cache_dir):
            shutil.rmtree(cache_dir, ignore_errors=True)
        time.sleep(5)
    print("SIDECAR_2C_STOP", flush=True)


def case_3c(seconds: float):
    """多进程 GPU 时间片抖动: spawn 多个子进程各自做 GEMM"""
    import torch
    import multiprocessing as mp
    torch.cuda.set_device(0)
    print("SIDECAR_3C_START: multi-process GPU contention", flush=True)

    def worker(duration):
        import torch
        torch.cuda.set_device(0)
        A = torch.randn(2048, 2048, device="cuda:0", dtype=torch.float16)
        B = torch.randn(2048, 2048, device="cuda:0", dtype=torch.float16)
        t_end = time.time() + duration
        while time.time() < t_end:
            torch.mm(A, B)
            torch.cuda.synchronize()

    procs = []
    for _ in range(4):
        p = mp.Process(target=worker, args=(seconds,))
        p.start()
        procs.append(p)
    for p in procs:
        p.join()
    print("SIDECAR_3C_STOP", flush=True)


def case_5b(seconds: float):
    """通信带宽争用: 在 victim 上做大量 NCCL-independent 网络 IO (模拟)"""
    # 注意: 真正的通信争用需要多进程 dist.all_reduce, 这里用大块 GPU→CPU copy 模拟 PCIe 争用
    import torch
    torch.cuda.set_device(0)
    print("SIDECAR_5B_START: PCIe bandwidth contention", flush=True)
    big = torch.randn(64 * 1024 * 1024, device="cuda:0", dtype=torch.float16)  # 128MB
    t_end = time.time() + seconds
    while time.time() < t_end:
        cpu_copy = big.cpu()  # GPU→CPU (PCIe)
        big.copy_(cpu_copy.cuda())  # CPU→GPU (PCIe)
        del cpu_copy
    print("SIDECAR_5B_STOP", flush=True)


def case_1c(seconds: float, frac: float = 0.7):
    """P1-EXT-C 显存容量压力(不 OOM): 占住目标卡 frac 比例显存并周期性触碰。

    与 3c 的多进程时间片抖动不同: 这里是"容量+访存压力"而非"算力抢占",
    单进程占大块显存 → 逼迫训练 allocator 走更碎的路径 + HBM 驻留竞争。
    frac 需 <1 以免 OOM; 默认 0.7(留给训练自身)。
    """
    import torch
    torch.cuda.set_device(0)
    free, total = torch.cuda.mem_get_info()
    hold_bytes = int(total * frac)
    nelems = hold_bytes // 2  # fp16
    print(f"SIDECAR_1C_START: hold {hold_bytes/2**30:.1f}GiB ({frac:.0%} of {total/2**30:.1f}GiB)", flush=True)
    try:
        block = torch.empty(nelems, device="cuda:0", dtype=torch.float16)
    except RuntimeError:
        # 目标 frac 太大 → 退到 free 的一半, 仍制造压力但不 OOM
        nelems = int(free * 0.5) // 2
        block = torch.empty(nelems, device="cuda:0", dtype=torch.float16)
        print(f"SIDECAR_1C_fallback: hold {nelems*2/2**30:.1f}GiB", flush=True)
    t_end = time.time() + seconds
    while time.time() < t_end:
        block[:1024].fill_(1.0)   # 周期性触碰, 保持驻留 + 少量 HBM 流量
        torch.cuda.synchronize()
        time.sleep(0.2)
    del block
    print("SIDECAR_1C_STOP", flush=True)


def case_2ext(seconds: float, target_host: str = "", hca: str = "xscale_0"):
    """P2-EXT-A 邻居 AllReduce/链路争用: 用 ib_write_bw 打满共享 RoCE 链路。

    这是 P2 唯一能做的高保真注入(tc 对 RoCE 无效, 见 feasibility audit):
    victim pod 起 ib_write_bw client 对邻居 server 持续打流, 抢占共享上行带宽,
    训练的 AllReduce 流量与之竞争 → 真实链路争用。
    需要一个 server 端: 在邻居 pod 先跑 `ib_write_bw -d <hca>`。
    检测端证据由编排层用 `rdma statistic show link` 采 ECN/CNP/retrans。
    """
    import subprocess
    if not target_host:
        print("SIDECAR_2EXT_ERR: need --target-host (邻居 server IP/hostname)", flush=True)
        return
    print(f"SIDECAR_2EXT_START: ib_write_bw flood → {target_host} via {hca}", flush=True)
    t_end = time.time() + seconds
    # ib_write_bw 单次跑完会退出, 循环重打直到时限; -D 让它按秒持续
    dur = max(5, int(seconds))
    try:
        subprocess.run(
            ["ib_write_bw", "-d", hca, "-D", str(dur), "-s", "1048576", target_host],
            timeout=seconds + 30, check=False,
        )
    except FileNotFoundError:
        print("SIDECAR_2EXT_ERR: ib_write_bw 未安装(apt install perftest)", flush=True)
    except subprocess.TimeoutExpired:
        pass
    print("SIDECAR_2EXT_STOP", flush=True)


def case_8a(seconds: float):
    """外部 GC 压力（遗留路径）。P3-SW-A Loud 主路径改为 train_bench INLINE_INJECT=8a。"""
    print("SIDECAR_8A_START: external GC pressure", flush=True)
    t_end = time.time() + seconds
    while time.time() < t_end:
        garbage = [bytearray(10240) for _ in range(50000)]  # 500MB
        del garbage
        gc.collect()
        time.sleep(1)
    print("SIDECAR_8A_STOP", flush=True)


def case_8b(seconds: float):
    """DataLoader worker 泄漏模拟: 渐进分配内存不释放"""
    print("SIDECAR_8B_START: progressive memory leak", flush=True)
    leaked = []
    t_end = time.time() + seconds
    while time.time() < t_end:
        leaked.append(bytearray(10 * 1024 * 1024))  # 10MB per iteration
        time.sleep(2)
    print(f"SIDECAR_8B_STOP leaked={len(leaked)*10}MB", flush=True)


def case_8c(seconds: float):
    """监控进程泄漏: 模拟 metric collector 不断创建线程 + 小内存泄漏"""
    print("SIDECAR_8C_START: monitoring overhead", flush=True)
    leaked_threads = []
    leaked_data = []
    t_end = time.time() + seconds

    def dummy_collector():
        while time.time() < t_end:
            time.sleep(0.1)

    while time.time() < t_end:
        # Spawn threads (simulate metric collectors)
        t = threading.Thread(target=dummy_collector, daemon=True)
        t.start()
        leaked_threads.append(t)
        # Small memory leak
        leaked_data.append(bytearray(1024 * 1024))  # 1MB
        time.sleep(3)
    print(f"SIDECAR_8C_STOP threads={len(leaked_threads)} mem={len(leaked_data)}MB", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", required=True,
                    choices=["1b", "1c", "2b", "2c", "2ext", "3c", "5b", "8a", "8b", "8c"])
    ap.add_argument("--seconds", type=float, default=300)
    ap.add_argument("--frac", type=float, default=0.7, help="1c: 占显存比例")
    ap.add_argument("--target-host", default="", help="2ext: ib_write_bw server 邻居 IP/host")
    ap.add_argument("--hca", default="xscale_0", help="2ext: RoCE HCA")
    args = ap.parse_args()

    if args.case == "1c":
        case_1c(args.seconds, args.frac)
    elif args.case == "2ext":
        case_2ext(args.seconds, args.target_host, args.hca)
    else:
        cases = {
            "1b": case_1b, "2b": case_2b, "2c": case_2c, "3c": case_3c,
            "5b": case_5b, "8a": case_8a, "8b": case_8b, "8c": case_8c,
        }
        cases[args.case](args.seconds)


if __name__ == "__main__":
    main()
