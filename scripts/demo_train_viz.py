#!/usr/bin/env python3
"""供可视化文档采集用的长时间小训练（含 attach_training_phases + span）。"""
from __future__ import annotations

import os
import time

import probing
import torch
import torch.nn as nn
import torch.nn.functional as F

DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")
BATCH_SIZE = 32
LR = 0.01
SLEEP_SEC = 0.15


class TinyNet(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.fc1 = nn.Linear(128, 256)
        self.fc2 = nn.Linear(256, 64)
        self.fc3 = nn.Linear(64, 10)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.fc3(F.relu(self.fc2(F.relu(self.fc1(x)))))


def train_one_batch(
    model: nn.Module,
    optimizer: torch.optim.Optimizer,
    batch_idx: int,
) -> float:
    x = torch.randn(BATCH_SIZE, 128, device=DEVICE)
    y = torch.randint(0, 10, (BATCH_SIZE,), device=DEVICE)
    logits = model(x)
    loss = F.cross_entropy(logits, y)
    optimizer.zero_grad()
    loss.backward()
    optimizer.step()
    if batch_idx % 10 == 0:
        probing.event(
            "batch.stats",
            attributes=[{"loss": round(float(loss.item()), 4)}, {"phase": probing.phase()}],
        )
    return float(loss.item())


def main() -> None:
    pid = os.getpid()
    duration = int(os.environ.get("DEMO_DURATION_SEC", "180"))
    print(
        f"DEMO_TRAIN pid={pid} device={DEVICE} duration={duration}s "
        f"probing={'on' if probing.is_enabled() else 'off'}",
        flush=True,
    )

    with probing.span("setup"):
        model = TinyNet().to(DEVICE)
        optimizer = torch.optim.SGD(model.parameters(), lr=LR)

    probing.attach_training_phases(model, optimizer)
    print("attach_training_phases ok", flush=True)

    deadline = time.time() + duration
    batch = 0
    with probing.span("training_loop"):
        while time.time() < deadline:
            loss = train_one_batch(model, optimizer, batch)
            if batch % 20 == 0:
                print(
                    f"  batch={batch} loss={loss:.4f} step={probing.step.micro_step}",
                    flush=True,
                )
            batch += 1
            time.sleep(SLEEP_SEC)

    print(f"done batches={batch}", flush=True)


if __name__ == "__main__":
    main()
