# P3-EXT-A Loud · C2 + SCORED · SUMMARY

| 项 | 值 |
|----|-----|
| 状态 | **SCORED** |
| run_id | `20260725_001251-yjr-as-c-p3-ext-a-loud` |
| pod | `yysong-master-0`（hold-exec） |
| world | 16（1×16） |
| dose | stress-ng `--cpu $(nproc)` `--cpu-load 90`；窗 [100,300]（同 LOUD_OK） |
| C0 / C1 | 合并自 `20260724_231918-yjr-as-c-p3exta-loud`（C1/C0=1.97） |
| C2 med step_ms | 195.95（C2/C0≈2.25） |
| **最高 D** | **D3**（offline；Host 单 pod；D4=SQL_PENDING） |
| Probing | wheel `0.2.6` 已装；训练侧 `Activating probing nested` 成功 |
| SQL dump | **失败**：dump 时 PATH 丢 `/bin` → `bash: command not found`（已修 hold_exec PATH，下轮可重 dump） |

## 三问

1. **边界**：manifest（16 卡、host_bound、victim_lr=7、C2_probing）
2. **跑通**：C2×16 jsonl + 注入 started；C0/C1 自 Loud 合并
3. **检出**：offline **D3**；Probing SQL 未落盘 → 不升 D4（不焊答案）
