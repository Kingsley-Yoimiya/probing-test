# Flight Recorder（Ascend）

pipeline C5 通过 `config_denv_ascend.sh` 设置：

- `TORCH_NCCL_TRACE_BUFFER_SIZE` / `TORCH_NCCL_DUMP_ON_TIMEOUT`（兼容探测）  
- `TORCH_HCCL_TRACE_BUFFER_SIZE`（若栈识别）

接入后验证：

1. 环境变量是否被 Ascend PyTorch 读取  
2. 超时或人工 dump 是否落盘  
3. 解析脚本能否对齐 MetaX 战役的「有/无可用 trace」结论
