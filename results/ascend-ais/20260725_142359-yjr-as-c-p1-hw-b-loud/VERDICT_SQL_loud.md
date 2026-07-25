# Verdict SQL — 20260725_142359-yjr-as-c-p1-hw-b-loud (loud)

| case | C1/C0 | d_level | SQL | notes |
|---|---:|---|---|---|
| P1-HW-B | 1.57 | **D3** | SQL_NO_EXT_EVIDENCE | D1: C1/C0_step_ms=1.57 (thr=1.3); D2: IoU=1.00 det=[100,300] gt=[100,300] onset=148; D3_signal=min_compute_ms rank=7 compute=66.58 step=123. |

- 主证据：C2 `probing/query_manifest.json`；训练 jsonl 仅离线验证到 D3。
- Greyhound / XPUTimer = PENDING（见 ledger §3.2；未接入≠D0，也未定谳 ENV-BLOCKED）。
- CSV: `/Users/yinjinrun/Codespace/myportal/project/probing-huawei/results/ascend-ais/20260725_142359-yjr-as-c-p1-hw-b-loud/scoring_table_SQL_loud.csv`
