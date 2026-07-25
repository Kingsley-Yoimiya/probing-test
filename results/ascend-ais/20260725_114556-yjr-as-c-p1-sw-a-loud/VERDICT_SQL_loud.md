# Verdict SQL — 20260725_114556-yjr-as-c-p1-sw-a-loud (loud)

| case | C1/C0 | d_level | SQL | notes |
|---|---:|---|---|---|
| P1-SW-A | 4.20 | **D3** | SQL_NO_EXT_EVIDENCE | D1: C1/C0_step_ms=4.20 (thr=1.5); D2: IoU=1.00 det=[100,300] gt=[100,300] onset=166; D3_signal=min_compute_ms rank=7 compute=66.43 step=325. |

- 主证据：C2 `probing/query_manifest.json`；训练 jsonl 仅离线验证到 D3。
- Greyhound / XPUTimer = PENDING（见 ledger §3.2；未接入≠D0，也未定谳 ENV-BLOCKED）。
- CSV: `results/ascend-ais/20260725_114556-yjr-as-c-p1-sw-a-loud/scoring_table_SQL_loud.csv`
