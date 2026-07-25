# SUMMARY · P1-EXT-A inline_cube Loud · SCORED D2

| 项 | 值 |
|----|-----|
| 状态 | **SCORED** |
| run_id | `20260725_011129-yjr-as-c-p1-ext-a-loud` |
| pod | `yysong-master-0`（hold-exec） |
| world | 16（1×16） |
| dose | `inline_cube_size=8192,inline_cube_mm=64`（末次加剂；非外挂） |
| INLINE | `INLINE_CUBE_ALLOC size=8192 mm/step=64 victim_local=7` |
| C0 / C1 / C2 med step_ms | 77.43 / 300.00 / 299.37 |
| C1/C0 | **3.87**（thr 1.5）→ Loud **PASS** |
| **最高 D** | **D2**（offline+SQL；D3 定位错 rank_4≠truth_7；D4 因 D3 未过跳过） |
| SQL dump | DUMP_OK（gpu/cpu util/tasks + p1_gpu_window）；缺 torch_trace / process.* |

## 三问

1. **边界**：manifest（16 卡、gpu_bound、inline 8192×64、victim_lr=7、C0–C2）
2. **跑通**：jsonl 48 + INLINE 激活 + ACCEPT PASS
3. **检出**：如实 **D2**（窗 IoU=1；根因 rank 错→不升 D3/D4，不焊答案）

## 剂量史

- sidecar@`004124` C1/C0=1.00 INEFFECTIVE（隔离）
- INLINE 4096×16@`010451` C1/C0=1.06 INEFFECTIVE
- INLINE 8192×64@`011129` C1/C0=3.87 **calibrated**
