# 符号对照：CUDA → MetaX → Ascend

> MetaX 已证实：**不能**假设 `nccl*`/`cuda*` 同名导出。昇腾必须同样用 `nm -D` 实测后再写 hook。  
> 参考：`~/Codespace/probing-baselines/xputimer-metax/xpu_timer/metax_probe/README.md`  
> **状态（2026-07-24 23:13）**：Ascend 列 = **pod 实测已填**（`yysong-worker-2` / torch_npu 2.7.1.post2 / CANN 8.5.0）。`U Hccl*` 齐全；**无** `U aclrtLaunchKernel` → hook 以 Hccl\* 为主。

## 采集命令（接入训练镜像 pod 后跑）

```bash
# 库路径按镜像改
HCCL_SO=${HCCL_SO:-/usr/local/Ascend/ascend-toolkit/latest/lib64/libhccl.so}
ACL_SO=${ACL_SO:-/usr/local/Ascend/ascend-toolkit/latest/lib64/libascendcl.so}
TORCH_NPU_SO=${TORCH_NPU_SO:-$(python - <<'PY'
import pathlib
try:
  import torch_npu
  p = pathlib.Path(torch_npu.__file__).parent
except Exception:
  p = pathlib.Path()
cands = list(p.rglob('libtorch_npu*.so')) + list(p.rglob('*npu*.so'))
print(cands[0] if cands else '')
PY
)}

echo "=== libhccl exports ==="
nm -D "$HCCL_SO" 2>/dev/null | rg -i ' T Hccl(AllReduce|AllGather|Broadcast|Reduce|Send|Recv)' | head -40
echo "=== libascendcl aclrt ==="
nm -D "$ACL_SO" 2>/dev/null | rg ' T aclrt(LaunchKernel|RecordEvent|CreateEvent|QueryEvent|EventElapsedTime|DestroyEvent)' | head -40
echo "=== torch_npu undefined (critical) ==="
nm -D "$TORCH_NPU_SO" 2>/dev/null | rg ' U (Hccl|aclrt|nccl|cuda)' | head -60
```

把 **pod 镜像** 输出贴到下方「实测」表；跳板 toolkit 摘录不能替代 torch `U` 表。

## 对照表

| 角色 | CUDA (原版) | MetaX (已适配) | Ascend（pod 实测） |
|------|-------------|----------------|--------------------------|
| kernel launch | `cudaLaunchKernel` | `mcLaunchKernel` | **不 hook**：torch_npu **无** `U aclrtLaunchKernel`（训练热路径不经此符号） |
| event create | `cudaEventCreate` | `mcEventCreate` | `aclrtCreateEvent`（libascendcl `T`；torch **无** `U`） |
| event record | `cudaEventRecord` | `mcEventRecord` | `aclrtRecordEvent`（torch `U` ✓） |
| event query | `cudaEventQuery` | `mcEventQuery` | `aclrtQueryEvent`（libascendcl `T`；torch **无** `U`） |
| event elapsed | `cudaEventElapsedTime` | `mcEventElapsedTime` | `aclrtEventElapsedTime`（torch `U` ✓） |
| event destroy | `cudaEventDestroy` | `mcEventDestroy` | `aclrtDestroyEvent`（torch `U` ✓） |
| AllReduce | `ncclAllReduce` | `mcclAllReduce` | `HcclAllReduce`（torch `U` ✓；NEEDED→libhccl） |
| AllGather | `ncclAllGather` | `mcclAllGather` | `HcclAllGather`（torch `U` ✓） |
| Broadcast | `ncclBroadcast` | `mcclBroadcast` | `HcclBroadcast`（**单 buffer**；torch `U` ✓） |
| ReduceScatter | `ncclReduceScatter` | `mcclReduceScatter` | `HcclReduceScatter`（torch `U` ✓） |
| Reduce | `ncclReduce` | `mcclReduce` | `HcclReduce`（libhccl `T`；torch **无** `U`，仍导出） |
| Send / Recv | `ncclSend` / `ncclRecv` | `mcclSend` / `mcclRecv` | `HcclSend` / `HcclRecv`（torch `U` ✓） |
| 可见设备 env | `CUDA_VISIBLE_DEVICES` | `MACA_VISIBLE_DEVICES` | `ASCEND_VISIBLE_DEVICES`（pod 已用） |
| 拓扑/带宽 CLI | `nvidia-smi` | `mx-smi` | `npu-smi` |
| shm 前缀 | `nccl*` | `nccl*`+`mccl*` | `hccl*`（惯例） |
| runtime .so | `libcudart` | `libmcruntime.so` | `libascendcl.so`（+ `libruntime.so`） |
| CCL .so | `libnccl.so` | `libmccl.so` | `libhccl.so` |

