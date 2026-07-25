# Verdict SQL — 20260725_121105-yjr-as-c-p1-sw-c-loud (loud)

| case | C1/C0 | d_level | SQL | notes |
|---|---:|---|---|---|
| P1-SW-C | 4.63 | **D3** | SQL_NO_EXT_EVIDENCE | D1: tip_victim_L7 max=4.63 p99=1.02 med=1.02 (median盲 tip可见); D2: IoU=1.00 det=[100,300] gt=[100,300] onset=100; D3_signal=min_compute_at_ti |

- 主证据：C2 `probing/query_manifest.json`；训练 jsonl 仅离线验证到 D3。
- Greyhound / XPUTimer = PENDING（见 ledger §3.2；未接入≠D0，也未定谳 ENV-BLOCKED）。
- CSV: `/Users/yinjinrun/Codespace/myportal/results/ascend-ais/20260725_121105-yjr-as-c-p1-sw-c-loud/scoring_table_SQL_loud.csv`
