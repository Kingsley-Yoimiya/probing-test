# Greyhound Ascend（占位）

目标产物：`libhcclprobe.so`（名称可随实测调整）。

阶段：

1. stub `.so`：constructor-only，验证 LD_PRELOAD 不破坏 HCCL 训练  
2. 真 probe：对标 MetaX `libmcclprobe` / CUDA `libncclprobe`  
3. Redis / ACF 依赖齐备前记 PENDING

安装脚本占位：`install_stub.sh`。
