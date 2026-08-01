#!/usr/bin/env python3
"""train_bench_probe.py — 仪器化 GPT-2 训练微基准(within-step 分解 + 流式本地落盘)。

相对 train_bench_clean.py 的三处关键改造:
  1. within-step 三段埋点: 用 cuda.Event 分别计 compute_ms / comm_ms,
     并在 backward 后插一个显式 barrier 取 wait_ms(= barrier耗时,
     healthy rank 早到 → wait 大; victim 晚到 → wait≈0)。
     这两路信号穿透 AllReduce 的 step-level 掩蔽,支撑"定位到 straggler rank"。
  2. 流式写 pod 本地盘: warmup 后开句柄,每步 append(写在计时区之外),每
     flush_every 步 fsync;out-dir 默认由编排器指向 /workspace/probe-bundle/out。
  3. --mode host_bound: 用真实 DataLoader(num_workers)喂数,让 host 层注入
     (GC/stress/leak)有关键路径可咬;gpu_bound 则用 device 端随机 idx(纯算)。

所有 config(C0..C4)共用本脚本; 注入由外部 sidecar 进程实现,检测器由环境变量
(PROBING / LD_PRELOAD)叠加。本脚本不感知注入器/检测器的存在。

输出: <out_dir>/rank_<global_rank>.jsonl (每步一行 JSON)
      <out_dir>/warmup_done            (rank0 warmup 完成 marker,供编排器查)
"""
from __future__ import annotations

import argparse
import json
import os
import pickle
import time
from pathlib import Path


def _activate_probing_if_requested() -> None:
    """挂 Probing site hook。

    ``pip install --target=pydeps`` 时 ``probing.pth`` 只在 PYTHONPATH 目录里，
    不会被 Python site 自动执行 → ``PROBING=2`` 形同虚设，SQL dump 全是
    Connection refused。训练 worker 入口必须显式激活。
    """
    val = os.environ.get("PROBING", "0").strip().lower()
    if val in ("", "0", "off", "false", "no"):
        return
    try:
        from probing.site_hook import run_site_hook

        run_site_hook()
    except Exception as exc:  # noqa: BLE001 — 激活失败不应拖死训练
        print(f"[train_bench_probe] probing site_hook failed: {exc}", flush=True)


