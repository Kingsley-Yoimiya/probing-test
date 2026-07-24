# Loud acceptance: P1-EXT-A

- window: measure step [100, 300] rank0 `step_ms` median
- threshold C1/C0 ≥ **1.8**
- injection.log: `warmup+start`
- verdict: **PASS**

| config | median step_ms | vs C0 |
|---|---:|---:|
| C0_baseline | 98.77 | 1.00 |
| C1_inject_none | 372.87 | 3.78 |
| C2_probing | — | — |

C1/C0 = 3.775
