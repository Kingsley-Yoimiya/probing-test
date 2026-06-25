#!/usr/bin/env python3
"""
Megatron-LM 风格可参数化 GPT 训练脚本。

Presets 控制模型规模与训练超参；probing 行为由环境变量 / 外部 CLI 控制。
"""
from __future__ import annotations

import argparse
import math
import os
import time
from dataclasses import dataclass

import probing
import torch
import torch.distributed as dist
import torch.nn as nn
import torch.nn.functional as F
from torch.nn.parallel import DistributedDataParallel as DDP


@dataclass(frozen=True)
class TrainConfig:
    name: str
    vocab: int = 256
    d_model: int = 128
    n_layers: int = 4
    n_heads: int = 4
    seq_len: int = 32
    batch: int = 8
    steps: int = 20
    lr: float = 3e-4
    micro_batches: int = 1
    step_sleep: float = 0.0
    manual_spans: bool = False
    use_torch_probe: bool = False


PRESETS: dict[str, TrainConfig] = {
    "tiny": TrainConfig(name="tiny"),
    "deep": TrainConfig(name="deep", n_layers=8, steps=15),
    "wide": TrainConfig(name="wide", d_model=256, n_heads=8, steps=15),
    "long_seq": TrainConfig(
        name="long_seq", seq_len=128, batch=4, steps=12, step_sleep=0.15
    ),
    "large_batch": TrainConfig(name="large_batch", batch=32, steps=12),
    "grad_accum": TrainConfig(
        name="grad_accum", micro_batches=4, steps=16, step_sleep=0.1
    ),
    "many_step": TrainConfig(name="many_step", steps=30, step_sleep=0.2),
}


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
        return x + self.ff(self.ln2(x))


class MiniGPT(nn.Module):
    def __init__(self, cfg: TrainConfig) -> None:
        super().__init__()
        d_ff = cfg.d_model * 4
        max_pos = max(cfg.seq_len * 2, 128)
        self.embed = nn.Embedding(cfg.vocab, cfg.d_model)
        self.pos = nn.Embedding(max_pos, cfg.d_model)
        self.blocks = nn.ModuleList(
            [
                MiniGPTBlock(cfg.d_model, cfg.n_heads, d_ff)
                for _ in range(cfg.n_layers)
            ]
        )
        self.ln_f = nn.LayerNorm(cfg.d_model)
        self.head = nn.Linear(cfg.d_model, cfg.vocab)

    def forward(self, idx: torch.Tensor) -> torch.Tensor:
        b, t = idx.shape
        pos = torch.arange(t, device=idx.device).unsqueeze(0).expand(b, t)
        x = self.embed(idx) + self.pos(pos)
        for block in self.blocks:
            x = block(x)
        return self.head(self.ln_f(x))


def _setup_device() -> tuple[torch.device, int, bool]:
    if dist.is_initialized():
        local_rank = int(os.environ.get("LOCAL_RANK", "0"))
        device = torch.device(f"cuda:{local_rank}")
        torch.cuda.set_device(device)
        return device, local_rank, True
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    return device, 0, False


