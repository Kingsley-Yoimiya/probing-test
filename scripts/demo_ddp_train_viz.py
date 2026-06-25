#!/usr/bin/env python3
"""多卡 DDP 小训练，供 Training 页 Step × Rank straggler 热力图采集。"""
from __future__ import annotations

import os
import time

import probing
import torch
import torch.distributed as dist
import torch.nn as nn
import torch.nn.functional as F
from torch.nn.parallel import DistributedDataParallel as DDP

SLEEP_SEC = 0.12
STRAGGLER_EXTRA_SEC = 0.35


class TinyNet(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.fc1 = nn.Linear(128, 256)
        self.fc2 = nn.Linear(256, 64)
        self.fc3 = nn.Linear(64, 10)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.fc3(F.relu(self.fc2(F.relu(self.fc1(x)))))


def main() -> None:
    dist.init_process_group(backend="nccl")
    rank = dist.get_rank()
    local_rank = int(os.environ.get("LOCAL_RANK", rank))
    device = torch.device(f"cuda:{local_rank}")
    torch.cuda.set_device(device)

    duration = int(os.environ.get("DEMO_DURATION_SEC", "180"))
    if rank == 0:
        print(
            f"DDP_DEMO rank={rank} local_rank={local_rank} device={device} "
            f"duration={duration}s probing={'on' if probing.is_enabled() else 'off'}",
            flush=True,
        )

    with probing.span("setup"):
        model = TinyNet().to(device)
        model = DDP(model, device_ids=[local_rank])
        optimizer = torch.optim.SGD(model.parameters(), lr=0.01)

    probing.attach_training_phases(model.module, optimizer)
    if rank == 0:
        print("attach_training_phases ok", flush=True)

    straggler_rank = int(os.environ.get("STRAGGLER_RANK", "2"))
    straggler_mod = int(os.environ.get("STRAGGLER_MOD", "4"))
    world = dist.get_world_size()
    deadline = time.time() + duration
    step = 0
    batch_size = 32
    if rank == 0:
        print(
            f"  world_size={world} straggler_rank={straggler_rank} "
            f"(rank {straggler_rank} 周期性加慢)",
            flush=True,
        )
    with probing.span("training_loop"):
        while time.time() < deadline:
            x = torch.randn(batch_size, 128, device=device)
            y = torch.randint(0, 10, (batch_size,), device=device)
            logits = model(x)
            loss = F.cross_entropy(logits, y)
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            if rank == straggler_rank and step % straggler_mod == 2:
                time.sleep(STRAGGLER_EXTRA_SEC)
            elif rank == (straggler_rank + 1) % world and step % 7 == 5:
                time.sleep(STRAGGLER_EXTRA_SEC * 0.45)
            time.sleep(SLEEP_SEC)
            if rank == 0 and step % 15 == 0:
                print(
                    f"  step={step} loss={float(loss.item()):.4f} "
                    f"micro={probing.step.micro_step}",
                    flush=True,
                )
            step += 1

    if rank == 0:
        print(f"DDP demo done steps={step} pid={os.getpid()}", flush=True)
    dist.barrier()
    time.sleep(2)
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
