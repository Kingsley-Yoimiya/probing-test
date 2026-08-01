# Greyhound MetaX（collect-min）

目标产物：`libmcclprobe.so`。

## 为何不能直接用 AE Docker

- 战役 pod **无 docker**；且 `tianyuanwu/greyhound:ae` 是 CUDA+NCCL。
- MetaX torch 绑定 **`mccl*`**（`libtorch_cuda.so` 对 `mcclAllReduce` 为 `U`），`libmccl.so` **无 `nccl*` 导出** → 原版 `libncclprobe.so` 挂不上。

## 阶段

1. **collect-min**：导出 C 链接 `mccl*`，JSONL dump（本目录）
2. **Redis 侧车**：apt/`redis-server`（控制面；collect-min 不依赖）
3. **真 AE probe**：需 MACA 重编 detector / 兼容层（后续）

```bash
bash install_collect_min.sh /workspace/probe-bundle/greyhound
export GREYHOUND_DUMP=/tmp/mcclprobe.collect.jsonl GREYHOUND_DEBUG=1
eval "$(bash preload_snippet.sh)"
torchrun --nproc_per_node=2 smoke_allreduce.py --iters 20
```
