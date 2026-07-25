# SUMMARY · P3-SW-C sidecar `8c` 监控自身泄漏 Loud · SCORED D4

| 项 | 值 |
|----|-----|
| 状态 | **SCORED** |
| run_id | `20260725_135238-yjr-as-c-p3-sw-c-loud` |
| pod | `yysong-master-0`（hold-exec；跳板编排） |
| world | 16（1×16） |
| dose | `cpu_n=nproc,cpu_load=90,mb=1,leak_every=1.0,max_chunks=64` calibrated |
| inject | sidecar 8c：stress-ng CPU + 主进程 1MB/s RSS 泄漏；host_bound |
| C0 / C1 med step_ms | 102.26 / 254.98 |
| C1/C0 | **2.49**（thr 1.3）→ Loud **PASS** |
| **最高 D** | **D4**（SQL `cpu.utilization_rss`；offline D3 same_host） |
| SQL dump | DUMP_OK（gpu/cpu util/tasks）；缺 torch_trace / process.* |

## 三问

1. **边界**：manifest（16 卡、host_bound、8c nproc@90+leak、C0–C2）
2. **跑通**：jsonl 48 + sidecar START + ACCEPT PASS
3. **检出**：如实 **D4**（窗 IoU=1；host 命中；SQL PASS_D4）

## 标定笔记

- pilot1 `132200` pure-busy×128：C1/C0=0.96 咬空
- `134528` nproc@90：咬合但训练曾中途死（编排断）
- `135238` 跳板编排完整 C0/C1/C2：C1/C0=**2.49** PASS → calibrated
