# Loud acceptance: P1-EXT-B

- window: measure step [100, 300] rank0 `step_ms` median
- threshold C1/C0 ≥ **1.6**
- injection.log: `warmup+start`
- verdict: **FAIL_WEAK**

| config | median step_ms | vs C0 |
|---|---:|---:|
| C0_baseline | 99.06 | 1.00 |
| C1_inject_none | 158.22 | 1.60 |
| C2_probing | — | — |

C1/C0 = 1.597
