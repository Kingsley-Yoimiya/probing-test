# SUMMARY · P3-SW-A inline `8a` GC/stall Loud · SCORED D4

| 项 | 值 |
|----|-----|
| 状态 | **SCORED** |
| run_id | `20260725_012957-yjr-as-c-p3-sw-a-loud` |
| pod | `yysong-master-0`（hold-exec） |
| world | 16（1×16） |
| dose | `INLINE_GC_EVERY=1, INLINE_GC_STALL_S=0.25`（沐曦起点，首轮即咬合） |
| inject | `INLINE_INJECT=8a` victim_local=7；host_bound |
| C0 / C1 / C2 med step_ms | 155.20 / 454.05 / 472.86 |
| C1/C0 | **2.93**（thr 1.3）→ Loud **PASS** |
| **最高 D** | **D4**（SQL：`cpu.utilization_rss` p3sw_rss_window；offline D3 定位 rank_7） |
| SQL dump | DUMP_OK（gpu/cpu util/tasks + p3sw_rss）；缺 torch_trace / process.* |

## 三问

1. **边界**：manifest（16 卡、host_bound、8a stall=0.25、victim_lr=7、C0–C2）
2. **跑通**：jsonl 48 + INLINE 8a 激活 + ACCEPT PASS
3. **检出**：如实 **D4**（窗 IoU=1；victim=7；RSS SQL PASS_D4）
