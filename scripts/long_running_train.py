#!/usr/bin/env python3
"""后台长时间运行的小训练，供动态 inject / backtrace / eval 测试。"""
from __future__ import annotations

import os
import time

import torch
import torch.nn as nn
import torch.nn.functional as F


class Net(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.fc = nn.Sequential(nn.Linear(16, 32), nn.ReLU(), nn.Linear(32, 4))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.fc(x)


def main() -> None:
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = Net().to(device)
    opt = torch.optim.SGD(model.parameters(), lr=0.01)
    print(f"LONG_RUN pid={os.getpid()} device={device}", flush=True)
    for i in range(200):
        x = torch.randn(8, 16, device=device)
        y = torch.randint(0, 4, (8,), device=device)
        loss = F.cross_entropy(model(x), y)
        opt.zero_grad()
        loss.backward()
        opt.step()
        if i % 20 == 0:
            print(f"  iter={i} loss={loss.item():.4f}", flush=True)
        time.sleep(0.3)


if __name__ == "__main__":
    main()
