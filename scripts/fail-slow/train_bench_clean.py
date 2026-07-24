#!/usr/bin/env python3
"""train_bench_clean.py — 纯净训练微基准（无任何注入代码）。

所有 phase 使用完全相同的这个脚本。
注入通过外部 sidecar 进程实现，检测器通过环境变量（LD_PRELOAD / PROBING）叠加。
本脚本不感知注入和检测器的存在。

输出: <out_dir>/rank_<global_rank>.jsonl
每行: {"step": i, "step_ms": ..., "loss": ..., "rank": ..., "node_rank": ..., "ts": ...}
"""
from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters", type=int, default=100)
    ap.add_argument("--warmup", type=int, default=10)
    ap.add_argument("--seq", type=int, default=2048)
    ap.add_argument("--hidden", type=int, default=2048)
    ap.add_argument("--layers", type=int, default=8)
    ap.add_argument("--ffn", type=int, default=8192)
    ap.add_argument("--batch", type=int, default=1)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()

    import torch
    import torch.distributed as dist
    import torch.nn as nn
    import torch.nn.functional as F

    torch.manual_seed(args.seed)
    torch.cuda.manual_seed_all(args.seed)

    dist.init_process_group(backend="nccl")
    rank = dist.get_rank()
    world = dist.get_world_size()
    local = int(os.environ.get("LOCAL_RANK", 0))
    node_rank = int(os.environ.get("GROUP_RANK", os.environ.get("NODE_RANK", "0")))
    torch.cuda.set_device(local)
    device = f"cuda:{local}"

    class Block(nn.Module):
        def __init__(self, h: int, ffn: int):
            super().__init__()
            self.ln1 = nn.LayerNorm(h)
            self.qkv = nn.Linear(h, 3 * h, bias=False)
            self.proj = nn.Linear(h, h, bias=False)
            self.ln2 = nn.LayerNorm(h)
            self.fc1 = nn.Linear(h, ffn, bias=False)
            self.fc2 = nn.Linear(ffn, h, bias=False)

        def forward(self, x):
            h = self.ln1(x)
            qkv = self.qkv(h)
            q, k, v = qkv.chunk(3, dim=-1)
            att = torch.matmul(q, k.transpose(-1, -2)) / (q.shape[-1] ** 0.5)
            att = torch.softmax(att, dim=-1)
            h = torch.matmul(att, v)
            x = x + self.proj(h)
            h = self.ln2(x)
            x = x + self.fc2(F.gelu(self.fc1(h)))
            return x

    class TinyGPT(nn.Module):
        def __init__(self):
            super().__init__()
            self.emb = nn.Embedding(32000, args.hidden)
            self.blocks = nn.ModuleList(
                [Block(args.hidden, args.ffn) for _ in range(args.layers)]
            )
            self.ln = nn.LayerNorm(args.hidden)
            self.head = nn.Linear(args.hidden, 32000, bias=False)

        def forward(self, idx):
            x = self.emb(idx)
            for b in self.blocks:
                x = b(x)
            return self.head(self.ln(x))

    model = TinyGPT().to(device=device, dtype=torch.bfloat16)
    opt = torch.optim.AdamW(model.parameters(), lr=1e-4)
    B, S = args.batch, args.seq

    def step():
        idx = torch.randint(0, 32000, (B, S), device=device)
        opt.zero_grad(set_to_none=True)
        logits = model(idx)
        loss = F.cross_entropy(logits.float().reshape(-1, 32000), idx.reshape(-1))
        loss.backward()
        for p in model.parameters():
            if p.grad is not None:
                dist.all_reduce(p.grad)
                p.grad.mul_(1.0 / world)
        opt.step()
        torch.cuda.synchronize()
        return float(loss.detach().cpu())

    # Warmup (同样的训练逻辑)
    for _ in range(args.warmup):
        step()
    dist.barrier()

    # 写一个 marker 文件表示 warmup 完成（供外部编排脚本检测）
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    if rank == 0:
        (out_dir / "warmup_done").write_text(str(time.time()))

    # Measure
    out_file = out_dir / f"rank_{rank:04d}.jsonl"
    records = []
    for i in range(args.iters):
        t0 = time.perf_counter()
        loss = step()
        t1 = time.perf_counter()
        step_ms = (t1 - t0) * 1e3
        records.append({
            "step": i,
            "step_ms": round(step_ms, 3),
            "loss": round(loss, 6),
            "rank": rank,
            "local_rank": local,
            "node_rank": node_rank,
            "world_size": world,
            "ts": round(time.time(), 3),
        })

    dist.barrier()

    with out_file.open("w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")

    if rank == 0:
        avg = sum(r["step_ms"] for r in records) / len(records)
        print(f"DONE world={world} avg_step_ms={avg:.1f} total={sum(r['step_ms'] for r in records)/1000:.1f}s")

    dist.destroy_process_group()


if __name__ == "__main__":
    main()
