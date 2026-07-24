# Baseline / 对手工具（本战役）

按 `rules.md` 红线 5：先趟通再记 ENV-BLOCKED。

| 工具 | config | 本战役做法 | 状态 |
|------|--------|------------|------|
| Probing | C2 | Probing_plus + site_hook；SQL dump | 跑 |
| Greyhound | C3 | `install_baseline_libs.sh` 最小 `libmcclprobe.so`（加载探针，非完整 ACF） | stub PENDING 完整 RCA |
| XPUTimer | C4 | 最小 `libxpu_timer_metax.so` | stub PENDING |
| Flight Recorder | C5 | `TORCH_NCCL_TRACE_BUFFER_SIZE`；MetaX 上可能映射 MCCL | 尝试；触发协议标 **oracle** 若人工开窗 |
| Dynolog | — | 管线无 C6；见其他 overlay NOTES | 本战役不挂常驻 |

代价五项（常驻%/注入扰动/trigger/分析/存储）在正式 C2+ 跑完后写入结果目录 `baseline_cost.yaml`。
