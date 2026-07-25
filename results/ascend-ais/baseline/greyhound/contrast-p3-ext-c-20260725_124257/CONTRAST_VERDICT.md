# Greyhound Contrast · P3-EXT-C Loud

- run_id: `contrast-p3-ext-c-20260725_124257`
- case_ref: `20260725_021906-yjr-as-c-p3-ext-c-loud`
- dose: stress_vm vm_n=96,vm_bytes=6G; window [100,300]；窗对齐 Case [100,300]
- fairness: `collect_seq` 真实 per-rank 序列 + C0 假阳性对照
- detect_ok: **no**；detect_mode: **no_bite**（自主= coll 比≥1.3 或 Rbeast 变点[C1有/C0无]）
- oracle_trigger: **no**（未把注入窗写入判定）；注入窗 [100,300] 仅标注；step_ms 窗比=1.063（剂量核对，非 Greyhound 规则）
- preload: cyclecounter stub + libhcclprobe.so；Redis :16379；pod=`yysong-worker-1`

## A) autonomous · collect-min AllReduce host-wall

| arm | n | median dur_us |
|-----|--:|-------------:|
| C0  | 70336 | 124.2 |
| C1  | 70336 | 160.9 |

**C1/C0 coll ratio = 1.296** → FAIL (thr 1.3)

## B) autonomous · Greyhound Rbeast（真实 per-rank 序列；C0 假阳性对照）

> call_id 用真实 (op,count) 签名序列、call_time 用真实 t0（`collect_seq`），跑 Greyhound 自带 find_period+find_performance_drop。健康线 C0 同跑作对照。

| arm | rep_rank | n_calls | uniq_sig | acf_period | n_changepoints |
|-----|---------:|--------:|---------:|-----------:|---------------:|
| C0  | 140668 | 4401 | 10 | 8 | 0 |
| C1  | 145849 | 4401 | 10 | 8 | 0 |

- C1 changepoints: []
- C0 changepoints: []
- rbeast_hit (C1有/C0无): **False**
- error: C1=None C0=None

## C) dose check · step_ms in oracle window (not Greyhound rule)

| arm | window median step_ms |
|-----|----------------------:|
| C0  | 93.68 |
| C1  | 99.59 |
| C1/C0 | 1.063 → dose_WEAK |

## Verdict

- **autonomous_detect**: NO (coll_pass=False, rbeast_hit=False, rbeast_fp=False)
- **dose_reproduced**: NO/WEAK (step_ms)

Note: P3-EXT-C 注入下 Greyhound 主路径是 CCL 时间戳+变点。若 coll/Rbeast 无咬合而 step_ms 有抬升，记能力边界，不焊 D4。


## Dose note（对照公平性）

- 冻结 dose `vm_n=96,vm_bytes=6G`；warmup 预热 page-in（`PAGEIN_PARTIAL used+6Gi`），窗内 Mem 仍 ~1.8Ti free。
- step_ms C1/C0=**1.063** dose_WEAK（Probing 金标准 1.59；XPU@worker-2 同参 step_ms=1.780）。
- coll 近阈 **1.296**（thr1.3）；Rbeast C1/C0 cp=0/0。不改对手阈值；不覆盖 Probing 分。
- 先前弱剂量轮 `contrast-p3-ext-c-20260725_123310`（coll=1.144）保留作对照。
