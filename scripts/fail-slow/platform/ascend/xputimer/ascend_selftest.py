#!/usr/bin/env python3
"""单卡 NPU 短训：验证 LD_PRELOAD 不炸（S1）。集合通信需 ascend_dist_test。"""
import argparse
import os
import time

import torch
import torch_npu  # noqa: F401


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters", type=int, default=50)
    ap.add_argument("--size", type=int, default=2048)
    args = ap.parse_args()

    assert torch.npu.is_available(), "torch.npu not available"
    torch.npu.set_device(0)
    print(f"[selftest] device={torch.npu.get_device_name(0)} "
          f"torch={torch.__version__} dump={os.environ.get('XPU_TIMER_DUMP_DIR')}",
          flush=True)

    n = args.size
    a = torch.randn(n, n, device="npu", dtype=torch.float16)
    b = torch.randn(n, n, device="npu", dtype=torch.float16)
    for _ in range(3):
        c = a @ b
    torch.npu.synchronize()

    t0 = time.time()
    for i in range(args.iters):
        c = a @ b
        c = torch.relu(c)
        c = c + a
        if i % 20 == 0:
            torch.npu.synchronize()
    torch.npu.synchronize()
    dt = time.time() - t0
    print(f"[selftest] {args.iters} iters ok in {dt*1000:.1f}ms "
          f"(kernel path; Hccl hooks idle on single-process)", flush=True)
    time.sleep(1.0)
    print("[selftest] done", flush=True)


if __name__ == "__main__":
    main()
