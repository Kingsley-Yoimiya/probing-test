# XPUTimer · STATUS

phase: S4_DETECT（对照波次进行中）
updated: 2026-07-25 11:50
pool_job: hold-exec → yysong-worker-2（标签 yjr-as-b-xpu-*）
symbols_filled: yes
collect_ok: yes
detect_mode: S3=oracle；对照=cross_run_contrast（自主 flags 与跨-run 中位比分列；不得误标 autonomous）
autonomous_flag: no（P3-EXT-A / P1-EXT-A 的 C1 hang+slow 均为 0）
blocker: none

## 对照完成

| case | run_id | dose_check | autonomous | cross-run coll | detect_ok |
|------|--------|------------|------------|----------------|-----------|
| P3-EXT-A | `yjr-as-b-xpu-s4-20260724_233105` | （host CPU） | NO | 1.032 FAIL | no |
| P1-EXT-A | `contrast-p1-ext-a-20260725_114546` | step_ms **3.955 PASS** | NO | **1.036 FAIL** | no |

evidence: `results/ascend-ais/baseline/xputimer/contrast-p1-ext-a-20260725_114546/`
next: CONTRAST_QUEUE 下一 PENDING × XPUTimer；或 S5 代价
