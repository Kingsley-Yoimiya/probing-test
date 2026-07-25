# Greyhound Ascend（stub → collect-min）

目标产物：`libhcclprobe.so`（编排默认见 `config_denv_ascend.sh`）。

## 阶段

1. **stub `.so`**：constructor-only，验证 `LD_PRELOAD` 不破坏 HCCL 训练（S0/S1）  
2. **collect-min**：导出 **C 链接** `Hccl*`，JSONL dump → **S2_COLLECT**（已在 yysong-worker-1 16 卡验证）  
3. **真 probe + Redis / ACF**：缺 Redis → `PENDING`（不写 ENV-BLOCKED）

## 脚本

| 文件 | 作用 |
|------|------|
| `install_stub.sh` | load-only stub |
| `install_collect_min.sh` / `collect_min.c` | Hccl* interpose + `GREYHOUND_DUMP` JSONL |
| `preload_snippet.sh` | `eval "$(…)"` 挂 `LD_PRELOAD` |
| `smoke_allreduce.py` | torch_npu AllReduce 短训 |
| `run_s1s2_worker1.sh` | worker-1 一键编 probe + 16 卡验收 |
| `selftest_host.sh` | 无 NPU 本机加载自检 |

```bash
# pod 内（hold-exec: yysong-worker-1）
bash install_collect_min.sh /data/yinjinrun.p-huawei/probe-bundle/greyhound
NPROC=16 bash run_s1s2_worker1.sh
# 验收: SUMMARY.json collect_ok=true；hcclprobe.collect.jsonl 非空

# 本机（无卡）
bash selftest_host.sh
```

**坑**：必须用 `gcc`/`extern "C"` 导出 `HcclAllReduce`；`g++` mangling 会导致 torch 仍绑真 `libhccl`，dump 为空。

细节：`results/ascend-ais/baseline/greyhound/NOTES.md`。
