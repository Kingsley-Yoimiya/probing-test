# P3-SW-A Loud — 20260724_115002-p3swa-loud

| 项 | 结果 |
|---|---|
| C1/C0 | **2.17**（PASS，门槛 1.3） |
| C2/C0 | 2.09 |
| 离线 | D3（victim rank_7，onset=101） |
| SQL | **D4 / PASS_D4**（`cpu.utilization_rss`） |

证据链：内联 8a（leak+GC+stall）→ 离线 D3 → C2 dump `cpu.utilization` 进程 RSS 超阈升 D4。
