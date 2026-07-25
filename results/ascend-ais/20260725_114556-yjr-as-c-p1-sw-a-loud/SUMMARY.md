# SUMMARY · P1-SW-A inline `2a` 显存碎片化 Loud · SCORED D3

| 项 | 值 |
|----|-----|
| 状态 | **SCORED** |
| run_id | `20260725_114556-yjr-as-c-p1-sw-a-loud` |
| pod | `yysong-master-0`（hold-exec） |
| world | 16（1×16） |
| dose | `INLINE_2A_CHUNKS=12, INLINE_2A_STALL_MB=768, INLINE_2A_STALL_S=0.25`（移植沐曦，首轮咬合） |
| inject | `INLINE_INJECT=2a` victim_local=7；gpu_bound |
| C0 / C1 / C2 med step_ms | 77.53 / 325.43 / 326.52 |
| C1/C0 | **4.20**（thr 1.3）→ Loud **PASS** |
| **最高 D** | **D3**（offline+SQL：`min_compute_ms`→rank_7；gap flat / SQL_NO_EXT_EVIDENCE 不升 D4） |
| SQL dump | DUMP_OK（gpu/cpu util/tasks）；缺 torch_trace / process.*；mx-smi N/A |

## 三问

1. **边界**：manifest（16 卡、gpu_bound、2a chunks12/stall768/0.25、victim_lr=7、C0–C2）
2. **跑通**：jsonl 48 + INLINE_2A 激活 + ACCEPT PASS
3. **检出**：如实 **D3**（窗 IoU=1；victim=7；无合法 SQL 升 D4，对齐沐曦 DONE_PARTIAL 口径）
