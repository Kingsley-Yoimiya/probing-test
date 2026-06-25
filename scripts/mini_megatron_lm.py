#!/usr/bin/env python3
"""
Megatron-LM 风格的小型 GPT 训练（单卡）。
模拟：Transformer block + Adam + 多 step，用于 probing 端到端训练 profiling。
"""
from __future__ import annotations

import math
import os

import probing
import torch
import torch.nn as nn
import torch.nn.functional as F


class MiniGPTBlock(nn.Module):
    def __init__(self, d_model: int, n_heads: int, d_ff: int) -> None:
        super().__init__()
        self.ln1 = nn.LayerNorm(d_model)
        self.attn = nn.MultiheadAttention(d_model, n_heads, batch_first=True)
        self.ln2 = nn.LayerNorm(d_model)
        self.ff = nn.Sequential(
            nn.Linear(d_model, d_ff),
            nn.GELU(),
            nn.Linear(d_ff, d_model),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        h = self.ln1(x)
        attn_out, _ = self.attn(h, h, h, need_weights=False)
        x = x + attn_out
        x = x + self.ff(self.ln2(x))
        return x


class MiniGPT(nn.Module):
    def __init__(
        self, vocab: int, d_model: int, n_layers: int, n_heads: int, d_ff: int
    ) -> None:
        super().__init__()
        self.embed = nn.Embedding(vocab, d_model)
        self.pos = nn.Embedding(128, d_model)
        self.blocks = nn.ModuleList(
            [MiniGPTBlock(d_model, n_heads, d_ff) for _ in range(n_layers)]
        )
        self.ln_f = nn.LayerNorm(d_model)
        self.head = nn.Linear(d_model, vocab)

    def forward(self, idx: torch.Tensor) -> torch.Tensor:
        b, t = idx.shape
        pos = torch.arange(t, device=idx.device).unsqueeze(0).expand(b, t)
        x = self.embed(idx) + self.pos(pos)
        for block in self.blocks:
            x = block(x)
        return self.head(self.ln_f(x))


def main() -> None:
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    vocab, d_model, n_layers, n_heads = 256, 128, 4, 4
    d_ff = d_model * 4
    batch, seq_len, steps = 8, 32, 12
    lr = 3e-4

    pid = os.getpid()
    print(f"MiniGPT pid={pid} device={device} probing={probing.is_enabled()}")

    with probing.span("model-init"):
        model = MiniGPT(vocab, d_model, n_layers, n_heads, d_ff).to(device)
        optimizer = torch.optim.AdamW(model.parameters(), lr=lr)

    probing.attach_training_phases(model, optimizer)

    with probing.span("train-loop"):
        for step in range(steps):
            idx = torch.randint(0, vocab, (batch, seq_len), device=device)
            targets = idx.clone()
            with probing.span("forward"):
                logits = model(idx)
            loss = F.cross_entropy(logits.view(-1, vocab), targets.view(-1))
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()

            if step % 3 == 0:
                ppl = math.exp(min(loss.item(), 20))
                probing.event(
                    "train.metrics",
                    attributes=[{"step": step}, {"loss": round(loss.item(), 4)}, {"ppl": round(ppl, 2)}],
                )
                print(f"  step={step:2d} loss={loss.item():.4f} ppl={ppl:.2f}")

    n_params = sum(p.numel() for p in model.parameters())
    print(f"Done. params={n_params:,} steps={steps}")


if __name__ == "__main__":
    main()
