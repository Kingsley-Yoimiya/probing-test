# SUMMARY · P3-EXT-C stress_vm Loud · SCORED D3

| 项 | 值 |
|----|-----|
| 状态 | **SCORED** |
| run_id | `20260725_021906-yjr-as-c-p3-ext-c-loud` |
| pod | `yysong-master-0`（hold-exec） |
| world | 16（1×16） |
| dose | `stress-ng --vm 96 --vm-bytes 6G --vm-keep --page-in`（≈576Gi on 2Ti host） |
| inject | `stress_vm` host_bound |
| C0 / C1 / C2 med step_ms | 87.24 / 138.77 / 130.92 |
| C1/C0 | **1.59**（thr 1.3）→ Loud **PASS** |
| **最高 D** | **D3**（窗 IoU=1；SQL attach 失败 + 核无 `/proc/pressure`→PSI_UNAVAIL → 不升 D4） |
| jsonl | 48 |
| PSI | **UNAVAIL**（无 `/proc/pressure`）；注入窗 loadavg≈150（vm hog 亦耗 CPU，无法用 PSI 分 memory vs cpu） |

## 三问

1. **边界**：manifest（16 卡、host_bound、stress_vm、victim_lr=7、C0–C2）
2. **跑通**：jsonl 48 + stress_vm dispatch + ACCEPT PASS
3. **检出**：如实 **D3**（不焊答案；SQL/PSI 无外证停 D3）

## 标定笔记

- 首轮 Loud `96×6G` 即咬合；部分 vm 子进程被 signal kill，残余压力仍够 1.59×
- 内核无 PSI：无法回答「压力走 memory 还是 cpu」；旁证仅有 loadavg + step_ms
