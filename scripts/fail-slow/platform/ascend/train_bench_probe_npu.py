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
    # Pillar-C S1：PROBING_ATTACH_AT_STEP 时延后到训练步再 import/site_hook
    # （Ascend hold 无独立 libprobing.so，无法依赖 CLI ptrace inject）
    if os.environ.get("PROBING_ATTACH_AT_STEP", "").strip():
        print(
            "[train_bench_probe_npu] probing deferred → PROBING_ATTACH_AT_STEP="
            f"{os.environ.get('PROBING_ATTACH_AT_STEP')}",
            flush=True,
        )
        return
    val = os.environ.get("PROBING", "0").strip().lower()
    if val in ("", "0", "off", "false", "no"):
        return
    try:
        from probing.site_hook import run_site_hook

        run_site_hook()
    except Exception as exc:  # noqa: BLE001
        print(f"[train_bench_probe_npu] probing site_hook failed: {exc}", flush=True)


def _maybe_mid_attach_probing(step: int, out_dir: Path, rank: int) -> None:
    """S1 中途接入：在指定 step 首次 import probing / run_site_hook。"""
    raw = os.environ.get("PROBING_ATTACH_AT_STEP", "").strip()
    if not raw:
        return
    try:
        at = int(raw)
    except ValueError:
        return
    if int(step) != at:
        return
    val = os.environ.get("PROBING", "0").strip().lower()
    if val in ("", "0", "off", "false", "no"):
        os.environ["PROBING"] = os.environ.get("PROBING_DEFERRED_VALUE", "2")
    ts = time.time()
    try:
        import probing.site_hook as sh
        from probing.site_hook import run_site_hook

        if getattr(sh, "_RAN", False):
            import probing  # noqa: F401
        else:
            run_site_hook()
        print(f"PROBING_MID_ATTACH_OK step={step} ts={ts}", flush=True)
        if rank == 0:
            (out_dir / "probing_mid_attach.marker").write_text(
                f"step={step}\nts={ts}\n", encoding="utf-8"
            )
    except Exception as exc:  # noqa: BLE001
        print(f"PROBING_MID_ATTACH_FAIL step={step} err={exc}", flush=True)
        if rank == 0:
            (out_dir / "probing_mid_attach.fail").write_text(
                f"step={step}\nts={ts}\nerr={exc}\n", encoding="utf-8"
            )


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

    # rare-shape：pos 表按 max(base_seq, RARE_SHAPE_SEQ) 分配，避免窗内拉长 seq 越界
    _inline_early = os.environ.get("INLINE_INJECT", "").strip()
    if _inline_early in ("2b", "rare_shape"):
        _rare_pos = max(1, int(os.environ.get("RARE_SHAPE_SEQ", "1536")))
        pos_max = max(args.seq, _rare_pos)
    else:
        pos_max = args.seq

    class GPT2Bench(nn.Module):
        def __init__(self):
            super().__init__()
            self.emb = nn.Embedding(vocab, hidden)
            self.pos = nn.Embedding(pos_max, hidden)
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
        data_stall_s: float = 0.0,
        hbm_bufs=None,
        hbm_copies: int = 0,
        cube_bufs=None,
        cube_mm: int = 0,
        frag_action=None,
        seq_override: int | None = None,
        compile_spike_n: int = 0,
    ):
        t0 = time.perf_counter()
        frag_stall_ms = 0.0
        if force_gc:
            import gc as _gc_mod

            _gc_mod.collect()
            if gc_stall_s > 0:
                time.sleep(gc_stall_s)
        # P3-SW-B：dataloader 阻塞必须落在计时区内，否则 accept(rank0 step_ms) 咬空
        if data_stall_s > 0:
            time.sleep(data_stall_s)
        idx = get_batch()
        # P1-SW-B：victim 窗内改用罕见 seq（pad/truncate）；非 victim / 窗外保持 base --seq
        if seq_override is not None and int(seq_override) != int(idx.shape[1]):
            tgt = int(seq_override)
            if idx.shape[1] > tgt:
                idx = idx[:, :tgt]
            else:
                pad = torch.randint(
                    0,
                    vocab,
                    (idx.shape[0], tgt - idx.shape[1]),
                    device=idx.device,
                    dtype=idx.dtype,
                )
                idx = torch.cat([idx, pad], dim=1)
        shape_seq = int(idx.shape[1])
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

        # P1-SW-C / 2c：清 inductor 缓存 + 未见 shape 的 torch.compile one-shot（计时区内）
        # Ascend 上 compile 常失败。裸 sleep 只抬 step_ms、不进 torch_trace module duration；
        # 归因尺要 post-forward duration≥0.4s 且≥3×中位 → 必须走 nn.Module.forward
        #（probing hook 记 wall duration）。默认 stall≥0.6s（旧 0.25 低于 0.4 阈值）。
        if compile_spike_n > 0:
            import shutil as _shutil

            _cache = os.environ.get(
                "TORCHINDUCTOR_CACHE_DIR",
                "/tmp/p1swc_inductor_cache",
            )
            stall = float(os.environ.get("INLINE_2C_FALLBACK_S", "0.6"))
            compile_ok = False
            try:
                if os.path.isdir(_cache):
                    _shutil.rmtree(_cache, ignore_errors=True)
                os.makedirs(_cache, exist_ok=True)
                os.environ["TORCHINDUCTOR_CACHE_DIR"] = _cache
                _n = int(compile_spike_n)

                def _spike_mm(a, b):
                    return a @ b

                _spike = torch.compile(_spike_mm)
                _a = torch.randn(_n, _n, device=device, dtype=torch.bfloat16)
                _b = torch.randn(_n, _n, device=device, dtype=torch.bfloat16)
                _c = _spike(_a, _b)
                torch.npu.synchronize()
                del _a, _b, _c, _spike
                compile_ok = True
                print(f"INLINE_2C_SPIKE_OK n={_n}", flush=True)
            except Exception as exc:  # noqa: BLE001
                print(f"INLINE_2C_COMPILE_FAIL err={exc}", flush=True)

            # 可复现 torch_trace duration 尖刺（E1 / ②-A 归因尺）；与 compile 成败无关
            class _P1SwcDurationSpike(torch.nn.Module):
                def __init__(self, stall_s: float):
                    super().__init__()
                    self.stall_s = float(stall_s)
                    self._bias = torch.nn.Parameter(
                        torch.zeros(1, device=device), requires_grad=False
                    )

                def forward(self, x):
                    t0 = time.perf_counter()
                    # wall stall inside forward → probing post-forward duration
                    while time.perf_counter() - t0 < self.stall_s:
                        time.sleep(0.01)
                    return x + self._bias

            _m = _P1SwcDurationSpike(stall).to(device)
            _x = torch.zeros(1, device=device)
            with torch.no_grad():
                _ = _m(_x)
            print(
                f"INLINE_2C_DURATION_SPIKE stall_s={stall} compile_ok={int(compile_ok)}",
                flush=True,
            )
            del _m, _x

        # P1-SW-A：碎片累积 + 骤停须在 barrier 前，才能拖全局 step_ms
        if frag_action is not None:
            t_f0 = time.perf_counter()
            live = frag_action.get("live")
            sizes = frag_action.get("sizes") or []
            n_chunks = int(frag_action.get("chunks", 0))
            stall_mb = int(frag_action.get("stall_mb", 0))
            do_stall = bool(frag_action.get("do_stall", False))
            min_stall_s = float(frag_action.get("min_stall_s", 0.0))
            step_i = int(frag_action.get("step", 0))
            if live is not None and n_chunks > 0 and sizes:
                for k in range(n_chunks):
                    sz = sizes[(step_i + k) % len(sizes)]
                    live.append(torch.empty(sz, device=device, dtype=torch.float16))
                if len(live) >= 4:
                    for j in range(0, len(live), 2):
                        live[j] = None  # type: ignore[assignment]
                    live[:] = [t for t in live if t is not None]
            if do_stall and stall_mb > 0:
                ne = stall_mb * 1024 * 1024 // 2
                try:
                    big = torch.empty(ne, device=device, dtype=torch.float16)
                    big.fill_(1)
                    torch.npu.synchronize()
                    del big
                except Exception as exc:  # noqa: BLE001
                    print(f"INLINE_2A_STALL_ALLOC_FAIL: {exc}", flush=True)
                elapsed = time.perf_counter() - t_f0
                if min_stall_s > elapsed:
                    time.sleep(min_stall_s - elapsed)
            frag_stall_ms = (time.perf_counter() - t_f0) * 1e3

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

        # DDP AllReduce 发生在 opt.step() 内；e_m1 必须在 step 之后
        opt.step()
        # P2-SW-B：可选大 AllReduce 负载（C0/C1/C2 同开），使 HCCL_ALGO 钳制可测
        stress_mb = int(os.environ.get("HCCL_STRESS_MB", os.environ.get("MCCL_STRESS_MB", "0")) or "0")
        if stress_mb > 0:
            nelem = max(1, stress_mb * 1024 * 1024 // 4)
            if not hasattr(step_instrumented, "_stress_buf"):
                step_instrumented._stress_buf = torch.randn(
                    nelem, device=device, dtype=torch.float32
                )
            dist.all_reduce(step_instrumented._stress_buf)
        # P2-SW-C：拓扑漂移辅剂量 —— 额外 AllReduce 模拟绕远路（落在 comm 窗，主证可走 comm_ms）
        extra_ar = int(os.environ.get("TOPO_EXTRA_AR", "0") or "0")
        if extra_ar > 0:
            ar_elems = max(1024, int(os.environ.get("TOPO_AR_ELEMS", "1024") or "1024"))
            if (
                not hasattr(step_instrumented, "_topo_ar_buf")
                or step_instrumented._topo_ar_buf.numel() != ar_elems
            ):
                step_instrumented._topo_ar_buf = torch.ones(
                    ar_elems, device=device, dtype=torch.float32
                )
            for _ in range(extra_ar):
                dist.all_reduce(step_instrumented._topo_ar_buf)
        if decompose:
            e_m1.record()
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
        return (
            data_ms,
            compute_ms,
            comm_ms,
            wait_ms,
            step_ms,
            float(loss.detach().cpu()),
            frag_stall_ms,
            shape_seq,
        )

    for _ in range(args.warmup):
        step_instrumented()  # ignore frag_stall / shape_seq
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
    # P3-SW-B：进程内渐进泄漏（外挂 sidecar 在大内存机上咬空）→ leak MB + data_stall
    do_inline_8b = inline == "8b" and local == inline_victim and node_rank == 0
    inline_8b_mb = max(4, int(os.environ.get("INLINE_8B_MB", "16")))
    inline_8b_stall_s = float(os.environ.get("INLINE_8B_STALL_S", "0.25"))
    # P1-EXT-B：固定 copies；P1-HW-B：INLINE_HBM_RAMP=1 或 inline=hbm_ramp → copies 线性升到 MAX
    do_inline_hbm = (
        inline in ("hbm", "hbm_ramp", "1b")
        and local == inline_victim
        and node_rank == 0
    )
    hbm_ramp = bool(
        inline in ("hbm_ramp", "1b")
        or os.environ.get("INLINE_HBM_RAMP", "0").strip() in ("1", "true", "yes")
    )
    do_inline_cube = inline == "cube" and local == inline_victim and node_rank == 0
    do_inline_2a = inline == "2a" and local == inline_victim and node_rank == 0
    # P1-SW-B：罕见 shape（OUTLINE 2B）；仅 victim 在窗内改 seq
    do_inline_2b = (
        inline in ("2b", "rare_shape")
        and local == inline_victim
        and node_rank == 0
    )
    # P1-SW-C：首次编译尖刺（OUTLINE 2C）；仅 victim 在窗内 one-shot compile/fallback
    do_inline_2c = (
        inline in ("2c", "compile_spike")
        and local == inline_victim
        and node_rank == 0
    )
    rare_seq = max(1, int(os.environ.get("RARE_SHAPE_SEQ", "1536")))
    rare_every = max(1, int(os.environ.get("RARE_SHAPE_EVERY", "1")))
    rare_frac_raw = os.environ.get("RARE_SHAPE_FRAC", "").strip()
    rare_frac = float(rare_frac_raw) if rare_frac_raw else None
    compile_every = max(1, int(os.environ.get("INLINE_2C_EVERY", "1")))
    compile_base_n = max(256, int(os.environ.get("INLINE_2C_N", "1024")))
    leak_buf: list = []
    frag_live: list = []
    frag_chunks_per_step = max(1, int(os.environ.get("INLINE_2A_CHUNKS", "12")))
    frag_stall_mb = max(64, int(os.environ.get("INLINE_2A_STALL_MB", "768")))
    frag_min_stall_s = float(os.environ.get("INLINE_2A_STALL_S", "0.25"))
    frag_sizes = [256, 1024, 4096, 16384, 65536, 262144, 524288, 1048576]  # fp16 elems
    hbm_bufs = None
    cube_bufs = None
    hbm_copies = max(1, int(os.environ.get("INLINE_HBM_COPIES", "6")))
    hbm_copies_max = max(hbm_copies, int(os.environ.get("INLINE_HBM_COPIES_MAX", "48")))
    cube_mm = max(1, int(os.environ.get("INLINE_CUBE_MM", "8")))
    cube_size = max(256, int(os.environ.get("INLINE_CUBE_SIZE", "4096")))
    if do_inline_hbm:
        hbm_mb = max(32, min(int(os.environ.get("INLINE_HBM_MB", "256")), 1024))
        ne = hbm_mb * 1024 * 1024 // 2
        src = torch.randn(ne, device=device, dtype=torch.float16)
        dst = torch.empty_like(src)
        hbm_bufs = (src, dst)
        print(
            f"INLINE_HBM_ALLOC mb={hbm_mb} copies/step={hbm_copies} "
            f"ramp={int(hbm_ramp)} copies_max={hbm_copies_max}",
            flush=True,
        )
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
    if do_inline_8b:
        print(
            f"INLINE_8B_LEAK mb/step={inline_8b_mb} data_stall_s={inline_8b_stall_s} "
            f"win=[{inline_start},{inline_stop}) victim_local={inline_victim}",
            flush=True,
        )
    if do_inline_2a:
        print(
            f"INLINE_2A_FRAG chunks/step={frag_chunks_per_step} stall_mb={frag_stall_mb} "
            f"min_stall_s={frag_min_stall_s} win=[{inline_start},{inline_stop})",
            flush=True,
        )
    if do_inline_2b:
        print(
            f"INLINE_RARE_SHAPE seq={rare_seq} every={rare_every} frac={rare_frac} "
            f"win=[{inline_start},{inline_stop}) victim_local={inline_victim}",
            flush=True,
        )
    if do_inline_2c:
        print(
            f"INLINE_2C_COMPILE every={compile_every} base_n={compile_base_n} "
            f"fallback_s={os.environ.get('INLINE_2C_FALLBACK_S', '0.6')} "
            f"win=[{inline_start},{inline_stop}) victim_local={inline_victim}",
            flush=True,
        )
    ckpt_dir = Path(os.environ.get("CKPT_DIR", "/data/yinjinrun.p-huawei/probe-bundle/ckpt"))

    f = out_file.open("a", buffering=1)
    try:
        for i in range(args.iters):
            _maybe_mid_attach_probing(i, out_dir, rank)
            in_win_8a = bool(do_inline_8a and inline_start <= i < inline_stop)
            in_win_8b = bool(do_inline_8b and inline_start <= i < inline_stop)
            in_win_hbm = bool(do_inline_hbm and inline_start <= i < inline_stop)
            in_win_cube = bool(do_inline_cube and inline_start <= i < inline_stop)
            in_win_2a = bool(do_inline_2a and inline_start <= i < inline_stop)
            in_win_2b = bool(do_inline_2b and inline_start <= i < inline_stop)
            in_win_2c = bool(do_inline_2c and inline_start <= i < inline_stop)
            cur_hbm_copies = 0
            if in_win_hbm:
                if hbm_ramp:
                    win_len = max(1, inline_stop - inline_start)
                    frac = (i - inline_start) / float(win_len)
                    cur_hbm_copies = max(
                        1,
                        int(hbm_copies + frac * (hbm_copies_max - hbm_copies)),
                    )
                else:
                    cur_hbm_copies = hbm_copies
            seq_override = None
            if in_win_2b:
                off = i - inline_start
                use_rare = False
                if rare_frac is not None:
                    win_len = max(1, inline_stop - inline_start)
                    use_rare = off < int(rare_frac * win_len + 1e-9)
                else:
                    use_rare = (off % rare_every) == 0
                if use_rare:
                    seq_override = rare_seq
            if in_win_8a:
                leak_buf.append(bytearray(1024 * 4 * 1024))
            if in_win_8b:
                leak_buf.append(bytearray(inline_8b_mb * 1024 * 1024))
            force_gc = bool(
                do_inline_8a
                and (
                    (in_win_8a and ((i - inline_start) % inline_gc_every) == 0)
                    or ((i + 1) == inline_stop)
                )
            )
            frag_action = None
            if in_win_2a:
                do_stall = (i - inline_start) >= max(10, (inline_stop - inline_start) // 3)
                frag_action = {
                    "live": frag_live,
                    "sizes": frag_sizes,
                    "chunks": frag_chunks_per_step,
                    "stall_mb": frag_stall_mb,
                    "do_stall": do_stall,
                    "min_stall_s": (frag_min_stall_s if do_stall else 0.0),
                    "step": i,
                }
            spike_n = 0
            if in_win_2c and ((i - inline_start) % compile_every) == 0:
                # 每步换 shape，逼 inductor 重新编译（one-shot 尖刺的 Loud 近似）
                spike_n = compile_base_n + ((i - inline_start) % 9) * 128
            (
                data_ms,
                compute_ms,
                comm_ms,
                wait_ms,
                step_ms,
                loss,
                frag_stall_ms,
                shape_seq,
            ) = step_instrumented(
                force_gc=force_gc,
                gc_stall_s=(inline_gc_stall_s if force_gc else 0.0),
                data_stall_s=(inline_8b_stall_s if in_win_8b else 0.0),
                hbm_bufs=(hbm_bufs if in_win_hbm else None),
                hbm_copies=cur_hbm_copies,
                cube_bufs=(cube_bufs if in_win_cube else None),
                cube_mm=(cube_mm if in_win_cube else 0),
                frag_action=frag_action,
                seq_override=seq_override,
                compile_spike_n=spike_n,
            )
            mem_alloc = mem_reserved = mem_gap = 0
            try:
                mem_alloc = int(torch.npu.memory_allocated(device))
                mem_reserved = int(torch.npu.memory_reserved(device))
                mem_gap = mem_reserved - mem_alloc
            except Exception:  # noqa: BLE001
                pass
            rec = {
                "step": i,
                "data_ms": round(data_ms, 3),
                "compute_ms": round(compute_ms, 3),
                "comm_ms": round(comm_ms, 3),
                "wait_ms": round(wait_ms, 3),
                "step_ms": round(step_ms, 3),
                "loss": round(loss, 6),
                "ts": round(time.time(), 3),
                "npu_alloc_bytes": mem_alloc,
                "npu_reserved_bytes": mem_reserved,
                "cuda_frag_gap_bytes": mem_gap,
                "frag_stall_ms": round(frag_stall_ms, 3),
                "shape_seq": shape_seq,
                **meta_common,
            }
            f.write(json.dumps(rec) + "\n")
            if (i + 1) % args.flush_every == 0:
                f.flush()
                os.fsync(f.fileno())
            # HANDOFF：注入窗依赖 100 整数倍 marker（统一 200/400）；rank0 每 100 步落盘
            if rank == 0 and (i + 1) % 100 == 0:
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
