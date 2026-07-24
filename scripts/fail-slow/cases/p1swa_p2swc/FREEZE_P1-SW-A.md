# P1-SW-A 探索冻结（2026-07-24）

## 注入

- kind: `INLINE_INJECT=2a`（隔离 `train_bench_probe_2a.py`）
- Loud: `INLINE_2A_CHUNKS=12` `INLINE_2A_STALL_MB=768` `INLINE_2A_STALL_S=0.25`
- 机制：窗内交错尺寸 alloc/释放造碎片；窗后 2/3 在 **barrier 前** 大块 fill+sync，并用最小 stall 地板拖全局（同 8a 控变）
- victim: node0 local_rank=7

## Pilot 证据

- run_id: `20260724_175729-p1swa-loud-pilot3`
- C1/C0 rank0 step_ms 中位：**3.58**（阈值 1.3）→ PASS
- 结果：`results/muxi-h3c/20260724_175729-p1swa-loud-pilot3/`

## 检测路径（冻结）

1. 离线：`accept_loud.py`（C1/C0 step_ms）
2. 趋势线索：`cases/p1swa_p2swc/score_trend.py`（`cuda_frag_gap_bytes` / `frag_stall_ms`）
3. C2：共享 `dump_probing_sql.sh` + `score_dlevel_sql.py`（不写死窗/rank/PID）

## 工程注意

- LOCAL_FS 必须在每轮清掉各 pod 上该 config 的 out 目录，否则残留 `node_*.done` 会假完成
