# Greyhound Contrast · P1-EXT-B Loud

- run_id: `contrast-p1-ext-b-20260725_121407`
- case_ref: `20260725_014350-yjr-as-c-p1-ext-b-loud`
- dose: INLINE hbm mb=512 copies=48 victim=7; window [100,300]；窗对齐 Case [100,300]
- fairness: `collect_seq` 真实 per-rank 序列 + C0 假阳性对照
- detect_ok: **yes**；detect_mode: **autonomous**（自主= coll 比≥1.6 或 Rbeast 变点[C1有/C0无]）
- oracle_trigger: **no**（未把注入窗写入判定）；注入窗 [100,300] 仅标注；step_ms 窗比=2.070（剂量核对，非 Greyhound 规则）
- preload: cyclecounter stub + libhcclprobe.so；Redis :16379；pod=`yysong-worker-1`

## A) autonomous · collect-min AllReduce host-wall

| arm | n | median dur_us |
|-----|--:|-------------:|
| C0  | 70336 | 107.0 |
| C1  | 70336 | 108.0 |

**C1/C0 coll ratio = 1.009** → FAIL (thr 1.6)

## B) autonomous · Greyhound Rbeast（真实 per-rank 序列；C0 假阳性对照）

> call_id 用真实 (op,count) 签名序列、call_time 用真实 t0（`collect_seq`），跑 Greyhound 自带 find_period+find_performance_drop。健康线 C0 同跑作对照。

| arm | rep_rank | n_calls | uniq_sig | acf_period | n_changepoints |
|-----|---------:|--------:|---------:|-----------:|---------------:|
| C0  | 109588 | 4401 | 10 | 8 | 0 |
| C1  | 114089 | 4401 | 10 | 8 | 2 |

- C1 changepoints: [{'id': 144, 't': 22.673997163772583}, {'id': 331, 't': 64.03469705581665}]
- C0 changepoints: []
- rbeast_hit (C1有/C0无): **True**
- error: C1=None C0=None

## C) dose check · step_ms in oracle window (not Greyhound rule)

| arm | window median step_ms |
|-----|----------------------:|
| C0  | 75.14 |
| C1  | 155.53 |
| C1/C0 | 2.070 → dose_OK |

## Verdict

- **autonomous_detect**: YES (coll_pass=False, rbeast_hit=True, rbeast_fp=False)
- **dose_reproduced**: YES (step_ms)

Note: P1-EXT-B 注入下 Greyhound 主路径是 CCL 时间戳+变点。若 coll/Rbeast 无咬合而 step_ms 有抬升，记能力边界，不焊 D4。
