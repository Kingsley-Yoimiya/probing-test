#!/usr/bin/env python3
"""64-rank 端到端训练微基准 v2（支持模型内注入）。

新增: 通过环境变量在指定 rank 注入 fail-slow:
  INJECT_CASE=none|3a|3b|8a|9a|9b|9c|2a|5b
  INJECT_RANK=7        (哪个 local_rank 被注入, default=7)
  INJECT_DELAY_STEPS=0 (前 N 步不注入, 用于对照)
  INJECT_DUTY=0.5      (注入强度 0~1)

注入在 step() 内部执行，完全避免 sidecar 与 MCCL init 冲突。
"""
from __future__ import annotations

import argparse
import gc
import json
import os
import time
import threading
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters", type=int, default=30)
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

    # === Injection config ===
    inject_case = os.environ.get("INJECT_CASE", "none")
    inject_rank = int(os.environ.get("INJECT_RANK", "7"))
    inject_delay = int(os.environ.get("INJECT_DELAY_STEPS", "0"))
    inject_duty = float(os.environ.get("INJECT_DUTY", "0.5"))
    is_victim = (local == inject_rank) and (node_rank == 0)

    # Injection state
    _gc_garbage = []
    _bandwidth_tensor = None

    def inject_before_step(step_idx: int):
        """Called BEFORE each step on victim rank."""
        if not is_victim or inject_case == "none":
            return
        if step_idx < inject_delay:
            return

        if inject_case == "3a":
            # GPU 算力抢占: 在同一 device 上做额外 GEMM
            N = 2048
            A = torch.randn(N, N, device=device, dtype=torch.float16)
            B = torch.randn(N, N, device=device, dtype=torch.float16)
            busy_ms = inject_duty * 50  # duty * period
            t0 = time.perf_counter()
            while (time.perf_counter() - t0) * 1000 < busy_ms:
                torch.mm(A, B)
            torch.cuda.synchronize()

        elif inject_case == "3b":
            # HBM 带宽争用: memory-bound copy
            nonlocal _bandwidth_tensor
            if _bandwidth_tensor is None:
                _bandwidth_tensor = torch.randn(64 * 1024 * 1024, device=device)  # 256MB
            dst = torch.empty_like(_bandwidth_tensor)
            copies = max(1, int(inject_duty * 5))
            for _ in range(copies):
                dst.copy_(_bandwidth_tensor)
            torch.cuda.synchronize()

        elif inject_case == "8a":
            # GC 骤停: 分配大量 Python 对象触发 GC
            nonlocal _gc_garbage
            _gc_garbage = [bytearray(10240) for _ in range(int(inject_duty * 5000))]
            del _gc_garbage
            _gc_garbage = []
            gc.collect()

        elif inject_case == "9a":
            # CPU 忙等 (模拟 CPU 争用)
            busy_ms = inject_duty * 50
            t0 = time.perf_counter()
            x = 1.0
            while (time.perf_counter() - t0) * 1000 < busy_ms:
                x = x * 1.0001 + 0.0001  # busy loop

        elif inject_case == "9b":
            # 磁盘 IO 压力: 写大文件
            size_mb = int(inject_duty * 10)
            with open("/tmp/inject_9b_trash", "wb") as f:
                f.write(os.urandom(size_mb * 1024 * 1024))

        elif inject_case == "9c":
            # 内存带宽争用: 大数组 memcpy
            size = int(inject_duty * 100 * 1024 * 1024)  # up to 100MB
            src = bytearray(size)
            dst = bytearray(size)
            dst[:] = src

        elif inject_case == "2a":
            # 显存碎片化: 分配释放不同尺寸张量
            frags = []
            for s in [1024, 4096, 16384, 65536, 262144]:
                frags.append(torch.empty(s, device=device))
            for i in range(0, len(frags), 2):
                del frags[i]
                frags[i] = None
            frags = [f for f in frags if f is not None]
            del frags

        elif inject_case == "5b":
            # 通信降速: 在 AllReduce 前插入额外小通信
            dummy = torch.ones(1024, device=device)
            dist.all_reduce(dummy)  # extra small allreduce

    # === Model ===
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

    def step(step_idx: int):
        inject_before_step(step_idx)
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

    # Warmup (no injection)
    for _ in range(args.warmup):
        step(-1)
    dist.barrier()

    # Measure
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"rank_{rank:04d}.jsonl"

    records = []
    for i in range(args.iters):
        t0 = time.perf_counter()
        loss = step(i)
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
            "injected": is_victim and inject_case != "none" and i >= inject_delay,
        })

    dist.barrier()

    with out_file.open("w") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")

    if rank == 0:
        avg = sum(r["step_ms"] for r in records) / len(records)
        summary = {
            "world_size": world, "iters": args.iters, "warmup": args.warmup,
            "avg_step_ms": round(avg, 2), "seed": args.seed,
            "inject_case": inject_case, "inject_rank": inject_rank,
            "inject_duty": inject_duty, "inject_delay_steps": inject_delay,
        }
        with (out_dir / "summary.json").open("w") as f:
            json.dump(summary, f, indent=2)
        print(f"DONE world={world} avg_step_ms={avg:.1f} case={inject_case} "
              f"victim={'rank'+str(inject_rank) if inject_case!='none' else 'none'}")

    dist.destroy_process_group()


if __name__ == "__main__":
    main()