def _train_step(
    model: nn.Module,
    optimizer: torch.optim.Optimizer,
    cfg: TrainConfig,
    device: torch.device,
    step: int,
    *,
    do_step: bool = True,
    do_zero: bool = True,
) -> float:
    vocab = cfg.vocab
    idx = torch.randint(0, vocab, (cfg.batch, cfg.seq_len), device=device)
    targets = idx.clone()

    ctx = probing.span("forward") if cfg.manual_spans else nullcontext()
    with ctx:
        logits = model(idx)

    loss = F.cross_entropy(logits.view(-1, vocab), targets.view(-1))
    if do_zero:
        optimizer.zero_grad(set_to_none=True)
    loss.backward()
    if do_step:
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        optimizer.step()

    if step % max(1, cfg.steps // 4) == 0:
        ppl = math.exp(min(loss.item(), 20))
        probing.event(
            "train.metrics",
            attributes=[
                {"step": step},
                {"loss": round(loss.item(), 4)},
                {"ppl": round(ppl, 2)},
                {"preset": cfg.name},
            ],
        )
        rank = dist.get_rank() if dist.is_initialized() else 0
        if rank == 0:
            print(
                f"  step={step:3d} loss={loss.item():.4f} ppl={ppl:.2f} "
                f"micro={probing.step.micro_step} local={probing.step.local_step}",
                flush=True,
            )

    if cfg.step_sleep > 0:
        time.sleep(cfg.step_sleep)
    return float(loss.item())


class nullcontext:
    def __enter__(self):
        return None

    def __exit__(self, *args):
        return False


def main() -> None:
    parser = argparse.ArgumentParser(description="Mini Megatron GPT trainer")
    parser.add_argument("--preset", choices=sorted(PRESETS), default="tiny")
    parser.add_argument("--steps", type=int, default=None)
    parser.add_argument("--step-sleep", type=float, default=None)
    parser.add_argument("--manual-spans", action="store_true")
    parser.add_argument("--no-phase-hook", action="store_true")
    args = parser.parse_args()

    if int(os.environ.get("WORLD_SIZE", "1")) > 1:
        dist.init_process_group(backend="nccl")

    cfg = PRESETS[args.preset]
    if args.steps is not None:
        cfg = TrainConfig(**{**cfg.__dict__, "steps": args.steps})
    if args.step_sleep is not None:
        cfg = TrainConfig(**{**cfg.__dict__, "step_sleep": args.step_sleep})
    if args.manual_spans:
        cfg = TrainConfig(**{**cfg.__dict__, "manual_spans": True})

    device, local_rank, is_ddp = _setup_device()
    rank = dist.get_rank() if dist.is_initialized() else 0

    pid = os.getpid()
    if rank == 0:
        print(
            f"MEGATRON preset={cfg.name} pid={pid} device={device} "
            f"probing={probing.is_enabled()} ddp={is_ddp}",
            flush=True,
        )
        print(
            f"  layers={cfg.n_layers} d_model={cfg.d_model} heads={cfg.n_heads} "
            f"seq={cfg.seq_len} batch={cfg.batch} steps={cfg.steps} "
            f"micro_batches={cfg.micro_batches}",
            flush=True,
        )

    if cfg.use_torch_probe or os.environ.get("PROBING_TORCH_PROFILING"):
        from probing.profiling.torch_probe import configure

        configure(os.environ.get("PROBING_TORCH_PROFILING", "on"))

    if cfg.micro_batches > 1:
        probing.step(micro_batches=cfg.micro_batches)

    with probing.span("model-init"):
        model = MiniGPT(cfg).to(device)
        optimizer = torch.optim.AdamW(model.parameters(), lr=cfg.lr)
        if is_ddp:
            model = DDP(model, device_ids=[local_rank])
            core = model.module
        else:
            core = model

    if not args.no_phase_hook:
        probing.attach_training_phases(core, optimizer)

    n_params = sum(p.numel() for p in core.parameters())
    if rank == 0:
        print(f"  params={n_params:,}", flush=True)

    with probing.span("train-loop"):
        for step in range(cfg.steps):
            train_model = model if is_ddp else core
            if cfg.micro_batches > 1:
                for micro in range(cfg.micro_batches):
                    is_last = micro == cfg.micro_batches - 1
                    _train_step(
                        train_model,
                        optimizer,
                        cfg,
                        device,
                        step,
                        do_zero=(micro == 0),
                        do_step=is_last,
                    )
            else:
                _train_step(train_model, optimizer, cfg, device, step)

    if rank == 0:
        print(f"DONE preset={cfg.name} steps={cfg.steps}", flush=True)

    if dist.is_initialized():
        dist.barrier()
        dist.destroy_process_group()


if __name__ == "__main__":
    main()
