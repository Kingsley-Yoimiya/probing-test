# Greyhound · STATUS

phase: S4_DETECT
updated: 2026-07-25 12:14
pool_job: hold-exec → yysong-worker-1（标签 yjr-as-b-gh-*）
collect_ok: yes
detect_ok: yes（P1-EXT-A Rbeast 自主；P3-EXT-A 仍 no_bite）
oracle_trigger: no（注入窗未写入判定）
dose_ok: yes（P1 step_ms≈3.92；P3≈1.92）
blocker: none
next: 继续 CONTRAST_QUEUE 其余格；不焊 D4 / 不改对手阈值
evidence_p3: results/ascend-ais/baseline/greyhound/contrast-p3-ext-a-20260725_114502/
evidence_p1: results/ascend-ais/baseline/greyhound/contrast-p1-ext-a-20260725_120526/
case_ref_p3: 20260724_231918-yjr-as-c-p3exta-loud
case_ref_p1: 20260725_011129-yjr-as-c-p1-ext-a-loud

## 对照摘要

| case | coll C1/C0 | Rbeast (C1/C0 cp) | step_ms | detect_ok |
|------|-----------:|-------------------:|--------:|-----------|
| P3-EXT-A | 1.048 FAIL | 0/0 | 1.922 OK | no |
| P1-EXT-A | 1.018 FAIL | **2/0 hit** | 3.924 OK | **yes**（autonomous） |

> 公平性：`collect_seq` 真实 per-rank + C0 假阳性对照；不改 Greyhound 阈值。
