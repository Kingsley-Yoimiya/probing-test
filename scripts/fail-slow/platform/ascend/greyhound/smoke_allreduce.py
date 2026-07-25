#!/usr/bin/env python3
"""短训：torch_npu AllReduce 若干步，供 Greyhound LD_PRELOAD 采集。

用法（pod 内）:
  torchrun --nproc_per_node=16 smoke_allreduce.py --iters 20 --count 1048576
"""
from __future__ import annotations

import argparse
import os
import time


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--iters", type=int, default=20)
    p.add_argument("--count", type=int, default=1 << 20)  # 1M float32 elems
    args = p.parse_args()

    import torch
    import torch.distributed as dist
    import torch_npu  # noqa: F401

    rank = int(os.environ.get("RANK", "0"))
    local_rank = int(os.environ.get("LOCAL_RANK", "0"))
    world = int(os.environ.get("WORLD_SIZE", "1"))

    torch.npu.set_device(local_rank)
    dist.init_process_group(backend="hccl")
    device = torch.device(f"npu:{local_rank}")
    # 每轮重置，避免失败累乘把数值打飞
    if rank == 0:
        print(
            f"[smoke] world={world} iters={args.iters} count={args.count} "
            f"backend=hccl",
            flush=True,
        )

    t0 = time.time()
    got = 0.0
    for i in range(args.iters):
        x = torch.ones(args.count, device=device, dtype=torch.float32) * float(rank + 1)
        dist.all_reduce(x, op=dist.ReduceOp.SUM)
        torch.npu.synchronize()
        got = float(x[0].item())
    elapsed = time.time() - t0

    # 期望：每元素 ≈ sum(1..world) = world*(world+1)/2
    expect = float(world * (world + 1) / 2)
    ok = abs(got - expect) < 1e-2 * max(1.0, expect)
    if rank == 0:
        print(
            f"[smoke] done elapsed={elapsed:.3f}s x0={got} expect≈{expect} ok={ok}",
            flush=True,
        )
    dist.barrier()
    dist.destroy_process_group()
    if not ok:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