_activate_probing_if_requested()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters", type=int, default=500)
    ap.add_argument("--warmup", type=int, default=50)
    ap.add_argument("--model", choices=["gpt2", "tiny"], default="gpt2",
                    help="gpt2=约124M GPT-2；tiny 仅用于紧急管线回退")
    ap.add_argument("--seq", type=int, default=1024)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--hidden", type=int, default=None)
    ap.add_argument("--layers", type=int, default=None)
    ap.add_argument("--ffn", type=int, default=None)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out-dir", required=True,
                    help="pod 本地路径；rank 各写各的 jsonl。")
    # ── 本轮新增 ──
    ap.add_argument("--mode", choices=["gpu_bound", "host_bound"], default="gpu_bound",
                    help="host_bound 用真实 DataLoader,让 host 注入(GC/stress/leak)咬到 data 路径")
    ap.add_argument("--flush-every", type=int, default=5, help="每 N 步 flush+fsync")
    ap.add_argument("--ckpt-every", type=int, default=100,
                    help="rank0 每 N 个 measure 步写一次 checkpoint（P3-EXT-B 可调密以咬 IO）")
    ap.add_argument("--decompose", type=int, default=1,
                    help="1=开 within-step compute/comm/wait 分解(默认); 0=只测 step_ms")
    ap.add_argument("--dl-workers", type=int, default=2, help="host_bound 模式 DataLoader worker 数")
    ap.add_argument("--io-payload", default="",
                    help="host_bound 可选：每样本从此文件 pread 一块，使 fio 同盘争用落入 data_ms")
    ap.add_argument("--io-read-kb", type=int, default=0,
                    help="配合 --io-payload：每次读取 KB 数（0=不读盘）")
    # 元信息(写进每条记录,便于离线汇聚)
    ap.add_argument("--run-id", default="")
    ap.add_argument("--group", default="")
    ap.add_argument("--config", default="")
    ap.add_argument("--round", type=int, default=0)
    args = ap.parse_args()

    import torch
    import torch.distributed as dist
    import torch.nn as nn
    import torch.nn.functional as F
    from torch.nn.parallel import DistributedDataParallel as DDP

    torch.manual_seed(args.seed)
    torch.cuda.manual_seed_all(args.seed)

    dist.init_process_group(backend="nccl")
    rank = dist.get_rank()
    world = dist.get_world_size()
    local = int(os.environ.get("LOCAL_RANK", 0))
    node_rank = int(os.environ.get("GROUP_RANK", os.environ.get("NODE_RANK", "0")))
    torch.cuda.set_device(local)
    device = f"cuda:{local}"

    # GPT-2 124M: vocab=50257, hidden=768, 12 层, MLP=3072，词表/输出层权重共享。
    # tiny 只保留为资源不足时验证编排、注入和回拉链路的退路。
    if args.model == "gpt2":
        hidden, layers, ffn, vocab = 768, 12, 3072, 50257
    else:
        hidden, layers, ffn, vocab = 256, 4, 1024, 32000
    hidden = args.hidden or hidden
    layers = args.layers or layers
    ffn = args.ffn or ffn

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

    class GPT2Bench(nn.Module):
        def __init__(self):
            super().__init__()
            self.emb = nn.Embedding(vocab, hidden)
            self.pos = nn.Embedding(args.seq, hidden)
            self.blocks = nn.ModuleList(
                [Block(hidden, ffn) for _ in range(layers)]
            )
            self.ln = nn.LayerNorm(hidden)
            self.head = nn.Linear(hidden, vocab, bias=False)
            self.head.weight = self.emb.weight  # GPT-2 tying，约124M 参数而非重复输出词表

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

    # ── 数据供给：两种模式都走 DataLoader(num_workers=2 默认)；host_bound 额外加入 CPU 工作。 ──
    import numpy as np
    from torch.utils.data import DataLoader, Dataset

    io_payload = (args.io_payload or "").strip()
    # O_DIRECT 要求长度/偏移 4K 对齐
    io_read = (max(0, int(args.io_read_kb)) * 1024 // 4096) * 4096
    io_direct = False
    io_direct_err = ""
    if args.mode == "host_bound" and io_payload and io_read > 0:
        p = Path(io_payload)
        if not p.is_file() or p.stat().st_size < io_read:
            # rank0 建 256MiB 填充文件；其它 rank 稍等
            if rank == 0:
                p.parent.mkdir(parents=True, exist_ok=True)
                with open(p, "wb") as wf:
                    chunk = b"\0" * (1024 * 1024)
                    for _ in range(256):
                        wf.write(chunk)
            dist.barrier()
        # 探测 O_DIRECT（文件系统不支持则回退 cached pread，并记证据）
        if hasattr(os, "O_DIRECT"):
            try:
                _fd = os.open(io_payload, os.O_RDONLY | os.O_DIRECT)
                os.close(_fd)
                io_direct = True
            except OSError as e:
                io_direct_err = f"{type(e).__name__}:{e}"
                io_direct = False
        if rank == 0:
            print(
                f"IO_PAYLOAD={io_payload} io_read={io_read} O_DIRECT={int(io_direct)}"
                + (f" err={io_direct_err}" if io_direct_err else ""),
                flush=True,
            )

    class TokenDataset(Dataset):
        def __len__(self):
            return args.iters * 100

        def __getitem__(self, i):
            rng = np.random.default_rng(i)
            buf = rng.integers(0, vocab, size=(S,), dtype=np.int64)
            if args.mode == "host_bound":
                # Loud host 路径可见性：768×768 matmul（仍保持 num_workers=2 / prefetch=2）
                _ = (rng.standard_normal((768, 768)) @ rng.standard_normal((768, 768))).sum()
                if io_payload and io_read > 0:
                    # 同文件随机读：优先 O_DIRECT+对齐缓冲，与 fio --direct=1 争用同一队列
                    try:
                        import mmap
                        fsz = os.path.getsize(io_payload)
                        off = (int(rng.integers(0, max(1, fsz - io_read))) // 4096) * 4096
                        flags = os.O_RDONLY | (os.O_DIRECT if io_direct else 0)
                        fd = os.open(io_payload, flags)
                        try:
                            if io_direct:
                                mm = mmap.mmap(-1, io_read)
                                try:
                                    os.preadv(fd, [mm], off)
                                finally:
                                    mm.close()
                            else:
                                os.pread(fd, io_read, off)
                        finally:
                            os.close(fd)
                    except OSError:
                        pass
            return torch.from_numpy(buf)

    # num_workers=0：主线程同步 IO，使同盘 fio 争用进 data_ms/step_ms；
    # PyTorch 禁止此时设 prefetch_factor / persistent_workers。
    _dl_kw = dict(batch_size=B, num_workers=args.dl_workers, pin_memory=True)
    if args.dl_workers > 0:
        _dl_kw["prefetch_factor"] = 2
        _dl_kw["persistent_workers"] = True
    dl = DataLoader(TokenDataset(), **_dl_kw)
    data_iter = iter(dl)

    decompose = bool(args.decompose)
    # 复用同一批 event(避免每步分配)
    if decompose:
        e_c0, e_c1 = torch.cuda.Event(True), torch.cuda.Event(True)
        e_m0, e_m1 = torch.cuda.Event(True), torch.cuda.Event(True)

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
    ):
        """返回 (data_ms, compute_ms, comm_ms, wait_ms, step_ms, loss)。"""
        t0 = time.perf_counter()
        if force_gc:
            import gc as _gc_mod
            _gc_mod.collect()
            # Loud 8a：真实 gc.collect 对 bytearray 堆往往只有 ~100ms，不足以抬中位；
            # 用可控 stall 模拟 STW，让 barrier 拖全局（仍落在计时区内）。
            if gc_stall_s > 0:
                time.sleep(gc_stall_s)
        # P3-SW-B：dataloader 阻塞必须落在计时区内，否则 accept(rank0 step_ms) 咬空
        if data_stall_s > 0:
            time.sleep(data_stall_s)
        idx = get_batch()                       # host_bound: 喂数时间落在此处
        t_data = time.perf_counter()

        # P1-EXT-B：外挂 D2D 在 MetaX 上常咬空（进程间带宽隔离）；victim 进程内 copy+sync
        if hbm_bufs is not None and hbm_copies > 0:
            src, dst = hbm_bufs
            for _ in range(hbm_copies):
                dst.copy_(src)
                src.copy_(dst)
            torch.cuda.synchronize()

        opt.zero_grad(set_to_none=True)
        if decompose:
            e_c0.record()
        logits = model(idx)
        loss = F.cross_entropy(logits.float().reshape(-1, vocab), idx.reshape(-1))
        loss.backward()
        if decompose:
            e_c1.record()
            torch.cuda.synchronize()            # compute 段真正算完
            t_arrive = time.perf_counter()      # 本 rank 到达 barrier 的绝对时刻
            dist.barrier()                      # 显式对齐: 慢的还没到, 快的在此等
            t_bar = time.perf_counter()
            e_m0.record()

        if decompose:
            e_m1.record()
        opt.step()
        torch.cuda.synchronize()
        t1 = time.perf_counter()

        if decompose:
            compute_ms = e_c0.elapsed_time(e_c1)      # GPU event 计时
            comm_ms = e_m0.elapsed_time(e_m1)
            wait_ms = (t_bar - t_arrive) * 1e3        # barrier 等待(空间信号)
            data_ms = (t_data - t0) * 1e3
        else:
            compute_ms = comm_ms = wait_ms = 0.0
            data_ms = (t_data - t0) * 1e3
        step_ms = (t1 - t0) * 1e3
        return data_ms, compute_ms, comm_ms, wait_ms, step_ms, float(loss.detach().cpu())

    # ── Warmup(同样的训练逻辑, 建立 CUDA context / autotune) ──
    for _ in range(args.warmup):
        step_instrumented()
    dist.barrier()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    if rank == 0:
        (out_dir / "warmup_done").write_text(str(time.time()))

    # ── Measure: 流式写 AFS(每步 append, 写在计时区之外, 每 flush_every 步 fsync) ──
    out_file = out_dir / f"rank_{rank:04d}.jsonl"
    meta_common = {
        "rank": rank, "local_rank": local, "node_rank": node_rank, "world_size": world,
        "run_id": args.run_id, "group": args.group, "config": args.config, "round": args.round,
        "mode": args.mode,
    }
    # P3-SW-A Loud：进程内泄漏+GC（外挂 GC 咬不到训练进程）。仅 victim local_rank。
    inline = os.environ.get("INLINE_INJECT", "").strip()
    inline_victim = int(os.environ.get("INLINE_VICTIM_LOCAL_RANK", str(max(0, int(os.environ.get("LOCAL_WORLD_SIZE", "8")) - 1))))
    inline_start = int(os.environ.get("INLINE_INJECT_START", "100"))
    inline_stop = int(os.environ.get("INLINE_INJECT_STOP", "300"))
    # 窗内每 N 步强制 STW；默认 1=每步（Loud 咬合用）
    inline_gc_every = max(1, int(os.environ.get("INLINE_GC_EVERY", "1")))
    inline_gc_stall_s = float(os.environ.get("INLINE_GC_STALL_S", "0.25"))
    do_inline_8a = (
        inline == "8a"
        and local == inline_victim
        and node_rank == 0
    )
    # P3-SW-B：进程内渐进泄漏（外挂 sidecar 在 64-rank/大内存机上咬空）
    do_inline_8b = (
        inline == "8b"
        and local == inline_victim
        and node_rank == 0
    )
    inline_8b_mb = max(4, int(os.environ.get("INLINE_8B_MB", "16")))
    inline_8b_stall_s = float(os.environ.get("INLINE_8B_STALL_S", "0.25"))
    do_inline_hbm = (
        inline == "hbm"
        and local == inline_victim
        and node_rank == 0
    )
    leak_buf: list = []
    hbm_bufs = None
    hbm_copies = max(1, int(os.environ.get("INLINE_HBM_COPIES", "6")))
    if do_inline_hbm:
        hbm_mb = max(32, min(int(os.environ.get("INLINE_HBM_MB", "256")), 1024))
        ne = hbm_mb * 1024 * 1024 // 2
        src = torch.randn(ne, device=device, dtype=torch.float16)
        dst = torch.empty_like(src)
        hbm_bufs = (src, dst)
        print(f"INLINE_HBM_ALLOC mb={hbm_mb} copies/step={hbm_copies}", flush=True)
    ckpt_dir = Path(os.environ.get("CKPT_DIR", "/workspace/probe-bundle/ckpt"))

    # Oracle short-window torch.profiler（dynolog 对照；不算自主检出）
    oracle_on = os.environ.get("ORACLE_PROFILE", "0").strip().lower() in (
        "1", "on", "true", "yes",
    )
    oracle_start = int(os.environ.get("ORACLE_PROFILE_START", "120"))
    oracle_stop = int(os.environ.get("ORACLE_PROFILE_STOP", "128"))
    oracle_dir = Path(
        os.environ.get(
            "ORACLE_PROFILE_DIR",
            str(out_dir.parent / "dynolog" / "traces"),
        )
    )
    oracle_ranks_raw = os.environ.get("ORACLE_PROFILE_RANKS", "").strip()
    oracle_rank_set = (
        {int(x) for x in oracle_ranks_raw.split(",") if x.strip()}
        if oracle_ranks_raw
        else None
    )
    do_oracle = bool(oracle_on and (oracle_rank_set is None or rank in oracle_rank_set))
    prof = None

    # Flight Recorder：环形缓冲常驻（TORCH_NCCL_TRACE_BUFFER_SIZE）；进程内 API dump 收证
    fr_dump_on = os.environ.get("FR_DUMP", "0").strip().lower() in (
        "1", "on", "true", "yes",
    )
    fr_dump_dir = Path(
        os.environ.get(
            "FR_DUMP_DIR",
            str(out_dir.parent / "flight_recorder"),
        )
    )
    fr_dump_step = int(os.environ.get("FR_DUMP_STEP", "300"))  # measure step
    fr_dump_ranks_raw = os.environ.get("FR_DUMP_RANKS", "").strip()
    fr_dump_rank_set = (
        {int(x) for x in fr_dump_ranks_raw.split(",") if x.strip()}
        if fr_dump_ranks_raw
        else None
    )
    do_fr_dump = bool(
        fr_dump_on and (fr_dump_rank_set is None or rank in fr_dump_rank_set)
    )

    def _fr_dump(tag: str) -> None:
        if not do_fr_dump:
            return
        try:
            fr_dump_dir.mkdir(parents=True, exist_ok=True)
            c10d = torch._C._distributed_c10d
            raw = c10d._dump_nccl_trace(
                includeCollectives=True,
                includeStackTraces=False,
                onlyActive=False,
            )
            pkl_path = fr_dump_dir / f"rank{rank}_{tag}.pkl"
            pkl_path.write_bytes(
                raw if isinstance(raw, (bytes, bytearray)) else pickle.dumps(raw)
            )
            meta = {
                "tag": tag,
                "rank": int(rank),
                "pkl_bytes": pkl_path.stat().st_size,
                "TORCH_NCCL_TRACE_BUFFER_SIZE": os.environ.get(
                    "TORCH_NCCL_TRACE_BUFFER_SIZE"
                ),
            }
            try:
                data = pickle.loads(raw) if isinstance(raw, (bytes, bytearray)) else raw
                if isinstance(data, dict):
                    ents = data.get("entries") or []
                    meta["version"] = data.get("version")
                    meta["entries_n"] = len(ents)
                    states = {}
                    names = {}
                    for e in ents:
                        if not isinstance(e, dict):
                            continue
                        st = str(e.get("state") or "?")
                        states[st] = states.get(st, 0) + 1
                        pn = str(e.get("profiling_name") or "?")
                        names[pn] = names.get(pn, 0) + 1
                    meta["states"] = states
                    meta["profiling_names_top"] = dict(
                        sorted(names.items(), key=lambda kv: -kv[1])[:8]
                    )
            except Exception as pe:  # noqa: BLE001
                meta["parse_err"] = repr(pe)
            (fr_dump_dir / f"rank{rank}_{tag}_meta.json").write_text(
                json.dumps(meta, indent=2)
            )
            print(
                f"FR_DUMP_OK rank={rank} tag={tag} bytes={meta.get('pkl_bytes')} "
                f"entries={meta.get('entries_n')}",
                flush=True,
            )
        except Exception as exc:  # noqa: BLE001
            print(f"FR_DUMP_FAIL rank={rank} tag={tag}: {exc}", flush=True)

    f = out_file.open("a", buffering=1)  # line-buffered
    try:
        for i in range(args.iters):
            if do_oracle and i == oracle_start and prof is None:
                from torch.profiler import (  # noqa: WPS433 — 仅 oracle 开窗时导入
                    ProfilerActivity,
                    profile,
                    tensorboard_trace_handler,
                )

                rank_trace_dir = oracle_dir / f"raw_rank_{rank:04d}"
                rank_trace_dir.mkdir(parents=True, exist_ok=True)
                prof = profile(
                    activities=[ProfilerActivity.CPU, ProfilerActivity.CUDA],
                    record_shapes=True,
                    with_stack=False,
                    on_trace_ready=tensorboard_trace_handler(str(rank_trace_dir)),
                )
                prof.__enter__()
                print(
                    f"ORACLE_PROFILE_START rank={rank} step={i} "
                    f"stop={oracle_stop} dir={rank_trace_dir}",
                    flush=True,
                )

            # 内联 8a：measure 窗内每步泄漏 ~4MB；窗内周期性 gc+stall 抬 C1/C0 中位
            in_win_8a = bool(do_inline_8a and inline_start <= i < inline_stop)
            in_win_8b = bool(do_inline_8b and inline_start <= i < inline_stop)
            in_win_hbm = bool(do_inline_hbm and inline_start <= i < inline_stop)
            if in_win_8a:
                leak_buf.append(bytearray(1024 * 4 * 1024))  # 4MiB
            if in_win_8b:
                leak_buf.append(bytearray(inline_8b_mb * 1024 * 1024))
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
                data_stall_s=(inline_8b_stall_s if in_win_8b else 0.0),
                hbm_bufs=(hbm_bufs if in_win_hbm else None),
                hbm_copies=(hbm_copies if in_win_hbm else 0),
            )
            if prof is not None and oracle_start <= i < oracle_stop:
                prof.step()
            if prof is not None and (i + 1) >= oracle_stop:
                prof.__exit__(None, None, None)
                print(
                    f"ORACLE_PROFILE_STOP rank={rank} step={i} dir={oracle_dir}",
                    flush=True,
                )
                # HTA 需要 distributedInfo.rank；汇总到 oracle_dir/rank{N}.pt.trace.json
                try:
                    rank_trace_dir = oracle_dir / f"raw_rank_{rank:04d}"
                    cands = sorted(rank_trace_dir.glob("*.pt.trace.json"))
                    if cands:
                        tp = cands[-1]
                        data = json.loads(tp.read_text())
                        data["distributedInfo"] = {"rank": int(rank)}
                        ranked = oracle_dir / f"rank{rank}.pt.trace.json"
                        ranked.write_text(json.dumps(data))
                        print(
                            f"ORACLE_PROFILE_TAGGED rank={rank} -> {ranked.name} "
                            f"events={len(data.get('traceEvents') or [])}",
                            flush=True,
                        )
                except Exception as exc:  # noqa: BLE001
                    print(f"ORACLE_PROFILE_TAG_FAIL rank={rank}: {exc}", flush=True)
                prof = None
            # 写在计时区之外: 绝不让 AFS I/O 污染 step_ms
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
            if rank == 0 and (i + 1) in {50, 100, 300}:
                # 编排器用这些测量步 marker：50=提前武装；100/300=验收窗边界
                # warmup=50 时，measure 100/300 分别对应全局 150/350。
                (out_dir / f"step_{i + 1}.marker").write_text(str(time.time()))
            # Flight Recorder：注入窗末 API dump（收证；非常驻 trigger）
            if do_fr_dump and (i + 1) == fr_dump_step:
                _fr_dump(f"step{fr_dump_step}")
            # SOP：checkpoint 写盘（9B IO 路径；写在计时外）。默认每 100 步；P3-EXT-B Loud 可加密。
            ckpt_every = max(1, int(args.ckpt_every))
            if rank == 0 and (i + 1) % ckpt_every == 0:
                ckpt_dir.mkdir(parents=True, exist_ok=True)
                torch.save(
                    {"step": i + 1, "model": model.module.state_dict()},
                    ckpt_dir / f"step_{i + 1}.pt",
                )
    finally:
        if prof is not None:
            try:
                prof.__exit__(None, None, None)
            except Exception:  # noqa: BLE001
                pass
            prof = None
        f.flush()
        try:
            os.fsync(f.fileno())
        except OSError:
            pass
        f.close()

    # 收证：训练结束前 API dump（缓冲常驻；此调用只是落盘，非检出 trigger）
    _fr_dump("end")
    dist.barrier()
    if rank == 0:
        print(f"DONE world={world} out={out_file}")
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
