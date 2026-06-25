#!/usr/bin/env python3
"""小型 DDP 训练脚本，用于验证 probing 分布式 collective 追踪。"""
from __future__ import annotations

import os
import time

import probing
import torch
import torch.distributed as dist
import torch.nn as nn
import torch.nn.functional as F
from torch.nn.parallel import DistributedDataParallel as DDP


class TinyMLP(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.fc1 = nn.Linear(32, 64)
        self.fc2 = nn.Linear(64, 8)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.fc2(F.relu(self.fc1(x)))


def main() -> None:
    dist.init_process_group(backend="nccl")
    rank = dist.get_rank()
    local_rank = int(os.environ.get("LOCAL_RANK", rank))
    device = torch.device(f"cuda:{local_rank}")
    torch.cuda.set_device(device)

    model = TinyMLP().to(device)
    model = DDP(model, device_ids=[local_rank])
    optimizer = torch.optim.Adam(model.parameters(), lr=1e-3)
    probing.attach_training_phases(model.module, optimizer)

    steps = 8
    with probing.span("ddp-epoch"):
        for step in range(steps):
            x = torch.randn(32, 32, device=device)
            y = torch.randint(0, 8, (32,), device=device)
            logits = model(x)
            loss = F.cross_entropy(logits, y)
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            if rank == 0:
                print(f"  rank0 step={step} loss={loss.item():.4f}")

    if rank == 0:
        print(f"DDP training done pid={os.getpid()} probing={probing.is_enabled()}")
    dist.barrier()
    dist.destroy_process_group()
    time.sleep(1)


if __name__ == "__main__":
    main()
