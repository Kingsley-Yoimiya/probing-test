# Loud acceptance: P1-EXT-B

- window: measure step [100, 300] rank0 `step_ms` median
- threshold C1/C0 ≥ **1.6**
- injection.log: `warmup+start`
- verdict: **PASS**

| config | median step_ms | vs C0 |
|---|---:|---:|
| C0_baseline | 98.50 | 1.00 |
| C1_inject_none | 171.75 | 1.74 |
| C2_probing | 169.79 | 1.72 |

C1/C0 = 1.744
C2/C0 = 1.724
