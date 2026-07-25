# Loud acceptance: P2-SW-B (comm_ms primary)

- window: measure step [100, 300] rank0
- threshold C1/C0 **comm_ms** ≥ **1.3** (step 不强制)
- injection.log: `hccl_algo`
- verdict: **PASS**

| config | median step_ms | median comm_ms | vs C0 (step/comm) |
|---|---:|---:|---|
| C0_baseline | 83.037 | 12.294 | - |
| C1_inject_none | 93.946 | 22.36 | step=1.131; comm=1.819 |
| C2_probing | 95.333 | 23.015 | step=1.148; comm=1.872 |

- step_ratio=1.1313751701048929
- **comm_ratio=1.8187733853912476** ← 主证
