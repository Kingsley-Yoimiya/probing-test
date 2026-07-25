# Verdict SQL — 20260725_011129-yjr-as-c-p1-ext-a-loud (loud)

| case | C1/C0 | d_level | SQL | notes |
|---|---:|---|---|---|
| P1-EXT-A | 3.87 | **D2** | DUMP_OK | D1: C1/C0_step_ms=3.87; D2: IoU=1.00 det=[100,300] gt=[100,300] onset=101; D3_signal=min_wait_among_slow rank=4 wait=0.88 slow_n=0 step=300. |

- 主证据：C2 `probing/query_manifest.json`；训练 jsonl 仅离线验证到 D3。
- Greyhound / XPUTimer = PENDING（见 ledger §3.2；未接入≠D0，也未定谳 ENV-BLOCKED）。
- CSV: `results/ascend-ais/20260725_011129-yjr-as-c-p1-ext-a-loud/scoring_table_SQL_loud.csv`
