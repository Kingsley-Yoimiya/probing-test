# P3-SW-A bite2 — 20260724_114257-p3swa-bite2

| 项 | 结果 |
|---|---|
| C1/C0 | **3.15**（门槛 1.3） |
| 验收 | **PASS** |
| 离线 | **D3**（onset=101, IoU=1.00, target rank_7） |
| 注入 | 窗内每步 leak 4MiB + `gc.collect` + stall 0.25s |

下一步：同配方正式 Loud ABC（含 C2 SQL）冲 D4。