### 关键风险（写 hook 前必读）

1. **torch 链接面已实测**：`libtorch_npu.so` **直接** `U Hccl*` 且 NEEDED→`libhccl.so`（与 MetaX 的 `U mccl*` 同构）。LD_PRELOAD 导出 `Hccl*` 即可。  
2. **`aclrtLaunchKernel` 不在热路径**：torch_npu `nm` 无该 `U` → S1/S2 以 **Hccl\* metadata + host-wall** 为主（对标 MetaX `COLL_META`）；kernel event 计时为可选后续。  
3. **禁止假设 `nccl*`/`cuda*` 同名**仍成立。  
4. **真盘**：pod 内写 `/data/yinjinrun.p-huawei/...`（PVC）；`/afs-a3-weight-share/...` 在本镜像可能是 overlay 假路径。

## 实测（粘贴区）

### A. 跳板 toolkit（非训练镜像；2026-07-24）

```
# host: ais-cf3e61a5
# image/toolkit: /usr/local/Ascend/cann-8.5.1/lib64
# full dump: results/ascend-ais/baseline/xputimer/s0_offline_20260724/jump_cann851_nm.txt

## libhccl.so (T)
HcclAllGather / HcclAllGatherV
HcclAllReduce
HcclAlltoAll / HcclAlltoAllV / HcclAlltoAllVC
HcclBatchSendRecv
HcclBroadcast
HcclRecv / HcclSend
HcclReduce / HcclReduceScatter / HcclReduceScatterV
HcclScatter

## libascendcl.so (T, timing-related)
aclrtCreateEvent / aclrtCreateEventWithFlag / aclrtCreateEventExWithFlag
aclrtDestroyEvent
aclrtEventElapsedTime
aclrtGetDevice / aclrtGetDeviceCount
aclrtLaunchKernel
aclrtQueryEvent
aclrtRecordEvent
```

### B. 训练镜像 pod（已填 · symbols_filled=yes）

```
# date=2026-07-24T23:12+08 pod=yysong-worker-2
# torch_npu=2.7.1.post2  torch=2.7.1+cpu  CANN=ascend-toolkit→cann-8.5.0
# full: results/ascend-ais/baseline/xputimer/yjr-as-b-xpu-s2-20260724_231201/nm/nm_pod.txt

## libtorch_npu.so U Hccl*
HcclAllGather / HcclAllReduce / HcclBroadcast
HcclRecv / HcclReduceScatter / HcclSend
(+ HcclComm* / HcclGetRootInfo；未 hook)

## libtorch_npu.so U aclrt* (timing-related)
aclrtRecordEvent / aclrtEventElapsedTime / aclrtDestroyEvent
aclrtSynchronizeEvent / aclrtStreamWaitEvent
# NO U aclrtLaunchKernel / aclrtCreateEvent / aclrtQueryEvent

## libhccl.so T (镜像内)
HcclAllGather / HcclAllReduce / HcclBroadcast / HcclReduceScatter
HcclReduce / HcclSend / HcclRecv / …

## S2 evidence
# LD_PRELOAD libxpu_timer_ascend.so + torchrun --nproc_per_node=2
# ascend_metrics.*.prom: xpu_timer_ascend_coll_events_total=80 / rank
# ascend_trace.*.jsonl: 80 lines / rank (HcclAllReduce+HcclAllGather)

## Greyhound collect-min（yysong-worker-1 · 同镜像）
# LD_PRELOAD libhcclprobe.so（C 符号）→ libtorch_npu 绑到 probe（LD_DEBUG）
# results/.../greyhound/yjr-as-b-gh-20260724_232223/hcclprobe.collect.jsonl = 336 lines
# 坑：g++ mangling → 绑真 libhccl、dump 空；须 gcc/extern "C"
```
