# Loud acceptance: P2-SW-C (topo_5c; primary=max(step,comm))

- window: measure step [100, 300] rank0
- threshold max(C1/C0 step, C1/C0 comm) ≥ **1.15**
- injection.log: `topo_5c`
- verdict: **PASS** (winner=`comm_ms`)

| config | median step_ms | median comm_ms | vs C0 (step/comm) |
|---|---:|---:|---|
| C0_baseline | 76.922 | 6.391 | - |
| C1_inject_none | 389.272 | 318.664 | step=5.061; comm=49.861 |
| C2_probing | 402.44 | 330.607 | step=5.232; comm=51.730 |

- step_ratio=5.060606848495879
- comm_ratio=49.861367548114536
- **primary_ratio=49.861367548114536** (comm_ms) ← 主证
