#!/usr/bin/env python3
"""train_bench_probe_npu.py — Ascend/NPU 版 GPT-2 训练微基准。

与共享 train_bench_probe.py 同构（jsonl 字段 / measure marker / host_bound），
仅把 CUDA/NCCL 换成 torch_npu + HCCL。勿把本文件逻辑回灌坏沐曦默认脚本。
"""
from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path


def _activate_probing_if_requested() -> None:
    val = os.environ.get("PROBING", "0").strip().lower()
    if val in ("", "0", "off", "false", "no"):
        return
    try:
        from probing.site_hook import run_site_hook

        run_site_hook()
    except Exception as exc:  # noqa: BLE001
        print(f"[train_bench_probe_npu] probing site_hook failed: {exc}", flush=True)


_activate_probing_if_requested()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters", type=int, default=500)
    ap.add_argument("--warmup", type=int, default=50)
    ap.add_argument("--model", choices=["gpt2", "tiny"], default="gpt2")
    ap.add_argument("--seq", type=int, default=1024)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--hidden", type=int, default=None)
    ap.add_argument("--layers", type=int, default=None)
    ap.add_argument("--ffn", type=int, default=None)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--mode", choices=["gpu_bound", "host_bound"], default="host_bound")
    ap.add_argument("--flush-every", type=int, default=5)
    ap.add_argument("--ckpt-every", type=int, default=100)
    ap.add_argument("--decompose", type=int, default=1)
    ap.add_argument("--dl-workers", type=int, default=2)
    ap.add_argument("--io-payload", default="")
    ap.add_argument("--io-read-kb", type=int, default=0)
    ap.add_argument("--run-id", default="")
    ap.add_argument("--group", default="")
    ap.add_argument("--config", default="")
    ap.add_argument("--round", type=int, default=0)
    args = ap.parse_args()

    import torch
    import torch.distributed as dist
    import torch.nn as nn
    import torch.nn.functional as F
    import torch_npu  # noqa: F401  — register npu backend
    from torch.nn.parallel import DistributedDataParallel as DDP

    torch.manual_seed(args.seed)
    if hasattr(torch.npu, "manual_seed_all"):
        torch.npu.manual_seed_all(args.seed)

    dist.init_process_group(backend="hccl")
    rank = dist.get_rank()
    world = dist.get_world_size()
    local = int(os.environ.get("LOCAL_RANK", 0))
    node_rank = int(os.environ.get("GROUP_RANK", os.environ.get("NODE_RANK", "0")))
    torch.npu.set_device(local)
    device = torch.device(f"npu:{local}")

    if args.model == "gpt2":
        hidden, layers, ffn, vocab = 768, 12, 3072, 50257
    else:
        hidden, layers, ffn, vocab = 256, 4, 1024, 32000
    hidden = args.hidden or hidden
    layers = args.layers or layers
    ffn = args.ffn or ffn

    class Block(nn.Module):
        def __init__(self, h: int, ffn_: int):
            super().__init__()
            self.ln1 = nn.LayerNorm(h)
            self.qkv = nn.Linear(h, 3 * h, bias=False)
            self.proj = nn.Linear(h, h, bias=False)
            self.ln2 = nn.LayerNorm(h)
            self.fc1 = nn.Linear(h, ffn_, bias=False)
            self.fc2 = nn.Linear(ffn_, h, bias=False)

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

    class GPT2Bench(nn.Module):
        def __init__(self):
            super().__init__()
            self.emb = nn.Embedding(vocab, hidden)
            self.pos = nn.Embedding(args.seq, hidden)
            self.blocks = nn.ModuleList([Block(hidden, ffn) for _ in range(layers)])
            self.ln = nn.LayerNorm(hidden)
            self.head = nn.Linear(hidden, vocab, bias=False)
            self.head.weight = self.emb.weight

        def forward(self, idx):
            positions = torch.arange(idx.shape[1], device=idx.device)
            x = self.emb(idx) + self.pos(positions)[None, :, :]
            for b in self.blocks:
                x = b(x)
            return self.head(self.ln(x))

    model = GPT2Bench().to(device=device, dtype=torch.bfloat16)
    model = DDP(model, device_ids=[local], output_device=local)
    opt = torch.optim.AdamW(model.parameters(), lr=1e-4)
    B, S = args.batch, args.seq

    import numpy as np
    from torch.utils.data import DataLoader, Dataset

    io_payload = (args.io_payload or "").strip()
    io_read = max(0, int(args.io_read_kb)) * 1024
    if args.mode == "host_bound" and io_payload and io_read > 0:
        p = Path(io_payload)
        if not p.is_file() or p.stat().st_size < io_read:
            if rank == 0:
                p.parent.mkdir(parents=True, exist_ok=True)
                with open(p, "wb") as wf:
                    chunk = b"\0" * (1024 * 1024)
                    for _ in range(256):
                        wf.write(chunk)
            dist.barrier()

    host_matmul = int(os.environ.get("HOST_BOUND_MATMUL", "768"))

    class TokenDataset(Dataset):
        def __len__(self):
            return args.iters * 100

        def __getitem__(self, i):
            rng = np.random.default_rng(i)
            buf = rng.integers(0, vocab, size=(S,), dtype=np.int64)
            if args.mode == "host_bound":
                n = max(64, host_matmul)
                _ = (rng.standard_normal((n, n)) @ rng.standard_normal((n, n))).sum()
                if io_payload and io_read > 0:
                    try:
                        fsz = os.path.getsize(io_payload)
                        off = (int(rng.integers(0, max(1, fsz - io_read))) // 4096) * 4096
                        fd = os.open(io_payload, os.O_RDONLY)
                        try:
                            os.pread(fd, io_read, off)
                        finally:
                            os.close(fd)
                    except OSError:
                        pass
            return torch.from_numpy(buf)

    dl = DataLoader(
        TokenDataset(),
        batch_size=B,
        num_workers=args.dl_workers,
        pin_memory=False,
        prefetch_factor=2,
        persistent_workers=(args.dl_workers > 0),
    )
    data_iter = iter(dl)

    decompose = bool(args.decompose)
    if decompose:
        e_c0, e_c1 = torch.npu.Event(enable_timing=True), torch.npu.Event(enable_timing=True)
        e_m0, e_m1 = torch.npu.Event(enable_timing=True), torch.npu.Event(enable_timing=True)

    def get_batch():
        nonlocal data_iter
        try:
            b = next(data_iter)
        except StopIteration:
            data_iter = iter(dl)
            b = next(data_iter)
        return b.to(device, non_blocking=True)

    def step_instrumented(
        force_gc: bool = False,
        gc_stall_s: float = 0.0,
        hbm_bufs=None,
        hbm_copies: int = 0,
        cube_bufs=None,
        cube_mm: int = 0,
    ):
        t0 = time.perf_counter()
        if force_gc:
            import gc as _gc_mod

            _gc_mod.collect()
            if gc_stall_s > 0:
                time.sleep(gc_stall_s)
        idx = get_batch()
        t_data = time.perf_counter()

        if hbm_bufs is not None and hbm_copies > 0:
            src, dst = hbm_bufs
            for _ in range(hbm_copies):
                dst.copy_(src)
                src.copy_(dst)
            torch.npu.synchronize()

        # P1-EXT-A：同进程 cube（外挂 sidecar 在 Ascend 上进程隔离、咬合比≈1.0）
        if cube_bufs is not None and cube_mm > 0:
            ca, cb = cube_bufs
            for _ in range(cube_mm):
                torch.mm(ca, cb)
            torch.npu.synchronize()

        opt.zero_grad(set_to_none=True)
        if decompose:
            e_c0.record()
        logits = model(idx)
        loss = F.cross_entropy(logits.float().reshape(-1, vocab), idx.reshape(-1))
        loss.backward()
        if decompose:
            e_c1.record()
            torch.npu.synchronize()
            t_arrive = time.perf_counter()
            dist.barrier()
            t_bar = time.perf_counter()
            e_m0.record()

        if decompose:
            e_m1.record()
        opt.step()
        torch.npu.synchronize()
        t1 = time.perf_counter()

        if decompose:
            compute_ms = e_c0.elapsed_time(e_c1)
            comm_ms = e_m0.elapsed_time(e_m1)
            wait_ms = (t_bar - t_arrive) * 1e3
            data_ms = (t_data - t0) * 1e3
        else:
            compute_ms = comm_ms = wait_ms = 0.0
            data_ms = (t_data - t0) * 1e3
        step_ms = (t1 - t0) * 1e3
        return data_ms, compute_ms, comm_ms, wait_ms, step_ms, float(loss.detach().cpu())

    for _ in range(args.warmup):
        step_instrumented()
    dist.barrier()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    if rank == 0:
        (out_dir / "warmup_done").write_text(str(time.time()))

    out_file = out_dir / f"rank_{rank:04d}.jsonl"
    meta_common = {
        "rank": rank,
        "local_rank": local,
        "node_rank": node_rank,
        "world_size": world,
        "run_id": args.run_id,
        "group": args.group,
        "config": args.config,
        "round": args.round,
        "mode": args.mode,
        "backend": "npu_hccl",
    }
    inline = os.environ.get("INLINE_INJECT", "").strip()
    inline_victim = int(
        os.environ.get(
            "INLINE_VICTIM_LOCAL_RANK",
            str(max(0, int(os.environ.get("LOCAL_WORLD_SIZE", "8")) - 1)),
        )
    )
    inline_start = int(os.environ.get("INLINE_INJECT_START", "100"))
    inline_stop = int(os.environ.get("INLINE_INJECT_STOP", "300"))
    inline_gc_every = max(1, int(os.environ.get("INLINE_GC_EVERY", "1")))
    inline_gc_stall_s = float(os.environ.get("INLINE_GC_STALL_S", "0.25"))
    do_inline_8a = inline == "8a" and local == inline_victim and node_rank == 0
    do_inline_hbm = inline == "hbm" and local == inline_victim and node_rank == 0
    do_inline_cube = inline == "cube" and local == inline_victim and node_rank == 0
    leak_buf: list = []
    hbm_bufs = None
    cube_bufs = None
    hbm_copies = max(1, int(os.environ.get("INLINE_HBM_COPIES", "6")))
    cube_mm = max(1, int(os.environ.get("INLINE_CUBE_MM", "8")))
    cube_size = max(256, int(os.environ.get("INLINE_CUBE_SIZE", "4096")))
    if do_inline_hbm:
        hbm_mb = max(32, min(int(os.environ.get("INLINE_HBM_MB", "256")), 1024))
        ne = hbm_mb * 1024 * 1024 // 2
        src = torch.randn(ne, device=device, dtype=torch.float16)
        dst = torch.empty_like(src)
        hbm_bufs = (src, dst)
        print(f"INLINE_HBM_ALLOC mb={hbm_mb} copies/step={hbm_copies}", flush=True)
    if do_inline_cube:
        # Loud 起点：4096×8 mm/step；咬空再抬 INLINE_CUBE_MM / SIZE
        ca = torch.randn(cube_size, cube_size, device=device, dtype=torch.float16)
        cb = torch.randn(cube_size, cube_size, device=device, dtype=torch.float16)
        for _ in range(2):
            torch.mm(ca, cb)
        torch.npu.synchronize()
        cube_bufs = (ca, cb)
        print(
            f"INLINE_CUBE_ALLOC size={cube_size} mm/step={cube_mm} victim_local={inline_victim}",
            flush=True,
        )
    ckpt_dir = Path(os.environ.get("CKPT_DIR", "/data/yinjinrun.p-huawei/probe-bundle/ckpt"))

    f = out_file.open("a", buffering=1)
    try:
        for i in range(args.iters):
            in_win_8a = bool(do_inline_8a and inline_start <= i < inline_stop)
            in_win_hbm = bool(do_inline_hbm and inline_start <= i < inline_stop)
            in_win_cube = bool(do_inline_cube and inline_start <= i < inline_stop)
            if in_win_8a:
                leak_buf.append(bytearray(1024 * 4 * 1024))
            force_gc = bool(
                do_inline_8a
                and (
                    (in_win_8a and ((i - inline_start) % inline_gc_every) == 0)
                    or ((i + 1) == inline_stop)
                )
            )
            data_ms, compute_ms, comm_ms, wait_ms, step_ms, loss = step_instrumented(
                force_gc=force_gc,
                gc_stall_s=(inline_gc_stall_s if force_gc else 0.0),
                hbm_bufs=(hbm_bufs if in_win_hbm else None),
                hbm_copies=(hbm_copies if in_win_hbm else 0),
                cube_bufs=(cube_bufs if in_win_cube else None),
                cube_mm=(cube_mm if in_win_cube else 0),
            )
            rec = {
                "step": i,
                "data_ms": round(data_ms, 3),
                "compute_ms": round(compute_ms, 3),
                "comm_ms": round(comm_ms, 3),
                "wait_ms": round(wait_ms, 3),
                "step_ms": round(step_ms, 3),
                "loss": round(loss, 6),
                "ts": round(time.time(), 3),
                **meta_common,
            }
            f.write(json.dumps(rec) + "\n")
            if (i + 1) % args.flush_every == 0:
                f.flush()
                os.fsync(f.fileno())
            if rank == 0 and (i + 1) in {100, 300}:
                (out_dir / f"step_{i + 1}.marker").write_text(str(time.time()))
            ckpt_every = max(1, int(args.ckpt_every))
            if rank == 0 and (i + 1) % ckpt_every == 0:
                ckpt_dir.mkdir(parents=True, exist_ok=True)
                torch.save(
                    {"step": i + 1, "model": model.module.state_dict()},
                    ckpt_dir / f"step_{i + 1}.pt",
                )
    finally:
        f.flush()
        try:
            os.fsync(f.fileno())
        except OSError:
            pass
        f.close()

    dist.barrier()
    if rank == 0:
        print(f"DONE world={world} out={out_file}", flush=True)
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
