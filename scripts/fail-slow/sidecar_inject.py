#!/usr/bin/env python3
"""sidecar_inject.py — MetaX C550 外部 GPU 干扰 sidecar。

完全独立于训练进程：有自己的 CUDA context，通过 duty cycle 在指定 device 上施压。
目标设备由 MACA_VISIBLE_DEVICES 控制（建议只暴露一张卡）。

用法:
  MACA_VISIBLE_DEVICES=7 python3 sidecar_inject.py --kind cube --duty 0.8 --warmup-seconds 5 --seconds 120
  MACA_VISIBLE_DEVICES=7 python3 sidecar_inject.py --kind hbm --duty 0.8 --warmup-seconds 5 --seconds 120

kind:
  cube - 持续 GEMM（抢算力）
  hbm  - 持续 D2D copy（抢显存带宽）

MetaX 时间片隔离要点（loud2 实测）：
  - 需要向 GPU 队列持续投核；中途频繁 synchronize 会把压力冲掉（C1/C0≈1）。
  - 但 warmup 末尾一次 synchronize 会在与训练共卡时长时间卡住，导致永远
    打不出 SIDECAR_START。因此：先打 START，施压阶段默认不 sync。
"""
from __future__ import annotations

import argparse
import signal
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kind", choices=["cube", "hbm"], default="cube")
    ap.add_argument("--duty", type=float, default=0.3, help="busy fraction per period (0~1)")
    ap.add_argument("--period-ms", type=float, default=200, help="duty cycle period in ms")
    ap.add_argument("--seconds", type=float, default=300, help="total duration")
    ap.add_argument("--size", type=int, default=4096, help="matrix size for cube / MB for hbm")
    ap.add_argument("--warmup-seconds", type=float, default=5.0,
                    help="稳态预热时长；预热完成前不计入故障窗口")
    ap.add_argument("--sync-during-pressure", action="store_true",
                    help="施压期每 period 末 synchronize（MetaX 上通常会削弱咬合，默认关）")
    args = ap.parse_args()

    import torch
    torch.cuda.set_device(0)  # visible-devices already restricts to target device
    device = "cuda:0"

    if args.kind == "cube":
        N = args.size
        A = torch.randn(N, N, device=device, dtype=torch.float16)
        B = torch.randn(N, N, device=device, dtype=torch.float16)
        for _ in range(5):
            torch.mm(A, B)
        torch.cuda.synchronize()

        def burst():
            torch.mm(A, B)

    elif args.kind == "hbm":
        # size=MB。共卡时过大（如 8192）易咬空；默认钳到 [64,2048]。
        # 多流在 MetaX 上会 mxkwCreateQueueBlock 超时（bite2），保持单流双向 copy。
        mb = max(64, min(int(args.size), 2048))
        nelems = mb * 1024 * 1024 // 2  # fp16
        src = torch.randn(nelems, device=device, dtype=torch.float16)
        dst = torch.empty_like(src)
        for _ in range(3):
            dst.copy_(src)
            src.copy_(dst)
        torch.cuda.synchronize()
        print(f"SIDECAR_HBM_ALLOC mb={mb} elems={nelems}", flush=True)

        def burst():
            dst.copy_(src)
            src.copy_(dst)

    if not 0.0 <= args.duty <= 1.0:
        ap.error("--duty must be within [0, 1]")
    if args.warmup_seconds < 0:
        ap.error("--warmup-seconds must be non-negative")

    ops = 0
    stopping = False

    def _on_signal(signum, _frame):
        nonlocal stopping
        stopping = True
        print(f"SIDECAR_SIGNAL signum={signum} ops={ops}", flush=True)

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    # 先落盘 WARMUP/START，再进入无 sync 投核。与训练共卡时 synchronize 会挂死，
    # 导致旧版永远写不出 START；施压期也避免频繁 sync，否则咬合力被冲掉。
    if args.warmup_seconds:
        print(
            f"SIDECAR_WARMUP kind={args.kind} seconds={args.warmup_seconds}",
            flush=True,
        )
    print(
        f"SIDECAR_START kind={args.kind} duty={args.duty} period={args.period_ms}ms",
        flush=True,
    )

    if args.warmup_seconds:
        warm_end = time.time() + args.warmup_seconds
        while time.time() < warm_end and not stopping:
            burst()
            ops += 1

    period_s = args.period_ms / 1000.0
    busy_s = period_s * args.duty
    t_end = time.time() + args.seconds

    while time.time() < t_end and not stopping:
        t0 = time.perf_counter()
        while (time.perf_counter() - t0) < busy_s and not stopping:
            burst()
            ops += 1
        if args.sync_during_pressure:
            torch.cuda.synchronize()
        idle_s = period_s - (time.perf_counter() - t0)
        if idle_s > 0 and not stopping:
            time.sleep(idle_s)

    print(f"SIDECAR_STOP ops={ops}", flush=True)


if __name__ == "__main__":
    main()
