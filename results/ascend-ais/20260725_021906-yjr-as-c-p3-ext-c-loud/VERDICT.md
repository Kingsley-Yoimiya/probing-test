# Verdict — 20260725_021906-yjr-as-c-p3-ext-c-loud (loud)

| case | C1/C0 | d_level | target | truth | notes |
|---|---:|---:|---|---|---|
| P3-EXT-C | 1.59 | **D3** | rank_15 / victim=7 | rank_7 | D1: C1/C0=1.59; D2: IoU=1.00 [100,300]; offline max_data→15；SQL same_host hit victim=7；attach=no / PSI_UNAVAIL → 不升 D4 |

- 工具线：C0/C1/C2；离线 `score_dlevel_offline` + `score_dlevel_sql`
- 注入：`stress-ng --vm 96 --vm-bytes 6G --vm-keep --page-in`；核无 `/proc/pressure`
- Greyhound / XPUTimer = PENDING（未本批对照）
