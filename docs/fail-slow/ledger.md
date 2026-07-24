# Probing Fail-Slow 实验台账

> **这份文档是什么**：实验的**现状台账**——现在用什么模型、开了什么、哪个集群怎么配、跑了哪些 case。**由执行的 Agent 边跑边维护。**
>
> **和规则的分工**：方法论（红线、控变原则、三阶段）在 [`rules.md`](rules.md)，那份很少动。这份是会变的现状，随实验推进不断更新。
>
> **别人来问，翻这里**：模型是什么（→ §2.1）、某功能开没开（→ §2.1 / §1.2）、base 怎么配（→ §1）、我们开了什么参数（→ §2.1）、跑了哪些 case 结果如何（→ §3）。
>
> **真值以脚本为准**：下面的值来自 `scripts/fail-slow/` 的实际脚本与 `image/` 配方，不是从别处抄的。脚本改了，这里跟着改；发现和 [`sop.md`](sop.md) 不一致，**以脚本+本台账为准**并在此标注。

---

## 维护纪律（改这份文档前先读）

- **谁维护**：执行实验的 Agent。每跑完一个 case、每改一次配置、每换一次环境，回来更新。
- **⚠️ 改「§2.1 全局固定」区的任何一格前先停。** 那些是控制变量，一改会让**之前所有 run 变得不可比**。真要改：要么准备好全部重跑，要么在该行记清「从哪个日期起改、为什么改、旧数据是否作废」。（对应 `rules.md` 控变原则）
- **改「§2.2 自变量」区不需要停**——那些本来就该随 run 变化。
- **case 不再有预写文档**（2026-07-24 删除 `cases/`，原因见下）：故障定义走 `OUTLINE`（论文侧 27-case 真相源），注入配方走 `dose_recipes.yaml`，检测方案在**探索阶段发现→冻结成脚本**（`rules.md` 三阶段），跑完结果记进本台账 §3。本台账只放**速览**。
  > 为什么删 `cases/`：旧 case 文档预写了检测 SQL（还写死了注入窗），与 `rules.md` 红线 2（检测不准出现答案）和三阶段（检测要探索发现、不许照本宣科）直接冲突；其余内容（定义/配方/结果）与 outline、dose_recipes、本台账重复。

---

# 一、环境（env）

> 集群、镜像、门禁——正式 run 前，本章的「门禁清单」必须全绿（`rules.md` 第四节契约）。

## 1.1 集群与身份

| 项 | 值 | 备注 |
|---|---|---|
| 主集群（先） | mohe-241 | 128 卡面；空闲常 <128 |
| 备集群（后） | h3c-test | 大池；128=16×8 |
| 身份 | **仅 `yinjinrun.p`** | kube `~/.kube/config-vc-c550-mohe-241.yaml` |
| 硬件 | MetaX C550 | — |
| 当前实验 pod | `yjr-fs-h14410` + `yjr-fs-h14411` | 2 节点 × 8 卡 |
| 代理 | Clash `:7897` | `NO_PROXY=127.0.0.1,localhost`；**unset** `ALL_PROXY`（Clash 干扰 kubectl / probing socket） |

## 1.2 镜像与 Probing 版本

| 项 | 值 |
|---|---|
| 底包 | `registry2.d.pjlab.org.cn/ccr-deeplink/megatron-lm:0.12.0-maca.ai3.3.0.11-torch2.6-py312-ubuntu22.04-amd64-driver` |
| 实验镜像配方 | `scripts/fail-slow/image/{Dockerfile,env.defaults,build.sh}` |
| **Probing 包** | **Probing_plus 0.2.5**（features=`gpu,gpu-cuda,kmsg`，含 `mx-smi`）；MD5 `fe3b76db996fece61033c3c12480f2e9` |
| ❌ 勿用 | PyPI `0.2.4`（**无** gpu/cpu 扩展） |
| host 注入工具 | `stress-ng` / `fio`（P3-EXT 用；镜像内已装） |
| 现网灌装 | `install_env_to_pods.sh` → pod 已装 |
| 推镜像 | ais 跳板对 `ccr-deeplink` **unauthorized**；需在有推送权限节点 `build.sh` 或集群内 Kaniko |

**Probing 接入相关环境变量**（`image/env.defaults` 默认）：

