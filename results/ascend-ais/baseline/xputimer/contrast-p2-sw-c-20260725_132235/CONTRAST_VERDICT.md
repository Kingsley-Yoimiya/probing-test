# XPUTimer contrast · P2-SW-C Loud

- case_id: `P2-SW-C`
- case_ref: `20260725_124102-yjr-as-c-p2-sw-c-loud`
- dose: topo_5c device_rev=1 topo_extra_ar=512 topo_ar_elems=262144; window [100,300]
- detect_mode: **cross_run_contrast** （自主=prom hang/slow flags；跨-run=C1/C0 中位比≥1.15，需外部健康基线 C0）
- metric: jsonl `dur_us` of `HcclAllReduce` (host-wall around Hccl*)

## A) XPUTimer 自主信号（.prom hang/slow flags；无需外部基线）

| arm | coll_events | hang_flags | slow_flags |
|-----|-----------:|-----------:|-----------:|
| C0  | 81401 | 0 | 0 |
| C1  | 4587001 | 0 | 0 |

**autonomous_flag (C1 hang+slow>0) = False** （SLOW_REPORT_US=0 关、HANG_TIMEOUT_MS=60000；未开 oracle INJECT_STALL）

## B) cross-run 中位对照（需外部健康基线 C0，非自主）

| arm | n | median dur_us | ≥1.5×C0med（噪声诊断，非判据） |
|-----|--:|-------------:|------------------------------:|
| C0  | 70336 | 113.0 | 3139 |
| C1  | 4575936 | 67.0 | 27753 |

**C1/C0 coll ratio = 0.593** → FAIL (thr 1.15)

> ⚠️ `≥1.5×C0med` 计数仅作噪声诊断：C0 健康线自身就有 3139 个，说明该线在集合通信 host-wall 上可能大面积误报，**不作判据**。

## C) dose_check（step_ms 窗内中位；非 XPUTimer 规则）

- window: [100, 300)
- C0 median step_ms: 75.858 (n=3200)
- C1 median step_ms: 160.764 (n=3200)
- C1/C0 step_ms = 2.119 → PASS (thr 1.15)


## C2) dose_check 主证=comm_ms（P2-SW-C；step 旁证不单独 FAIL）

- window: [100, 300)
- C0 median comm_ms: 6.306 (n=3200)
- C1 median comm_ms: 87.716 (n=3200)
- **C1/C0 comm_ms = 13.910** → PASS (thr 1.15)
- C1/C0 step_ms = 2.119 （旁证；金标≈5.06；本对照 step PASS）
- Probing gold C1/C0_comm≈49.86；dose_check 主证 → PASS
## Verdict

- **autonomous_detect**: NO (XPUTimer 自己的 hang/slow flags)
- **cross_run_contrast**: FAIL (C1/C0=0.593；需外部基线)
- **dose_check**: PASS (comm_ms C1/C0=13.910 主证；step_ms=2.119 旁证)
- **detect_ok**: false (autonomous OR cross_run；dose_check 单独记)
- **detect_mode**: `cross_run_contrast`

Note: 如实记能力边界；无咬合也是 DONE。不改对手阈值、不覆盖 Probing 分。
