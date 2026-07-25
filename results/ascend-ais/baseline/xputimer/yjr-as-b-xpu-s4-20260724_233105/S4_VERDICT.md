# XPUTimer S4 · P3-EXT-A Loud contrast

- case_ref: `20260724_231918-yjr-as-c-p3exta-loud` (C1/C0 step_ms=1.97)
- dose: stress-ng `--cpu $(nproc) --cpu-load 90`；窗对齐 Case [100,300]
- detect_mode: **cross_run_contrast**（C1/C0 中位比≥1.3；需外部健康基线 C0，非 run 内自主判据）
- metric: jsonl `dur_us` of `HcclAllReduce` (host-wall around Hccl*)

## A) XPUTimer 自主信号（它自己 .prom 的 hang/slow flags；无需外部基线）

| arm | coll_events | hang_flags | slow_flags |
|-----|-----------:|-----------:|-----------:|
| C0  | 81401 | 0 | 0 |
| C1  | 81401 | 0 | 0 |

**autonomous_flag (C1 hang+slow>0) = False** （S4 配置 SLOW_REPORT_US=0 关、HANG_TIMEOUT_MS=60000；host CPU 抢占够不到 hang 阈）

## B) cross-run 中位对照（需外部健康基线 C0，非自主）

| arm | n | median dur_us | ≥1.5×C0med（噪声诊断，非判据） |
|-----|--:|-------------:|------------------------------:|
| C0  | 70336 | 126.0 | 10327 |
| C1  | 70336 | 130.0 | 11288 |

**C1/C0 coll ratio = 1.032** → FAIL (thr 1.3)

> ⚠️ `≥1.5×C0med` 计数仅作噪声诊断：C0 健康线自身就有 10327 个，说明该线在集合通信 host-wall 上大面积误报，**不作判据**。

## Verdict

- **autonomous_detect**: NO (XPUTimer 自己的 hang/slow flags)
- **cross_run_contrast**: FAIL (C1/C0=1.032；需外部基线)

Note: P3-EXT-A 是 host CPU 抢占；XPUTimer 天花板多为 D0–D1 信号。它自主检出=0（hang/slow 未触发）；集合通信 host-wall 也未随 Loud 抬升。能力范围内如实记「无咬合」，不声称 D4 RCA。
