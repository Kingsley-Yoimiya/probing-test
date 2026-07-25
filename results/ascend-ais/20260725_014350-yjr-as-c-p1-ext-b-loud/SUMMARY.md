# SUMMARY · P1-EXT-B inline_hbm Loud · SCORED D3

| 项 | 值 |
|----|-----|
| 状态 | **SCORED** |
| run_id | `20260725_014350-yjr-as-c-p1-ext-b-loud` |
| pod | `yysong-master-0`（hold-exec） |
| world | 16（1×16） |
| dose | `inline_hbm_mb=512,inline_hbm_copies=48`（dose_recipes 起点，首轮即咬合） |
| inject | `INLINE_INJECT=hbm` victim_local=7；gpu_bound；**非**外挂 sidecar |
| C0 / C1 / C2 med step_ms | 77.26 / 156.44 / 158.10 |
| C1/C0 | **2.02**（thr 1.6）→ Loud **PASS** |
| **最高 D** | **D3**（offline：`min_compute_ms`→rank_7；SQL attach 失败→不升 D4） |
| SQL dump | attach=no（Connection refused）；host_psi 无 hit；不焊答案 |

## 三问

1. **边界**：manifest（16 卡、gpu_bound、inline HBM 512×48、victim_lr=7、C0–C2）
2. **跑通**：jsonl 48 + `INLINE_HBM_ALLOC` + ACCEPT PASS
3. **检出**：如实 **D3**（窗 IoU=1；victim=7；SQL 无外证→停 D3）

## 硬教训落实

- 未走外挂 memory sidecar；直接 INLINE（对齐 P1-EXT-A 隔离教训）