| 变量 | 默认 | 含义 |
|---|---|---|
| `PROBING` | `2` | current+children，适用 torchrun 分布式（对主进程及所有 per-GPU worker 生效） |
| `PROBING_GPU` | `on` | 开 GPU 采集 |
| `PROBING_GPU_SAMPLE_MS` | `1000` | GPU 采样间隔 |
| `PROBING_TORCH_PROFILING` | **不设默认**（见门禁 #3） | 开 torch trace；MetaX 上 import 期 SET 会 SIGSEGV，要用得显式 `on:rate=1.0` |
| `DUMP_PROBING_SQL` | `1` | C2 注入窗采 SQL + host PSI |
| `SIDECAR_WARMUP` | `8` | 注入 sidecar 预热秒数 |

## 1.3 门禁清单（正式 run 前逐条过，全绿才开跑）

| # | 检查项 | 为什么（踩过的坑） |
|---|---|---|
| 1 | `/dev/shm` **≥ 8Gi**（目标扩到 32G） | 默认 Docker/k8s 常 **64Mi**，8 卡 MCCL 打满 → **SIGBUS**。开训前 `PODS=… KUBECONFIG=… bash scripts/fail-slow/ensure_shm.sh`；新建 pod 挂 `emptyDir medium=Memory sizeLimit=32Gi`（见 `image/pod-shm-snippet.yaml`）。**⚠️ 勿在训练中途 remount**（已 mmap 进程会 SIGBUS/消失） |
| 2 | 健康线 / 无工具线 **`unset PROBING`**（或 `PROBING=0`） | 残留 PROBING 会让基线挂 crash handler / SIGABRT，污染基线 |
| 3 | **禁止**默认 `PROBING_TORCH_PROFILING=on` | MetaX 上 import 期易 **SIGSEGV**；要用得显式 `rate=1.0` |
| 4 | 挂 Probing 线确认 `site_hook` 生效（`PROBING=2` + 入口 `run_site_hook()`） | MetaX `--target=pydeps` 时 `.pth` 不自动加载 |
| 5 | **禁止**把 MACA cu-bridge `libcuda` 塞进 `LD_LIBRARY_PATH` | cudarc panic |
| 6 | Probing attach PID 用 **victim local_rank 的 worker 进程** | torchrun 父进程无 probing socket；裸 `pgrep -n` 会打错进程 |
| 7 | `NO_PROXY=127.0.0.1,localhost`；`unset ALL_PROXY` | Clash 代理干扰 kubectl / probing socket |
| 8 | 本机后台跑用 IDE 持久 background shell | macOS **无 `setsid`**，普通 `nohup &` 易被会话收掉 |
| 9 | **每个 config 发射前**确认目标 pod **无外来 `torchrun` / 其它 `run_id` 占 master_port** | 复现时 C2 曾被旧 `P1-EXT-A` 占端口打断；清障后再发 |

## 1.4 平台 know-how（探索 verdad；勿把答案写进检测 SQL）

> 剂量数值仍以 `dose_recipes.yaml` / 脚本为准。这里只记「不读 runbook 就会假阴性」的平台事实。

| 场景 | 要点 |
|---|---|
| **Host CPU（P3-EXT-A）** | `stress-ng` CPU 线程要相对核数**过载**（经验：约 **≥2×nproc** 才咬得动；128 核机上只开 16 线程 → 假阴性）。训练须 `host_bound`。 |
| **P3-EXT D4 信号** | MetaX 上 `cpu.tasks` **只见本进程**，见不到 host `stress-ng` → D4 走同窗 PSI：`host_pressure.json` / `host_psi_cpu`（经 `dump_probing_sql.sh`），**不是**裸 `pgrep`。 |
| **P1-EXT D4 信号** | MetaX 常无 `gpu.utilization` / `process.gpu_users` → 同窗 `mx-smi`（`host_mx_smi_gpu_util` / `host_mx_smi_hbm_bw`）。**勿把 PSI 误套到 P1。** |
| **D3（Host 类）** | 按 **host** 命中即可（见 `rules.md` D3 口径）；离线 `max_data_ms` 指到邻 rank 仍可 same_host 记 D3。 |

## 1.5 结果落盘

| 集群 | 本机备份（主） | 远端（若挂上 AFS） |
|---|---|---|
| mohe-241 | myportal `results/muxi-mohe/<run_id>/` | `/afs-a3-weight-share/yinjinrun.p/results/muxi-mohe/<run_id>/` |
| h3c-test | myportal `results/muxi-h3c/<run_id>/` | 同上前缀 |

