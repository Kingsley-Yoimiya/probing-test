# Baseline 昇腾适配：难度与方法

原则与沐曦战役相同：**测的是「那套检测规则/逻辑」能否在新栈上工作**，不是重写论文指标。  
红线 5：未穷尽 → **PENDING**，不写 ENV-BLOCKED。

## 总览

| 工具 | 配置 | CUDA→MetaX 经验 | 昇腾预期难度 | 方法 |
|------|------|-----------------|--------------|------|
| **Probing (C2)** | SQL + host 旁路 | mx-smi / PSI；torch profiling 易炸 | 中 | 换 `npu-smi` 旁路；先关 torch profiling smoke |
| **Greyhound (C3)** | LD_PRELOAD + Redis | `libmcclprobe.so`；常缺 Redis→PENDING | **高** | 对 HCCL 做 interposer；先 stub 加载，再接完整 ACF |
| **XPUTimer (C4)** | LD_PRELOAD hook | **必须 hook `mc*`/`mccl*`**；Bazel 放弃→g++ 直编；64 卡曾挂 | **高** | 复制 `build_metax_hook.sh` 模式：`build_ascend_hook.sh` + 实测符号 |
| **Flight Recorder (C5)** | env 环形缓冲 | `TORCH_NCCL_*` 在 MCCL 上语义含糊 | 中低 | 查 Ascend PyTorch 是否认 `TORCH_HCCL_*`；dump 解析兼容性 |
| **Dynolog** | 不进默认 C0–C5 | oracle 短窗 | 中 | MSProf / 厂商 profiler；触发协议仍标 oracle |

## 1. XPUTimer（优先啃，因为「规则兼容」最直接）

MetaX 路径（真相源）：

`~/Codespace/probing-baselines/xputimer-metax/xpu_timer/metax_probe/`

要点：

1. `nm -D` 确认 torch/HCCL **未定义符号**列表。  
2. hook 导出 **实际符号名**，dlsym 到 next。  
3. 复用 hang/slow 判定与 dump（prom/jsonl），少改阈值语义。  
4. 单卡 selftest → 2-rank desync → 再上 64 卡（MetaX formal 曾在 64 卡挂死）。

昇腾目录占位：`xputimer/build_ascend_hook.sh`、`xputimer/README.md`。  
设备代码到齐后：把 CUDA/MetaX hook 源拷入并改符号表。

## 2. Greyhound

- 目标：HCCL 路径上的 straggler/ACF 类探测（对标 NCCL/MCCL probe）。  
- 先：`greyhound/install_stub.sh` 保证 LD_PRELOAD 不炸训练。  
- 再：接 Redis/完整逻辑；缺依赖记 PENDING。  
- 输出 schema 尽量与 MetaX 战役可比（代价表五项）。

## 3. Flight Recorder

- 目标：集合通信 trace 环形缓冲，超时 dump。  
- 兼容性测：同一注入窗下，FR 是否给出**可用** timeline（即使 API 名不同）。  
- 若仅 env 生效但内容空 → PENDING + 记录，不伪造成 D4。

## 4. 检测规则兼容性（你要的「差不多的方法」）

见 `COMPAT_MATRIX.md`：用**同一 case 剂量语义**（Loud 阈值、窗 [100,300]、victim L7）在昇腾复跑，对比：

- accept_loud（C1/C0）是否同方向；  
- D1–D3 离线规则是否仍成立；  
- C3/C4 是否能产出与 MetaX 同级的「慢/挂」信号（允许实现不同）。

## 5. 明确不做的事

- 不把沐曦 `libmcclprobe.so` / `libxpu_timer_metax.so` 直接拷到昇腾当「适配完成」。  
- 不在共享 `score_dlevel_*.py` 里写死昇腾窗/rank 答案。  
- 不为昇腾新建第二套 ledger 仓；只在 ledger 加 `platform=ascend` 行。
