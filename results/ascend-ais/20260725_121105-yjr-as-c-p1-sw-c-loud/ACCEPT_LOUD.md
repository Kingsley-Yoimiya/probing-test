# P1-SW-C spike acceptance

- window measure [100,300]
- pass if victim rank7: median≥1.3 OR p99≥1.5 OR max≥2.5
- verdict: **BITE_OK**

| rank | median | p99 | max | hit |
|---|---|---|---|---|
| rank0 | med 78.7/77.1=1.02 | p99 121.2/82.5=1.47 | max 1867.2/114.5=16.31 | PASS |
| rank7 | med 78.6/77.1=1.02 | p99 358.1/351.1=1.02 | max 2227.1/481.0=4.63 | PASS |
