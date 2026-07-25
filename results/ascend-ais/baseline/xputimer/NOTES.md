# XPUTimer Ascend · NOTES

## 符号（yysong-worker-2 · 2026-07-24）

- torch_npu **U Hccl\*** → LD_PRELOAD 可行；**无** `U aclrtLaunchKernel`
- 真盘：`/data/yinjinrun.p-huawei/`（PVC）；本机备份 `results/ascend-ais/baseline/xputimer/`
- 脚本：`project/probing-test/scripts/fail-slow/platform/ascend/xputimer/`

## S1–S3

| 阶段 | 结果 |
|------|------|
| S1 | preload 单卡不炸 |
| S2 | 2-rank；`coll_events_total=80`/rank → `yjr-as-b-xpu-s2-20260724_231201/` |
| S3a SLOW | `XPU_TIMER_SLOW_REPORT_US=50` → `slow_flags=40`；parse OK（**oracle**） |
| S3b desync | peer-desync **未**稳触发 HANG（HCCL 异步） |
| S3c HANG | `INJECT_STALL_MS=1200` → `hang_flags=8`；parse OK（**oracle**） |

S3：`yjr-as-b-xpu-s3-20260724_231733/`

## S4 · P3-EXT-A Loud 对照（终态）

- case_ref：`20260724_231918-yjr-as-c-p3exta-loud`（Case C1/C0 step_ms=1.97）
- 落点：`yysong-worker-2` · 16 卡 · 同剂量 `stress-ng --cpu $(nproc) --cpu-load 90` · 窗 [100,300]
- 脚本：`s4_p3exta_contrast.sh` + `s4_verdict.py`
- run_id：`yjr-as-b-xpu-s4-20260724_233105/`
- **detect_mode=cross_run_contrast**（2026-07-25 修正，原误标 autonomous）：
  - XPUTimer **自主信号**（它自己 .prom 的 hang/slow flags）：C0/C1 **均 0**（SLOW_REPORT_US=0 关、HANG=60s host CPU 抢占够不到）→ 自主检出 = **NO**。
  - **跨-run 中位比**（需外部健康基线 C0，非 run 内自主）：HcclAllReduce `dur_us` 中位 C1/C0=**1.032** → **FAIL**（thr 1.3）。
  - 原脚本 `≥1.5×C0med` 的 SLOW 计数（C0=10327 / C1=11288）**改为噪声诊断，不作判据**——C0 健康线自身就爆表，证明该线在 host-wall 上大面积误报。
- **公平性核验**（2026-07-25）：即便按 rules §三·五A 用健康集冻结 SLOW 阈值（C0 p99.9=685µs），C1 超阈率/C0=**0.99×**——host CPU 抢占对 XPUTimer 结构性不可见，**非配置吃亏**。
- 结论：P3-EXT-A（host CPU 抢占）未抬升 HCCL host-wall、自主 flags=0；能力范围内如实记「无咬合」，不焊 D4。

## 判定路径

- hook：hang poller + SLOW 阈值（XPUTimer 自主信号，写入 .prom flags）
- S3 解析：`parse_ascend_detect.py`
- S4 解析：`s4_verdict.py` ← 自主 flags 读 `ascend_metrics.*.prom`；跨-run 中位比读 `ascend_trace.*.jsonl`
- 产物：`S4_VERDICT.md` + `S4_SUMMARY.json`（detect_mode / autonomous_flag / cross_run_contrast 分列）

## 对照 · P1-EXT-A Loud（流水线 2 · 2026-07-25）

- case_ref：`20260725_011129-yjr-as-c-p1-ext-a-loud`（Case C1/C0 step_ms=3.87）
- 落点：`yysong-worker-2` · 16 卡 · 冻结 dose `inline_cube_size=8192,inline_cube_mm=64` · 窗 [100,300] · mode=gpu_bound
- 脚本：`contrast_p1exta.sh` + `s4_verdict.py`（分列自主 flags vs 跨-run）
- run_id：`contrast-p1-ext-a-20260725_114546/`
- **detect_mode=cross_run_contrast**（不得误标 autonomous）：
  - 自主（.prom hang/slow）：C0/C1 **均 0** → **NO**
  - 跨-run coll `dur_us` 中位 C1/C0=**1.036** → **FAIL**（thr 1.5）
  - dose_check step_ms C1/C0=**3.955** → **PASS**（剂量生效；非 XPUTimer 规则）
- 结论：同卡 INLINE cube 抬升 step_ms，但不抬 HCCL host-wall、自主 flags=0；能力边界如实「无咬合」
