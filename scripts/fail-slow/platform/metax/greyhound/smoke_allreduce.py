#!/usr/bin/env python3
"""短训：MetaX torch AllReduce，供 Greyhound LD_PRELOAD 采集。

用法（pod 内）:
  torchrun --nproc_per_node=2 smoke_allreduce.py --iters 20 --count 1048576
"""
from __future__ import annotations

import argparse
import os
import time


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--iters", type=int, default=20)
    p.add_argument("--count", type=int, default=1 << 20)
    args = p.parse_args()

    import torch
    import torch.distributed as dist

    rank = int(os.environ.get("RANK", "0"))
    local_rank = int(os.environ.get("LOCAL_RANK", "0"))
    world = int(os.environ.get("WORLD_SIZE", "1"))

    torch.cuda.set_device(local_rank)
    dist.init_process_group(backend="nccl")
    device = torch.device(f"cuda:{local_rank}")
    if rank == 0:
        print(
            f"[smoke] world={world} iters={args.iters} count={args.count} "
            f"backend=nccl(mccl) torch={torch.__version__}",
            flush=True,
        )

    t0 = time.time()
    got = 0.0
    for _ in range(args.iters):
        x = torch.ones(args.count, device=device, dtype=torch.float32) * float(rank + 1)
        dist.all_reduce(x, op=dist.ReduceOp.SUM)
        torch.cuda.synchronize()
        got = float(x[0].item())
    elapsed = time.time() - t0

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
