#!/usr/bin/env python3
"""2+ rank HCCL — S2 collect / S3 desync hang injection for XPUTimer Ascend."""
import argparse
import os
import time

import torch
import torch.distributed as dist
import torch_npu  # noqa: F401


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters", type=int, default=40)
    ap.add_argument("--size", type=int, default=1 << 18)
    ap.add_argument("--desync-rank", type=int, default=-1,
                    help="rank that skips collectives (stalls peers → HANG)")
    ap.add_argument("--desync-at", type=int, default=-1,
                    help="iteration at which desync rank bails")
    ap.add_argument("--desync-sleep", type=float, default=8.0,
                    help="seconds desync rank sits out (let peer hang poller fire)")
    args = ap.parse_args()

    rank = int(os.environ.get("RANK", "0"))
    local_rank = int(os.environ.get("LOCAL_RANK", "0"))
    world = int(os.environ.get("WORLD_SIZE", "1"))
    torch.npu.set_device(local_rank)
    dist.init_process_group(backend="hccl")
    if rank == 0:
        print(f"[dist] world={world} device={torch.npu.get_device_name(0)} "
              f"backend=hccl dump={os.environ.get('XPU_TIMER_DUMP_DIR')} "
              f"desync_rank={args.desync_rank}@{args.desync_at}",
              flush=True)

    x = torch.randn(args.size, device=f"npu:{local_rank}", dtype=torch.float32)
    g = torch.empty(args.size * world, device=f"npu:{local_rank}", dtype=torch.float32)

    for i in range(args.iters):
        if rank == args.desync_rank and i == args.desync_at:
            print(f"[dist][rank{rank}] DESYNC: skipping collectives from iter {i} "
                  f"for {args.desync_sleep}s", flush=True)
            time.sleep(args.desync_sleep)
            break

        dist.all_reduce(x)
        dist.all_gather_into_tensor(g, x)
        if i % 10 == 0:
            torch.npu.synchronize()
            if rank == 0:
                print(f"[dist] iter {i} ok", flush=True)

    # Peers may still be blocked; give hang poller time, then exit without
    # waiting forever on destroy (desync path uses outer `timeout`).
    time.sleep(1.0)
    if rank == 0 and args.desync_rank < 0:
        torch.npu.synchronize()
        print("[dist] done", flush=True)
        dist.destroy_process_group()
    elif rank == args.desync_rank:
        print(f"[dist][rank{rank}] desync exit (skip destroy)", flush=True)
    else:
        print(f"[dist][rank{rank}] peer may be hung; exit without destroy",
              flush=True)


if __name__ == "__main__":
    main()
