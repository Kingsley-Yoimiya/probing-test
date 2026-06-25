# Megatron-LM 真实参数 × Probing 测试矩阵（修订 v2）

## 原则

- **训练**: 真实 `/home/yjr/work/Megatron-LM/pretrain_gpt.py`
- **参数**: Megatron 官方 126M / 345M 规模（非 mock TinyGPT）
- **采集**: 10 种 probing 用法，每种对应不同 Megatron 配置

## Preset 对照

| Preset | Megatron 参数 | 说明 |
|--------|---------------|------|
| gpt126m | 12L/768H/12H seq1024 | CI 常用小规模 |
| gpt345m | 24L/1024H/16H seq1024 | 官方 345M inference 配置 |
| gpt345m_long | 345M + seq2048 | 长序列 |
| gpt345m_gbs | 345M mbs1 gbs16 | 梯度累积 |
| gpt345m_tp2 | 345M TP=2 | 张量并行 |
| gpt126m_pp2 | 12L/512H PP=2 | 流水线并行 |
| gpt126m_2dp | 126M 2×GPU | 数据并行 |

## 10 TC

| TC | Megatron | Probing |
|----|----------|---------|
| TC01 | gpt345m | SQL phase JOIN |
| TC02 | gpt345m | TORCH_PROFILING + torch_trace |
| TC03 | gpt126m | memory + gpu SQL |
| TC04 | gpt345m_long | eval 显存 |
| TC05 | gpt345m_gbs | phase SQL (accum) |
| TC06 | gpt345m_tp2 | collective + phase |
| TC07 | gpt126m_pp2 | backtrace |
| TC08 | gpt126m_2dp | collective |
| TC09 | gpt345m | span logger |
| TC10 | gpt345m | config + 综合 SQL |

## 运行

```bash
bash scripts/run_megatron_matrix.sh
```

依赖: probing venv + Megatron dataset helpers 已编译 + `einops regex pybind11` 等