- `run_id` 带时间戳，如 `20260724_090823-p3-live-d4e`。
- **AFS 不可靠**（raw Pod 挂 weight-share 长 Pending）：默认 pod 本地落盘 → **立刻回拉**本机 `results/`。不依赖 AFS。
- 每 run 至少留：`manifest.yaml`、`training/*.jsonl`、`injection/ground_truth.yaml`+log、`probing/` 检测输出、`verdict/` 判分、`system/env_snapshot.yaml`。
- 默认实验规模（本台账现状）：**2×8=16 rank**（`yjr-fs-h14410/11`）；不是起满 mohe 128 卡。Eval-D 扫规模另开。

---

# 二、控制变量（具体设置）

## 2.1 全局固定 · 控制变量 ⚠️

> **这一区是地基。改任何一格 = 之前所有 run 不可比。** 值以 `train_bench_probe.py` 实际默认为准。

| 参数 | 值 | 来源 / 备注 |
|---|---|---|
| 模型 | **GPT-2 124M**（hidden=768, layers=12, ffn=3072, vocab=50257, 词表/输出层权重共享） | `--model gpt2`；`tiny` 仅紧急管线回退 |
| batch (per GPU) | **8** | `--batch` |
| sequence length | **1024** | `--seq` |
| **dtype** | **bfloat16** | 脚本 `model.to(dtype=torch.bfloat16)`。**⚠️ 注意：`sop.md` §2.1 写的是 fp16，与脚本不符，以脚本 bf16 为准** |
| seed | **42** | `--seed`；正式扫 42/43/44 |
| 并行 | DDP（小规模）/ FSDP（≥64 卡） | — |
| optimizer | AdamW | — |
| 总步数 iters | **500** | `--iters` |
| warmup | **50** | `--warmup`；前 50 步不计任何判分 |
| DataLoader | **必开**，`num_workers=2`, `pin_memory=True`, `prefetch_factor=2`, `persistent_workers=True` | host 类 case 的前提；`--dl-workers` |
| Checkpoint | **必开**，每 **100** 步 | `--ckpt-every`；Eval-A1 重启代价 + 9B 磁盘 IO 前提 |
| flush | 每 5 步 flush+fsync | `--flush-every` |
| 日志 | 每步写 step_time/loss/各 phase 耗时到 jsonl | 离线验证用 |

## 2.2 每 run 变化 · 自变量

> 这些本来就该随 run 变，正常记录，不用停。

| 自变量 | 取值 |
|---|---|
| case_id | 27 格之一（P1/P2/P3 × HW/SW/EXT × A/B/C） |
| 剂量档 | **Loud** / **Quiet** / **Masked**（每 case 三档具体值见 §3 或 `dose_recipes.yaml`） |
| 检测工具 | 无 / Probing / Greyhound / XPUTimer / Dynolog / Flight Recorder / StragglerAnalysis |
| 规模 | 8 / 16 / 32 / 64 / 128 / … 卡（Eval-D 扫规模时变） |

**平行 run 命名对照**（脚本/结果里到处是 `C0/C1/C2`，与 `rules.md` 平行 run 概念对齐）：

| 脚本标签 | 注入 | 工具 | 对应 `rules.md` / 代价指标 |
|---|---|---|---|
| **C0** | 无 | 无 | 健康基线线（不挂工具健康线） |
| **C1** | 有 | 无 | 纯注入线（Loud 验收 C1/C0 比值即出自此） |
| **C2** | 有 | Probing | 挂工具线；C2/C0 → 常驻开销，C2/C1 → 注入期扰动 |
| D-run / E-run | 有 | Greyhound / XPUTimer | 对手线，同 C2 位置换工具 |

## 2.3 注入时序（默认，全局共用）

| 参数 | 值 | 备注 |
|---|---|---|
| warmup | 前 50 步 | 不判分 |
| 健康基线段 | step 50 ~ N_inject-1 | 建“正常”统计基准 |
| N_inject | **150**（= warmup 50 + 窗起 100） | 保证 100 步干净基线 |
| 注入持续 | **200 步**（窗 [100,300] 内部计，即全局 step 150–350） | `dose_recipes.yaml` `inject_measure_window: [100,300]` |
| victim | `sidecar_local_rank=7` | 训练 local_rank=7 同卡 |
| 特殊时序 | 间歇类 on-off 交替 / 渐进类线性递增 | 各 case 文档 §1.4 |

---

# 三、测试用例（cases）

## 3.1 已跑 case 速览

