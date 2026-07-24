# baseline_status.md — SW-B 对手线状态

更新：2026-07-24（隔离目录初建）

| 工具 | 角色 | 接线位置 | 当前状态 | 备注 |
|------|------|----------|----------|------|
| Probing | 主检测（C2） | `PROBING=2` + GPU sample | 沿用父战役 | MetaX 勿默认开 `PROBING_TORCH_PROFILING=on` |
| Greyhound | 对手 D-run | C3 `LD_PRELOAD=.../greyhound/libmcclprobe.so` | **PENDING / 待接入** | 非 ENV-BLOCKED；需 Redis + MetaX MCCL probe |
| XPUTimer | 对手 E-run | C4 `LD_PRELOAD=.../xputimer/libxpu_timer_metax.so` | **PENDING / 待接入** | 同上 |
| Flight Recorder | 极轻极窄 baseline | C5 `TORCH_NCCL_TRACE_BUFFER_SIZE` | **PENDING + 触发协议待定** | oracle 触发不能算检出率 / TTD |
| Dynolog | 按需触发 | 未绑 C* | **PENDING** | 见 SOP-COMPATIBILITY；本隔离目录未加 denv |
| StragglerAnalysis | 离线补充 | `convert_timeline_to_straggler.py` | **stub** | 不进在线分母 |

禁止在本文件写死 `ENV-BLOCKED`（rules 红线 5）；穷尽接入后才可在 ledger 升格。
