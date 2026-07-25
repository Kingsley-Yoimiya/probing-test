# platform/ascend — 昇腾 Fail-Slow 平台差分

> 共享编排仍在 `scripts/fail-slow/{run_case_abc,run_case_pipeline_v4}.sh`。  
> 本目录只放 **Ascend/HCCL/NPU** 专用：baseline 构建、env、采集旁路、镜像片段。  
> 结果落盘：**禁止**写沐曦结果树。本机默认用 `probing-huawei/results/ascend-ais/<run_id>/`
>（`source probing-huawei/scripts/fail-slow/env.sh` 的 `LOCAL_RESULT_ROOT_BASE`）；**不依赖 myportal**。

## 状态

| 项 | 状态 |
|----|------|
| 集群访问 / 设备代码 | **待用户提供** |
| 符号表（`nm -D`） | 待填 `SYMBOL_MAP.md` |
| Smoke（1×8 / 2×8） | 未开 |
| Baseline 真 .so | 未编 |

## 目录

| 路径 | 用途 |
|------|------|
| `env.defaults` | `ASCEND_*` / `HCCL_*` / 可见设备 |
| `config_denv_ascend.sh` | 供 pipeline `source`：C3–C5 preload / FR env |
| `SYMBOL_MAP.md` | CUDA→MetaX→Ascend 符号对照（接入后填实测） |
| `BASELINE_PORTING.md` | Greyhound / XPUTimer / FR / Dynolog 适配原则与难度 |
| `COMPAT_MATRIX.md` | 检测规则兼容性测试清单 |
| `greyhound/` | → `libhcclprobe.so`（名待定） |
| `xputimer/` | → `libxpu_timer_ascend.so` + `build_ascend_hook.sh` |
| `flight_recorder/` | HCCL/Torch FR env |
| `dynolog/` | oracle 协议（默认不进 C0–C5） |
| `host_bypass/` | `npu-smi` / PSI 旁路（对标 dump 里 mx-smi） |
| `image/` | 底包 Dockerfile 片段 + install |

## 与沐曦的平行原则

1. **检测逻辑尽量同构**（hang/slow 阈值、rank 对齐、代价五项）——换的是 hook 符号与旁路命令。  
2. MetaX 教训：**不要假设** CCL 导出 `nccl*` 同名；昇腾上先 `nm -D libhccl.so` / `libtorch*.so`。  
3. XPUTimer：优先 **plain g++ 自包含 hook**（对标 `probing-baselines/xputimer-metax/.../build_metax_hook.sh`），勿一上来死磕完整 Bazel。  
4. 红线 5：未穷尽前记 **PENDING**，不写 ENV-BLOCKED。  
5. 多 Agent：大改放本目录或 `results/ascend-ais/<run>/campaign/`，少抢共享 pipeline。

## 开跑顺序（接入后）

Smoke / 身份：见 `probing-huawei/docs/fail-slow/{SHARE,IDENTITY}.md`。