> 剂量配方真相源：`scripts/fail-slow/dose_recipes.yaml`。故障定义见 `OUTLINE`；检测方案见探索时冻结的脚本。

| Case | 名称 | 注入 kind | 模式 | Loud 实测 C1/C0 | 到达 D | 关键 run_id / 备注 |
|---|---|---|---|---|---|---|
| **P3-EXT-A** | host CPU 争用 | `stress_cpu` | host_bound | **~2.97**（复现 2.19） | **D4** ✅ | 锚点 `20260724_090823-p3-live-d4e`；**skill 复现** `20260724_154230-p3exta-repro`（同 D4 / `host_psi_cpu`） |
| **P3-SW-A** | 对象泄漏→GC | `8a`（`INLINE_INJECT`） | host_bound | **2.17** | **D4** ✅ | `20260724_115002-p3swa-loud`；证据 `cpu.utilization_rss`；bite `114257` |
| **P1-EXT-A** | 同卡算力抢占 | `cube` | gpu_bound | **3.78** | **D4** ✅ | `20260724_112745-p1exta-loud`；证据 `host_mx_smi_gpu_util`（mx-smi 旁路） |
| **P1-EXT-B** | 同卡 HBM 带宽 | **inline_hbm**（外挂失效） | gpu_bound | **1.74** | **D4** ✅ | `20260724_124947-p1extb-loud`；`512MB×48`；证据 `host_mx_smi_hbm_bw` |
| **P3-EXT-B** | host IO 争用 | `stress_io` | host_bound | — | — | `injection_ineffective`，**不进分母**；`104828-p3extb-bite5` |

**冻结归档（含 raw）**：[`reports/fail-slow-mohe/20260724-first-tier-loud-d4/`](../../reports/fail-slow-mohe/20260724-first-tier-loud-d4/CAMPAIGN.md)

## 3.2 baseline（对手工具）状态

> **本轮目标：把下面的 baseline 真跑出来，别轻易记 `ENV-BLOCKED`**（`rules.md` 红线 5）。每个都有沐曦接入路径，先当它能跑、去趟通。接入命令与检测方式详见 `BASELINE-SETUP-PLAYBOOK.md`（paper 侧）。
> baseline 测试方式（公平 + 代价五项）见 `rules.md` §三·五。

| 工具 | 角色 | 接入方式 | 检测方式 | 预期天花板 | 当前状态 |
|---|---|---|---|---|---|
| **Greyhound** | 主对手（D-run，在线） | LD_PRELOAD 挂 MCCL + Redis；docker `tianyuanwu/greyhound:ae` | ACF 估周期 → Rbeast 变点 → GEMM/P2P 微基准主动定位 | **D3**（无 PID/温频，不分 HW/SW/EXT） | **待接入**（NCCL/Redis/Docker 依赖需在 MetaX 趟通；非最终 blocked） |
| **XPUTimer** | 次对手（E-run，在线） | LD_PRELOAD + MACA 兼容层；Bazel 构建，NCCL≤2.21.5 | 采关键算子/通信事件 → Prometheus 五指标 + hang | **D0–D1**（只采信号不判，自动 RCA 未开源） | **待接入** |
| **Dynolog + Profiler + HTA** | 新 baseline（trade-off「极深极贵」极点，本轮要真跑） | Dynolog daemon + `KINETO_USE_DAEMON=1`；HTA 离线解析 | 全栈 kernel 级 profiling；HTA 事后分解 | D3–D4（事后、极贵，常驻 +20~44% 且 OOM） | **待接入 + 触发协议待定**（见下注） |
| **PyTorch Flight Recorder** | 新 baseline（trade-off「极轻极窄」极点，本轮要真跑） | 环境变量启用环形缓冲（如 `TORCH_NCCL_TRACE_BUFFER_SIZE`）；`fr_trace` 解析 | 只记 collective 元数据，做 hang/desync | **D1**（P2 in-scope；P1 芯片 / P3 主机结构上看不到） | **待接入 + 触发协议待定** |
| StragglerAnalysis | 离线可选补充 | 离线喂 B-run trace 转成 parquet | 依赖图仿真理想 timeline → slowdown 分解 | D2（无 PID/温频/编译事件） | 转换脚本待写；标“离线”，不并入在线检出率 |

