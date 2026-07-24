# 符号对照：CUDA → MetaX → Ascend（待填）

> MetaX 已证实：**不能**假设 `nccl*`/`cuda*` 同名导出。昇腾必须同样用 `nm -D` 实测后再写 hook。  
> 参考：`~/Codespace/probing-baselines/xputimer-metax/xpu_timer/metax_probe/README.md`

## 采集命令（接入 pod 后跑）

```bash
# 库路径按镜像改
HCCL_SO=${HCCL_SO:-/usr/local/Ascend/ascend-toolkit/latest/lib64/libhccl.so}
TORCH_SO=${TORCH_SO:-$(python - <<'PY'
import torch, pathlib
print(next(pathlib.Path(torch.__file__).parent.glob('lib/libtorch*.so'), ''))
PY
)}

nm -D "$HCCL_SO" 2>/dev/null | rg -i 'hccl|nccl|AllReduce' | head -40
nm -D "$TORCH_SO" 2>/dev/null | rg -i 'Hccl|aclrt|cudaLaunch|nccl' | head -40
```

把输出贴到下方「实测」表。

## 对照表

| 角色 | CUDA (原版) | MetaX (已适配) | Ascend（待填） |
|------|-------------|----------------|----------------|
| kernel launch | `cudaLaunchKernel` | `mcLaunchKernel` | `?`（常为 `aclrtLaunchKernel` 或 torch 封装） |
| event | `cudaEvent*` | `mcEvent*` | `?` |
| AllReduce | `ncclAllReduce` | `mcclAllReduce` | `?`（`HcclAllReduce` / `hcclAllReduce`） |
| AllGather | `ncclAllGather` | `mcclAllGather` | `?` |
| Broadcast | `ncclBroadcast` | `mcclBroadcast` | `?` |
| 可见设备 env | `CUDA_VISIBLE_DEVICES` | `MACA_VISIBLE_DEVICES` | `ASCEND_VISIBLE_DEVICES` / `?` |
| 拓扑/带宽 CLI | `nvidia-smi` | `mx-smi` | `npu-smi` |
| shm 前缀 | `nccl*` | `nccl*`+`mccl*` | `?` + `hccl*` |

## 实测（粘贴区）

```
# date / image / pod:
# nm excerpts:
```
