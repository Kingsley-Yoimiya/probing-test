# XPUTimer contrast · P1-SW-C Loud

- case_id: `P1-SW-C`
- case_ref: `20260725_121105-yjr-as-c-p1-sw-c-loud`
- dose: INLINE 2c n=1024 every=1 fallback_s=0.25 victim=7; window [100,300]
- detect_mode: **cross_run_contrast** （自主=prom hang/slow flags；跨-run=C1/C0 中位比≥1.3，需外部健康基线 C0）
- metric: jsonl `dur_us` of `HcclAllReduce` (host-wall around Hccl*)

## A) XPUTimer 自主信号（.prom hang/slow flags；无需外部基线）

| arm | coll_events | hang_flags | slow_flags |
|-----|-----------:|-----------:|-----------:|
| C0  | 81401 | 0 | 0 |
| C1  | 81402 | 0 | 0 |

**autonomous_flag (C1 hang+slow>0) = False** （SLOW_REPORT_US=0 关、HANG_TIMEOUT_MS=60000；未开 oracle INJECT_STALL）

## B) cross-run 中位对照（需外部健康基线 C0，非自主）

| arm | n | median dur_us | ≥1.5×C0med（噪声诊断，非判据） |
|-----|--:|-------------:|------------------------------:|
| C0  | 70336 | 113.0 | 4723 |
| C1  | 70336 | 112.0 | 1579 |

**C1/C0 coll ratio = 0.991** → FAIL (thr 1.3)

> ⚠️ `≥1.5×C0med` 计数仅作噪声诊断：C0 健康线自身就有 4723 个，说明该线在集合通信 host-wall 上可能大面积误报，**不作判据**。

## C) dose_check（step_ms 窗内中位；非 XPUTimer 规则）

- window: [100, 300)
- C0 median step_ms: 76.436 (n=3200)
- C1 median step_ms: 76.887 (n=3200)
- C1/C0 step_ms = 1.006 → FAIL/NA (thr 1.3)


## C2) tip/max dose_check（victim local_rank；P1-SW-C 叙事）

- victim local_rank=7
- median C1/C0 step_ms = 1.005 （常盲）
- p99 C1/C0 = 2.484
- max C1/C0 = 4.897 （C1 max=2009.0 @step 100；C0 max=410.3）
- tip gate → PASS (med≥1.3 OR p99≥1.5 OR max≥2.5)
- Probing gold tip max≈4.63；本对照 tip max_ratio=4.897

## Verdict

- **autonomous_detect**: NO (XPUTimer 自己的 hang/slow flags)
- **cross_run_contrast**: FAIL (C1/C0=0.991；需外部基线)
- **dose_check**: FAIL/NA (step_ms median C1/C0=1.006；median盲)
- **tip_dose_check**: PASS (victim max C1/C0=4.897 @step100；p99=2.484；对齐 Probing tip max≈4.63)
- **detect_ok**: false (autonomous OR cross_run；dose_check 单独记)
- **detect_mode**: `cross_run_contrast`

Note: 如实记能力边界；无咬合也是 DONE。不改对手阈值、不覆盖 Probing 分。