> **两个新 baseline 与 outline 的关系**：Dynolog / Flight Recorder 在 `OUTLINE-v5.md` 里目前是「引用不跑」的 trade-off 极点；本轮决定**升级为真跑**（2026-07-24 拍板），outline 正文待跑出数后回改。它俩的 preflight / 触发策略 / verdict schema 依据 `SOP-COMPATIBILITY-DYNOLOG-FLIGHT-RECORDER.md`。
>
> **触发协议注意**（`rules.md` §三·五 B）：这两个是**按需触发**型，不是常驻检测。若用「已知故障时刻」触发采集 = **oracle 触发**，只能比「采到后诊断多深 + 代价」，**不能**算它的检出率 / trigger 延迟。用前必须在此标清是 oracle 触发还是自主检出。

## 3.2b baseline 代价记录（五项，每个 baseline + Probing 都填）

> 指标定义见 `rules.md` §三·五 B。同 seed、对齐窗口、看中位数（控变 ①②）。

| 工具 | 1 常驻开销% | 2 注入期扰动 | 3 trigger 延迟 | 4 分析延迟 | 5 存储/内存 |
|---|---|---|---|---|---|
| Probing | 待填 | 待填 | 待填（SET 热更 <200ms） | 待填 | `PROBING_COLD_MAX_TOTAL_MB` |
| Greyhound | 自报 ~0.39% | 待填 | 论文 ~10.56s | profiling 20s 窗 | 待填 |
| XPUTimer | 自报 ~0.43% | 待填 | hang 超时默认 300s | 待填 | ~1.5MB/GPU/step |
| Dynolog+HTA | 常驻 +20~44%（会 OOM） | 待填 | oracle 触发（不算） | HTA 离线，待填 | 短窗 trace，待填 |
| Flight Recorder | 待填（环形缓冲，轻） | 待填 | oracle 触发（不算） | `fr_trace`，待填 | 环形缓冲字节数 |

> “自报”= 来自该工具论文/文档，**须在本环境实测复核**后替换。

## 3.3 判分证据口径（当前实测结论）

- **D0–D3**：训练埋点（C1/C0、`data_ms`、窗 IoU、同机 victim 命中）即可支撑。
- **D4**：需 Probing SQL 或同窗旁路（PSI / mx-smi / 已有表 RSS）。
  - P3-EXT：`cpu.tasks` 只见本进程 → 允许 `host_psi_cpu` / `host_psi_io`。
  - P3-SW：允许 `cpu.utilization` 进程 `rss_kb` 超阈（`cpu.utilization_rss`）。
  - P1-EXT：MetaX 缺 `gpu.utilization` / `process.gpu_users` → 允许同窗 `mx-smi`（`host_gpu.json`：`host_mx_smi_gpu_util` / `host_mx_smi_hbm_bw`）。**勿把 PSI 误套到 P1**。
- **永不**用 `injection.log` / 裸 `pgrep` 单独升 D4（`rules.md` 红线 4）。

## 3.4 SQL 表可用性（MetaX + Probing_plus 0.2.5，2026-07-23 复测）

| 表 | 状态 |
|---|---|
| `cpu.utilization` | ✅ |
| `gpu.devices` | ✅（可空） |
| `python.torch_trace` | ✅（需 `PROBING_TORCH_PROFILING=on`） |
| `python.comm_collective` | ✅ |
| `gpu.utilization` | ⚠️ 采样未自动起表（`SET probing.gpu.sample_interval` 亦失败，待查 backend） |
| `process.gpu_users` | ❌ 主线无表 |
| 跨 rank 联邦查询 | ⚠️ **探索阶段实测确认**：`sop.md` §3.8 称“无内置联邦”，兼容性评审称现已支持 `global.*`——不预设结论，按 `rules.md` 红线 5 去趟通：真跑一次确认当前 wheel 支持到什么程度，结果回填此处 |

---

## 附：本台账与其他文档的关系

| 内容 | 落点 |
|---|---|
| 方法论（红线/控变/三阶段） | [`rules.md`](rules.md) |
| 完整长规程 | [`sop.md`](sop.md) |
| case 故障定义 | `OUTLINE`（论文侧 27-case 真相源） |
| 注入配方 | `scripts/fail-slow/dose_recipes.yaml` |
| 检测方案 | 探索阶段发现→冻结进 `scripts/fail-slow/`（不预写） |
| 剂量配方真相源 | `scripts/fail-slow/dose_recipes.yaml` |
| 历史拍板决策 | [`decisions.md`](decisions.md) |
| P3-EXT-A 首个 D4 实录 | [`p3-d4-first-case-runbook.md`](p3-d4-first-case-runbook.md) |
