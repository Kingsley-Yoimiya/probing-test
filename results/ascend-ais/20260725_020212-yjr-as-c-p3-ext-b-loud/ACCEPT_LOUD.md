# Loud acceptance: P3-EXT-B

- window: measure step [100, 300] rank0 `step_ms` median
- threshold C1/C0 ≥ **1.3**
- injection.log: `started` (fio_loud_nj16)
- verdict: **PASS**

| config | median step_ms | vs C0 |
|---|---:|---:|
| C0_baseline | 84.67 | 1.00 |
| C1_inject_none | 180.51 | 2.13 |
| C2_probing | 148.95 | 1.76 |

C1/C0 = 2.132
C2/C0 = 1.759
