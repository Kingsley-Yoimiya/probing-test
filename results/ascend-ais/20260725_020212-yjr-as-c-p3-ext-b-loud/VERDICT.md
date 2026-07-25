# Verdict — 20260725_020212-yjr-as-c-p3-ext-b-loud (loud)

| case | C1/C0 | d_level | target | truth | notes |
|---|---:|---:|---|---|---|
| P3-EXT-B | 2.13 | **D3** | rank_11 / victim=7 | rank_7 | D1: C1/C0=2.13; D2: IoU=1.00 [100,300]; offline max_data→11；SQL same_host hit victim=7；attach=no / host_psi_io_no_hit → 不升 D4 |

- 工具线：C0/C1/C2；离线 `score_dlevel_offline` + `score_dlevel_sql`
- 注入：fio-3.29 randrw nj=16 iodepth=64（同盘 `probe-bundle/io_stress`）；ckpt_every=20 + payload pread 1MB
- Greyhound / XPUTimer = PENDING（未本批对照）
