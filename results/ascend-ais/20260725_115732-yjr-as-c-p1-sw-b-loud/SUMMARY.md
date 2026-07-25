# SUMMARY · P1-SW-B inline `2b` 罕见 shape Loud · SCORED D3

| 项 | 值 |
|----|-----|
| 状态 | **SCORED** |
| run_id | `20260725_115732-yjr-as-c-p1-sw-b-loud` |
| pod | `yysong-master-0`（hold-exec） |
| world | 16（1×16） |
| dose | `RARE_SHAPE_SEQ=1536, RARE_SHAPE_EVERY=1`（移植沐曦 dose_swb，首轮咬合） |
| inject | `INLINE_INJECT=2b` victim_local=7；gpu_bound |
| C0 / C1 / C2 med step_ms | 77.54 / 105.15 / 105.26 |
| C1/C0 | **1.36**（thr 1.15）→ Loud **PASS** |
| **最高 D** | **D3**（offline+SQL：`shape_seq_rare`→rank_7；SQL_NO_EXT_EVIDENCE 不升 D4） |
| SQL dump | DUMP_OK；缺 gpu.utilization / process.* → 无合法 SQL 升 D4 |

## 三问

1. **边界**：manifest（16 卡、gpu_bound、2b rare_seq=1536/every=1、victim_lr=7、C0–C2）
2. **跑通**：jsonl 48 + INLINE_RARE_SHAPE 激活 + ACCEPT PASS
3. **检出**：如实 **D3**（窗 IoU=1；victim=7 窗内 shape_seq=1536×200；无合法 SQL 升 D4，对齐沐曦 DONE_PARTIAL 口径）
