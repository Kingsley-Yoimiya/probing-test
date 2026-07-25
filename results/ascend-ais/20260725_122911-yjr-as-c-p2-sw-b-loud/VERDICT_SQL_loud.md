# Verdict SQL — 20260725_122911-yjr-as-c-p2-sw-b-loud (loud)

| case | C1/C0 | d_level | SQL | notes |
|---|---:|---|---|---|
| P2-SW-B | 1.82 | **D3** | SQL_NO_EXT_EVIDENCE | D1: C1/C0_comm_ms=1.819 (thr=1.3); step=1.131 (step<1.15 不自动 FAIL；主证=comm); D2: IoU=1.00 det=[100,300] gt=[100,300] onset=0; D3_signal=comm_ |

- 主证据：C2 `probing/query_manifest.json`；训练 jsonl 仅离线验证到 D3。
- Greyhound / XPUTimer = PENDING（见 ledger §3.2；未接入≠D0，也未定谳 ENV-BLOCKED）。
- CSV: `/Users/yinjinrun/Codespace/myportal/results/ascend-ais/20260725_122911-yjr-as-c-p2-sw-b-loud/scoring_table_SQL_loud.csv`
