# Greyhound Contrast · P2-SW-B Loud

- run_id: `contrast-p2-sw-b-20260725_134521`
- case_ref: `20260725_122911-yjr-as-c-p2-sw-b-loud`
- dose: hccl_algo algo=ring stress_mb=512 buffsize=8; window [100,300]；窗对齐 Case [100,300]
- fairness: `collect_seq` 真实 per-rank 序列 + C0 假阳性对照
- detect_ok: **no**；detect_mode: **no_bite**（自主= coll 比≥1.3 或 Rbeast 变点[C1有/C0无]）
- oracle_trigger: **no**（未把注入窗写入判定）；注入窗 [100,300] 仅标注；step_ms 窗比=1.154（剂量核对，非 Greyhound 规则）
- preload: cyclecounter stub + libhcclprobe.so；Redis :16379；pod=`yysong-worker-1`

## A) autonomous · collect-min AllReduce host-wall

| arm | n | median dur_us |
|-----|--:|-------------:|
| C0  | 79136 | 108.0 |
| C1  | 79136 | 106.1 |

**C1/C0 coll ratio = 0.982** → FAIL (thr 1.3)

## B) autonomous · Greyhound Rbeast（真实 per-rank 序列；C0 假阳性对照）

> call_id 用真实 (op,count) 签名序列、call_time 用真实 t0（`collect_seq`），跑 Greyhound 自带 find_period+find_performance_drop。健康线 C0 同跑作对照。

| arm | rep_rank | n_calls | uniq_sig | acf_period | n_changepoints |
|-----|---------:|--------:|---------:|-----------:|---------------:|
| C0  | 195835 | 4951 | 11 | 9 | 0 |
| C1  | 203645 | 4951 | 11 | 9 | 0 |

- C1 changepoints: []
- C0 changepoints: []
- rbeast_hit (C1有/C0无): **False**
- error: C1=None C0=None

## C) dose check · step_ms in oracle window (not Greyhound rule)

| arm | window median step_ms |
|-----|----------------------:|
| C0  | 81.11 |
| C1  | 93.62 |
| C1/C0 | 1.154 → dose_WEAK |


## C2) dose_check 主证=comm_ms（P2-SW-B；step 弱升不单独 FAIL）

- window: [100, 300)
- C0 median comm_ms: 11.895 (n=3200)
- C1 median comm_ms: 22.148 (n=3200)
- **C1/C0 comm_ms = 1.862** → PASS (thr 1.3)
- C1/C0 step_ms = 1.152 （旁证；金标≈1.13 不 FAIL；本对照 step WEAK/FAIL）
- Probing gold C1/C0_comm≈1.82；dose_check 主证 → PASS
## Verdict

- **autonomous_detect**: NO (coll_pass=False, rbeast_hit=False, rbeast_fp=False)
- **dose_reproduced**: YES (comm_ms=1.862 主证；step=1.152 旁证弱升)

Note: P2-SW-B 注入下 Greyhound 主路径是 CCL 时间戳+变点。若 coll/Rbeast 无咬合而 step_ms 有抬升，记能力边界，不焊 D4。
