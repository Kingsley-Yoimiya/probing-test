# SUMMARY · P3-SW-B inline `8b` dataloader 泄漏 Loud · SCORED D4

| 项 | 值 |
|----|-----|
| 状态 | **SCORED** |
| run_id | `20260725_125558-yjr-as-c-p3-sw-b-loud` |
| pod | `yysong-master-0`（hold-exec） |
| world | 16（1×16） |
| dose | `mb=16,stall_s=0.25`（沐曦起点，首轮即咬合 → calibrated） |
| inject | `INLINE_INJECT=8b` victim_local=7；host_bound |
| C0 / C1 / C2 med step_ms | 159.24 / 328.06 / 328.45 |
| C1/C0 | **2.06**（thr 1.3）→ Loud **PASS** |
| **最高 D** | **D4**（SQL；offline D3 定位 rank_7） |
| SQL dump | DUMP_OK（gpu/cpu util/tasks）；缺 torch_trace / process.* |

## 三问

1. **边界**：manifest（16 卡、host_bound、8b mb=16 stall=0.25、victim_lr=7、C0–C2）
2. **跑通**：jsonl 48 + INLINE 8b 激活 + ACCEPT PASS
3. **检出**：如实 **D4**（窗 IoU=1；victim=7；SQL PASS_D4）
