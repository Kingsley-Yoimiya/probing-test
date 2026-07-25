# Greyhound Contrast · P3-EXT-A Loud（公平性重跑）

- run_id: `contrast-p3-ext-a-20260725_114502`
- case_ref: `20260724_231918-yjr-as-c-p3exta-loud` (C1/C0 step_ms=1.97)
- dose: stress-ng `--cpu $(nproc) --cpu-load 90`；窗对齐 Case [100,300]
- fairness: `collect_seq` 真实 per-rank 序列 + C0 假阳性对照（旧 S4 `yjr-as-b-gh-s4-20260725_002805` 保留）
- detect_ok: **no**；detect_mode: **no_bite**（自主= coll 比≥1.3 或 Rbeast 变点[C1有/C0无]）
- oracle_trigger: **no**（未把注入窗写入判定）；注入窗 [100,300] 仅标注；step_ms 窗比=1.922（剂量核对，非 Greyhound 规则）
- preload: cyclecounter stub + libhcclprobe.so；Redis :16379；pod=`yysong-worker-1`

## A) autonomous · collect-min AllReduce host-wall

| arm | n | median dur_us |
|-----|--:|-------------:|
| C0  | 70336 | 120.2 |
| C1  | 70336 | 125.9 |

**C1/C0 coll ratio = 1.048** → FAIL (thr 1.3)

## B) autonomous · Greyhound Rbeast（真实 per-rank 序列；C0 假阳性对照）

> call_id 用真实 (op,count) 签名序列、call_time 用真实 t0（`collect_seq`），跑 Greyhound 自带 find_period+find_performance_drop。健康线 C0 同跑作对照。

| arm | rep_rank | n_calls | uniq_sig | acf_period | n_changepoints |
|-----|---------:|--------:|---------:|-----------:|---------------:|
| C0  | 78844 | 4401 | 10 | 8 | 0 |
| C1  | 83146 | 4401 | 10 | 8 | 0 |

- C1 changepoints: []
- C0 changepoints: []
- rbeast_hit (C1有/C0无): **False**
- error: C1=None C0=None

## C) dose check · step_ms in oracle window (not Greyhound rule)

| arm | window median step_ms |
|-----|----------------------:|
| C0  | 91.05 |
| C1  | 175.03 |
| C1/C0 | 1.922 → dose_OK |

## Verdict

- **autonomous_detect**: NO (coll_pass=False, rbeast_hit=False, rbeast_fp=False)
- **dose_reproduced**: YES (step_ms)

Note: P3-EXT-A 是 host CPU 抢占；Greyhound 主路径是 CCL 时间戳+变点。若 coll/Rbeast 无咬合而 step_ms 有抬升，记能力边界（同 XPUTimer S4），不焊 D4。
