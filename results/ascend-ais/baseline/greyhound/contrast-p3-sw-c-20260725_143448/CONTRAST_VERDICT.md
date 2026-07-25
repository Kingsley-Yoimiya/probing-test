# Greyhound Contrast · P3-SW-C Loud

- run_id: `contrast-p3-sw-c-20260725_143448`
- case_ref: `20260725_135238-yjr-as-c-p3-sw-c-loud`
- dose: sidecar 8c cpu_n=nproc cpu_load=90 mb=1 leak_every=1.0 max_chunks=64; window [100,300]; gold≈2.49；窗对齐 Case [100,300]
- fairness: `collect_seq` 真实 per-rank 序列 + C0 假阳性对照
- detect_ok: **yes**；detect_mode: **autonomous**（自主= coll 比≥1.3 或 Rbeast 变点[C1有/C0无]）
- oracle_trigger: **no**（未把注入窗写入判定）；注入窗 [100,300] 仅标注；step_ms 窗比=2.509（剂量核对，非 Greyhound 规则）
- preload: cyclecounter stub + libhcclprobe.so；Redis :16379；pod=`yysong-worker-1`

## A) autonomous · collect-min AllReduce host-wall

| arm | n | median dur_us |
|-----|--:|-------------:|
| C0  | 70336 | 122.1 |
| C1  | 70336 | 124.0 |

**C1/C0 coll ratio = 1.016** → FAIL (thr 1.3)

## B) autonomous · Greyhound Rbeast（真实 per-rank 序列；C0 假阳性对照）

> call_id 用真实 (op,count) 签名序列、call_time 用真实 t0（`collect_seq`），跑 Greyhound 自带 find_period+find_performance_drop。健康线 C0 同跑作对照。

| arm | rep_rank | n_calls | uniq_sig | acf_period | n_changepoints |
|-----|---------:|--------:|---------:|-----------:|---------------:|
| C0  | 276845 | 4401 | 10 | 8 | 0 |
| C1  | 281418 | 4401 | 10 | 8 | 1 |

- C1 changepoints: [{'id': 341, 't': 102.88634395599365}]
- C0 changepoints: []
- rbeast_hit (C1有/C0无): **True**
- error: C1=None C0=None

## C) dose check · step_ms in oracle window (not Greyhound rule)

| arm | window median step_ms |
|-----|----------------------:|
| C0  | 88.38 |
| C1  | 221.78 |
| C1/C0 | 2.509 → dose_OK |

## Verdict

- **autonomous_detect**: YES (coll_pass=False, rbeast_hit=True, rbeast_fp=False)
- **dose_reproduced**: YES (step_ms)

Note: P3-SW-C 注入下 Greyhound 主路径是 CCL 时间戳+变点。若 coll/Rbeast 无咬合而 step_ms 有抬升，记能力边界，不焊 D4。
