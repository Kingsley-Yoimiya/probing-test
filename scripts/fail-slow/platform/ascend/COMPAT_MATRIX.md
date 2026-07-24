# 检测规则兼容性矩阵（Ascend vs MetaX）

> 目标：方法尽量同构，验证「规则/逻辑」是否可迁移，而不是追求 bit-identical 数值。

## 固定控变（昇腾 smoke / Loud 对齐沐曦）

| 项 | 值 |
|----|-----|
| 模型 | GPT-2 124M host_bound（或文档注明的 gpu_bound 例外） |
| ITERS / warmup | 500 / 50 |
| measure 窗 | step [100, 300] |
| victim | node0 local_rank=7 |
| Loud 阈 | 按 case（多为 C1/C0≥1.3） |
| 结果根 | `results/ascend-ais/<run_id>/` |

## 矩阵（跑完打勾）

| 检查项 | MetaX 参考 | Ascend smoke | Ascend Loud | 备注 |
|--------|------------|--------------|-------------|------|
| C0 写出 rank jsonl | ✓ h3c | ☐ | ☐ | |
| C1 注入咬合（accept） | ✓ 多 case | ☐ | ☐ | 剂量可能要重标定 |
| C2 Probing SQL dump | ✓ 部分 | ☐ | ☐ | |
| host 旁路（smi/PSI） | mx-smi | ☐ npu-smi | ☐ | |
| C3 Greyhound 加载 | stub/真 | ☐ | ☐ | |
| C3 检出信号非空 | 少 | ☐ | ☐ | |
| C4 XPUTimer 加载 | ✓/.so | ☐ | ☐ | |
| C4 hang/slow 报告 | 单机有/64 卡挂过 | ☐ | ☐ | |
| C5 FR dump 可读 | 弱 | ☐ | ☐ | |
| D1 C1/C0 同方向 | ✓ | ☐ | ☐ | |
| D2 窗 IoU 规则可跑 | ✓ | ☐ | ☐ | |
| D3 victim/host 定位 | ✓/overlay | ☐ | ☐ | |
| 代价五项可填 | 部分 | ☐ | ☐ | |

## 首轮建议 case（注入已熟 → 先测兼容）

1. **host 压力类**（对标 P3-EXT-C）：`stress-ng` / 等价 → 看 PSI + step_ms。  
2. **inline stall 类**（对标 P3-SW-B / P1-SW-A）：进程内 stall → accept 闸门。  
3. **再**上 C3/C4 真 hook（符号表填完后）。

## 失败分类（写 ledger 时用）

| 标签 | 含义 |
|------|------|
| `DOSE_RECAL` | 规则通，剂量要重调 |
| `HOOK_SYMBOL` | 符号/ABI 不对 |
| `STACK_CRASH` | LD_PRELOAD 或 profiling 炸 |
| `RULE_GAP` | 规则在昇腾上语义不成立（少见，需论证） |
| `PENDING` | 依赖未齐（Redis、镜像、权限） |
