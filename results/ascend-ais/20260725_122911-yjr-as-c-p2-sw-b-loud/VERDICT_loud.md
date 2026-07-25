# Verdict — 20260725_122911-yjr-as-c-p2-sw-b-loud (loud)

| case | C1/C0 | d_level | target | truth | notes |
|---|---:|---:|---|---|---|
| P2-SW-B | 1.82 | D3 | rank_7 | rank_7 | D1: C1/C0_comm_ms=1.819 (thr=1.3); step=1.131 (step<1.15 不自动 FAIL；主证=comm); D2:  |

- 工具=`offline_training_metrics`（训练内 compute/wait/data）；Probing SQL = SQL_PENDING
- Greyhound / XPUTimer = PENDING（见 ledger §3.2；未接入≠D0，也未定谳 ENV-BLOCKED）
- CSV: `/Users/yinjinrun/Codespace/myportal/results/ascend-ais/20260725_122911-yjr-as-c-p2-sw-b-loud/scoring_table_loud.csv`
