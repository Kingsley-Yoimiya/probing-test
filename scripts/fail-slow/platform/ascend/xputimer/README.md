# XPUTimer Ascend hook

对标：`~/Codespace/probing-baselines/xputimer-metax/xpu_timer/metax_probe/`。

## 实测结论（yysong-worker-2 · 2026-07-24）

- `libtorch_npu.so` **直接** `U HcclAllReduce|AllGather|Broadcast|ReduceScatter|Send|Recv`（NEEDED → `libhccl.so`）。
- **无** `U aclrtLaunchKernel` → 训练热路径不走该符号；S1/S2 以 **Hccl\* metadata + host-wall** 为主（对标 MetaX `COLL_META`）。
- 禁止假设 `nccl*`/`cuda*` 同名。

## 文件

| 文件 | 作用 |
|------|------|
| `xpu_timer_ascend_hook.cc` | LD_PRELOAD：导出 Hccl\*；prom/jsonl |
| `build_ascend_hook.sh` | `g++ -shared` → `libxpu_timer_ascend.so` |
| `scan_symbols_on_pod.sh` | pod 内 `nm -D` → `.symbols_verified` |
| `ascend_selftest.py` | 单卡短训（S1 不炸） |
| `ascend_dist_test.py` | 2-rank HCCL（S2 非空事件） |

## 构建 + 运行（yysong-worker-2）

```bash
# 真盘：/data/yinjinrun.p-huawei/...（勿写宋 AFS；勿用假 /afs 空目录）
DUMP=/data/yinjinrun.p-huawei/results/ascend-ais/baseline/xputimer/<run_id>
bash scan_symbols_on_pod.sh "$DUMP/nm"
bash build_ascend_hook.sh

# S1
XPU_TIMER_DUMP_DIR=$DUMP LD_PRELOAD=./libxpu_timer_ascend.so \
  python3 ascend_selftest.py --iters 30

# S2（需 ≥2 卡）
XPU_TIMER_DUMP_DIR=$DUMP LD_PRELOAD=./libxpu_timer_ascend.so \
  torchrun --nproc_per_node=2 ascend_dist_test.py --iters 40

# S3a SLOW（阈值；标 oracle）
XPU_TIMER_SLOW_REPORT_US=50 XPU_TIMER_DUMP_DIR=$DUMP/s3a \
  LD_PRELOAD=./libxpu_timer_ascend.so \
  torchrun --nproc_per_node=2 ascend_dist_test.py --iters 20
python3 parse_ascend_detect.py $DUMP/s3a --require slow

# S3c HANG（inject-stall oracle；peer-desync 因 HCCL 异步暂不稳）
XPU_TIMER_HANG_TIMEOUT_MS=400 XPU_TIMER_INJECT_STALL_MS=1200 \
  XPU_TIMER_DUMP_DIR=$DUMP/s3c LD_PRELOAD=./libxpu_timer_ascend.so \
  torchrun --nproc_per_node=2 ascend_dist_test.py --iters 4
python3 parse_ascend_detect.py $DUMP/s3c --require hang
```

## 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `XPU_TIMER_ENABLE` | 1 | 总开关 |
| `XPU_TIMER_DUMP_DIR` | `/tmp/xpu_timer_ascend` | prom/jsonl/flag |
| `XPU_TIMER_HCCL_LIB` | `libhccl.so` | 原库覆盖 |
| `XPU_TIMER_HANG_TIMEOUT_MS` | 2000 | outstanding ≥ 此值 → HANG |
| `XPU_TIMER_SLOW_REPORT_US` | 0 | host-wall ≥ 此值 → SLOW |
| `XPU_TIMER_INJECT_STALL_MS` | 0 | S3 oracle：interposer 内 stall，供 hang poller 观测 |
| `XPU_TIMER_POLLER_SLEEP_US` | 200 | hang poller 周期 |
