# Probing Fail-Slow 实验台账

> **这份文档是什么**：实验的**现状台账**——现在用什么模型、开了什么、哪个集群怎么配、跑了哪些 case。**由执行的 Agent 边跑边维护。**
>
> **和规则的分工**：方法论（红线、控变原则、三阶段）在 [`rules.md`](rules.md)，那份很少动。这份是会变的现状，随实验推进不断更新。
>
> **别人来问，翻这里**：模型是什么（→ §2.1）、某功能开没开（→ §2.1 / §1.2）、base 怎么配（→ §1）、我们开了什么参数（→ §2.1）、跑了哪些 case 结果如何（→ §3）。
>
> **真值以脚本为准**：下面的值来自 `scripts/fail-slow/` 的实际脚本与 `image/` 配方，不是从别处抄的。脚本改了，这里跟着改。方法论冲突时以 [`rules.md`](rules.md) 为准。

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

> 剂量数值仍以 `dose_recipes.yaml` / 脚本为准。这里只记「不读本台账就会假阴性」的平台事实。

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
| **dtype** | **bfloat16** | 脚本 `model.to(dtype=torch.bfloat16)` |
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
| 特殊时序 | 间歇类 on-off 交替 / 渐进类线性递增 | 见 OUTLINE / `dose_recipes.yaml` 注释 |

---

# 三、测试用例（cases）

## 3.1 已跑 case 速览

> 剂量配方真相源：`scripts/fail-slow/dose_recipes.yaml`。故障定义见 `OUTLINE`；检测方案见探索时冻结的脚本。

| Case | 名称 | 注入 kind | 模式 | Loud 实测 C1/C0 | 到达 D | 关键 run_id / 备注 |
|---|---|---|---|---|---|---|
| **P3-EXT-A** | host CPU 争用 | `stress_cpu` | host_bound | **~2.97**（复现 2.19） | **D4** ✅ | 锚点 `20260724_090823-p3-live-d4e`；**skill 复现** `20260724_154230-p3exta-repro`（同 D4 / `host_psi_cpu`） |
| **P3-EXT-A** | host CPU 争用 | `stress_cpu` | host_bound | **2.51** | **D4** ✅ | **64 卡** mohe-241；score `20260725_001503-p3exta-score`（bite `234815` + C2 `000520`）；证据 `host_psi_cpu` rate≈977679；对象 same_host（reported rank_1 / GT L7）；platform=metax |
| **P3-SW-A** | 对象泄漏→GC | `8a`（`INLINE_INJECT`） | host_bound | **2.17** | **D4** ✅ | `20260724_115002-p3swa-loud`；证据 `cpu.utilization_rss`；bite `114257` |
| **P3-SW-A** | 对象泄漏→GC | `8a`（`INLINE_INJECT`） | host_bound | **2.72** | **D4** ✅ | **64 卡** mohe-241；score `20260725_010339-p3swa-score`（bite `002320` + C2 `005732`）；证据 `cpu.utilization_rss` rise 482616→544708（+62092）；对象 `rank_7`；platform=metax |
| **P3-SW-B** | dataloader worker 泄漏 | `8b`（`INLINE_INJECT`） | host_bound | **2.74** | **D4** ✅ | **64 卡** mohe-241；score `20260725_020430-p3swb-score`（bite `014732` + C2 `015742`）；证据 `cpu.utilization_rss` rise 483228→545200（+61972）；对象 `rank_7`；platform=metax |
| **P3-SW-C** | 监控程序自身泄漏 | `8c`（sidecar **8c_loud3**） | host_bound | **2.85** | **D4** ✅ | **64 卡** mohe-241；score `20260725_043056-p3swc-score`（bite `040120` + C2 `041824`）；证据 `host_psi_cpu`（8c overlay）rate≈677097；rss rise≈+35k 弱（sidecar 不在 attach PID）；对象 same_host（reported rank_2 / GT L7）；格 **P3-SW**；platform=metax |
| **P1-EXT-A** | 同卡算力抢占 | `cube` | gpu_bound | **3.78** | **D4** ✅ | `20260724_112745-p1exta-loud`；证据 `host_mx_smi_gpu_util`（mx-smi 旁路）；**16 卡** mohe |
| **P1-EXT-A** | 同卡算力抢占 | `cube` | gpu_bound | **3.10** | **D4** ✅ | **64 卡** mohe-241；score `20260724_231300-p1exta-score`（bite `225308` + C2 `230604`）；证据 `host_mx_smi_gpu_util` util=98%；对象 `rank_7`；platform=metax |
| **P1-EXT-B** | 同卡 HBM 带宽 | **inline_hbm**（外挂失效） | gpu_bound | **1.74** | **D4** ✅ | `20260724_124947-p1extb-loud`；`512MB×48`；证据 `host_mx_smi_hbm_bw`；**16 卡** mohe |
| **P1-EXT-B** | 同卡 HBM 带宽 | **inline_hbm**（外挂失效） | gpu_bound | **1.69** | **D4** ✅ | **64 卡** mohe-241；score `20260724_233623-p1extb-score`（bite `231923` + C2 `233039`）；证据 `host_mx_smi_hbm_bw` hbm_bw≈900963；对象 `rank_7`；D3=`min_compute_ms`；platform=metax |
| **P3-EXT-C** | host 内存带宽/NUMA | `stress_vm` | host_bound | **3.43** | **D4** ✅ | **64 卡** mohe-241；score `20260725_013847-p3extc-score`（bite `011135` + C2 `012907`）；证据 `host_psi_cpu`（via_vm overlay）rate=548978；**memory PSI=0 未 hit**；对象 `rank_7`；platform=metax；勿裸 pgrep |
| **P3-EXT-B** | host IO 争用 | `stress_io` | host_bound | — | — | `injection_ineffective`，**不进分母**；`104828-p3extb-bite5` |
| **P1-SW-A** | 显存碎片化→骤停 | `2a`（`INLINE_INJECT`） | gpu_bound | **3.40** | **D3** ⚠ | **64 卡** mohe-241；score `20260725_050400-p1swa-score`（bite `043833` + C2 `045330`）；离线 D3=`min_compute_ms`→rank_7；**D4 不足**（gap C1−C0≈0；`host_mx_smi_unused`；缺 gpu 表）；旁证 frag_stall≈250；**DONE_PARTIAL**；platform=metax；勿 ENV-BLOCKED |
| **P1-SW-B** | 罕见 shape 重编译 | `2b`（`INLINE_INJECT` / `rare_shape`） | gpu_bound | **1.35** | **D3** ⚠ | **64 卡** mohe-241；score `20260725_102519-p1swb-score`（bite `093941` + C2 `101806`）；Loud thr≥1.15；离线 D3=`shape_seq_rare`→rank_7（1536×200）；旁证 compute 双峰≈1.39；**D4 不足**（`host_mx_smi_unused`；缺 gpu 表；非 PSI/RSS）；**DONE_PARTIAL**；格 **P1-SW**；platform=metax；勿 ENV-BLOCKED |
| **P1-SW-C** | 编译缓存尖刺（tip） | `2c`（`INLINE_INJECT`） | gpu_bound | tip max≈**3.96**（med≈1.01） | **D3** ⚠ | **64 卡** mohe-241；score `20260725_054823-p1swc-score`（bite `052144` + C2 `053406`）；tip 叙事 median 盲；离线 D3=`min_compute_at_tip_step`→rank_7；C2 tip_vs_self_med≈21.7；**D4 不足**（SQL connection closed；`host_mx_smi_unused`；缺 gpu 表）；**DONE_PARTIAL**；platform=metax；勿 ENV-BLOCKED |
| **P1-HW-B** | 显存带宽渐进衰减 | **inline_hbm ramp**（`512MB` copies 6→48） | gpu_bound | **1.35** | **D4** ✅ | **64 卡** mohe-241；score `20260725_062452-p1hwb-score`（bite `055700` + C2 `061408`）；证据 `host_mx_smi_hbm_bw` hbm_bw≈352092；对象 `rank_7`；D3=`min_compute_ms`；格 **P1-HW**；D1 thr=1.3（dose）；platform=metax |
| **P2-SW-B** | MCCL 通道钳制 | `mccl_algo` Ring/Simple ch=4 + stress=512 | gpu_bound | step=**1.117** / comm=**1.685** / 标定=**2.050** | **D3** ⚠ | **64 卡** mohe-241；score `20260725_065237-p2swb-score`（bite `063127` + C2 `064217`）；主证=comm+标定（step&lt;1.15 不 FAIL）；离线 D3=`comm_phase_envwide`→rank_7；**D4 不足**（`comm_collective` present 无 duration 查询；mx-smi unused）；**DONE_PARTIAL**；格 **P2-SW**；platform=metax；勿 ENV-BLOCKED |
| **P2-SW-C** | 拓扑映射漂移 | `topo_5c` AR=256+SHM_DISABLE=1（禁 P2P） | gpu_bound | **1.265** | **D3** ⚠ | **pilot16** mohe-241；score `20260725_113632-p2swc-score`（bite `105912` + C2 `112917`）；Loud thr≥1.15；离线 D3=`topo_phase_envwide`→rank_7；**D4 不足**（`comm_collective`/`mlx_hca` present 无归因查询；mx-smi unused）；**64 未复核** → **DONE_PARTIAL**；格 **P2-SW**；platform=metax；勿 ENV-BLOCKED |
| **P1-EXT-C** | 同卡时间片抖动 | `3c`（sidecar timeslice N6×4096 EARLY） | gpu_bound | **80.70** | **D4** ✅ | **64 卡** mohe-241；score `20260725_135256-p1extc-score`（bite `130252` + C2 `133054`）；证据 `host_mx_smi_gpu_util` util=93%；对象 `rank_7`；D3=`min_wait_among_slow`；**jsonl 截断**：C1@210（56/64）、C2 heal@286（64/64）仍够中位窗；platform=metax；attempts=3 |
| **P2-SW-A** | 通信库回退（5A 代理） | `mccl_fallback` fabric_off+IB+STRESS1024（禁 Socket/P2P） | gpu_bound | step=**84.269** / comm=**470.328** | **D3** ⚠ | **pilot16** mohe-241；score `20260725_162012-p2swa-score`（bite `143520` + C2 `152032`）；主证=comm；离线 D3=`comm_phase_envwide`→rank_7；**D4 不足**（`comm_collective`/`mlx_hca` present 无归因查询；mx-smi unused）；**64 未复核** → **DONE_PARTIAL**；格 **P2-SW**；platform=metax；勿 ENV-BLOCKED；attempts=3 |
| **P1-HW-A** | GPU 降频（xcore dpm） | `freq`（`mx-smi --set-dpm-max xcore,0` mid@100） | gpu_bound | **2.071** | **D4** ✅ | **64 卡** mohe-241；score `20260725_171929-p1hwa-score`（bite `170104` + C2 `171025`）；证据 `host_mx_smi_dpm_freq` xcore_dpm=0 / 450MHz / ~154W；对象 `rank_7`；D3=`min_wait_among_slow`；格 **P1-HW**；D1 thr=1.3；attempts=2；platform=metax |
| **P1-HW-C** | 功耗墙间歇（xcore 脉冲） | `freq_pulse`（`xcore,0↔9` on=7s/off=1s arm@50） | gpu_bound | **2.06**（tip med≈2.05） | **D3** ⚠ | **64 卡** mohe-241；score `20260725_191434-p1hwc-score`（bite `184200` + C2 `185600`）；**间歇≠恒定 1A**；离线 D3=`min_compute_ms`→rank_7；**D4 不足**（dump 未采 dpm→`host_mx_smi_unused`；禁 injection 升 D4）；旁证 PULSE_LOW×85/HIGH×84；**DONE_PARTIAL**；格 **P1-HW**；attempts=3；platform=metax；勿 ENV-BLOCKED |
| **P3-HW-A** | 换页/ECC 代理（7A） | `stress_page` 64×6G mlock=0 + drop_caches | host_bound | **1.911** | **D3** ⚠ | **64 卡** mohe-241；score `20260725_220158-p3hwa-score`（bite `211310` + C2 `214900`）；C2/C0=1.756 同会话；离线 D3=`max_data_ms`→rank_5 same_host；**D4 不足**（dump `host_pgmajfault` Δ=0；PSI memory=0；SwapTotal=0；**禁** `host_psi_cpu`/injection 升 D4；≠真实 ECC；≠EXT-C stress_vm）；旁证 inject pgmajΔ=+278；**DONE_PARTIAL**；格 **P3-HW**；attempts=4；platform=metax；勿 ENV-BLOCKED |
| **P3-HW-B** | 主机 CPU 温墙（7B） | `cpufreq` mid@100 `scaling_max_freq=1200MHz` | host_bound | **1.728** | **D4** ✅ | **64 卡** mohe-241；score `20260725_233000-p3hwb-score`（bite `222800` + C2 `230600`）；C2/C0=2.419 同会话；证据 `host_cpufreq_scaling_max_locked` 128/128@1200MHz；离线 D3=`max_data_ms`→rank_5 same_host；格 **P3-HW**；C2 jsonl 56/64（h1444 miss）已记；≠campaign stress_vm；≠HW-A page；attempts=1；platform=metax |
| **P3-HW-C** | 本地盘读延迟（7C） | `disk_lat` dm-delay mid@100 `delay_ms=50` | host_bound | **1.927** | **D4** ✅ | **64 卡** mohe-241；score `20260726_012211-p3hwc-score`（bite `233800` + C2 `005600`）；C2/C0=1.913 同会话；证据 `host_disk_lat_dm_delay_odirect` dm=50 O_DIRECT≈58.1ms iowaitΔ=701；离线 D3=`max_data_ms`→rank_6 ±1；格 **P3-HW**；jsonl 64/64；≠campaign ecc；≠EXT-B stress_io；attempts=1；platform=metax |

**冻结归档（含 raw）**：[`reports/fail-slow-mohe/20260724-first-tier-loud-d4/`](../../reports/fail-slow-mohe/20260724-first-tier-loud-d4/CAMPAIGN.md)

## 3.2 baseline（对手工具）状态

> **本轮目标：把下面的 baseline 真跑出来，别轻易记 `ENV-BLOCKED`**（`rules.md` 红线 5）。每个都有沐曦接入路径，先当它能跑、去趟通。接入命令与检测方式详见 `BASELINE-SETUP-PLAYBOOK.md`（paper 侧）。
> baseline 测试方式（公平 + 代价五项）见 `rules.md` §三·五。

| 工具 | 角色 | 接入方式 | 检测方式 | 预期天花板 | 当前状态 |
|---|---|---|---|---|---|
| **Greyhound** | 主对手（D-run，在线） | LD_PRELOAD 挂 MCCL + Redis；docker `tianyuanwu/greyhound:ae` | ACF 估周期 → Rbeast 变点 → GEMM/P2P 微基准主动定位 | **D3**（无 PID/温频，不分 HW/SW/EXT）；**本 mohe collect-min 止于 D2** | **P1-EXT-A loud DETECT D2**（`20260726_082325`；inter-AR≈3.11× IoU≈0.86；C3/C0≈3.59 vs D4/3.10）；**P1-EXT-B loud DETECT D2**（`20260726_102700`；step-max gap≈2.14× IoU≈0.99；C3/C0≈1.706 vs D4/1.69）；**P3-EXT-A loud DETECT D2**（`20260726_114620`；inter-AR mean-shift≈6.74× IoU≈0.78；C3/C0≈2.42 vs D4/2.51）；**P3-SW-A loud DETECT D2**（`20260726_132530`；step-max gap≈2.62× IoU≈0.995；C3/C0≈2.782 vs D4/2.72）；**P3-EXT-C loud DETECT D2**（`20260726_144331`；inter-AR mean-shift≈5.51× IoU≈0.79；C3/C0≈4.237 vs D4/3.43）；**P3-SW-B loud DETECT D2**（`20260726_161522`；step-max gap≈2.15× IoU≈0.957；C3/C0≈2.755 vs D4/2.74）；**P3-SW-C loud DETECT D2**（`20260726_180605`；step-max gap≈3.75× IoU≈0.995；C3/C0≈3.441 vs D4/2.85）；**P1-SW-A loud DETECT D2**（`20260726_193227`；step-max gap≈2.76× IoU≈0.995；C3/C0≈3.395 vs DONE_PARTIAL D3/3.40）；**P1-SW-C loud DETECT D2** tip（`20260726_201016`；tip_max/clean_med≈8.05× onset@99 IoU≈0.995；med≈1.01 盲；tip_max≈3.96 vs DONE_PARTIAL D3 tip）；**P1-HW-B loud DETECT D2**（`20260726_205510`；step-max gap mean≈1.19× med≈1.35× onset@100 IoU≈1.0；C3/C0≈1.339 vs D4/1.35）；**P2-SW-B loud NO_DETECT D0**（`20260726_213527`；mccl_algo env-wide 无变点；C3/C0 step≈1.116/comm≈1.693 vs DONE_PARTIAL D3）；**P1-SW-B loud DETECT D2**（`20260726_220917`；step-max gap mean≈1.24× med≈1.50× onset@81 IoU≈0.913；C3/C0≈1.369 vs DONE_PARTIAL D3/1.35）；**P2-SW-C loud NO_DETECT D0**（`20260726_235900`；topo_5c env-wide 无变点；gap≈1.07×/0.99× IoU≈0.425；C3/C0≈1.604 vs DONE_PARTIAL D3/1.26 pilot16） |
| **XPUTimer** | 次对手（E-run，在线） | LD_PRELOAD + MACA 兼容层；Bazel 构建，NCCL≤2.21.5；**本 mohe 用 plain g++ `metax_probe`**（`mc*`/`mccl*`） | 采关键算子/通信事件 → Prometheus 五指标 + hang | **D0–D1**（只采信号不判，自动 RCA 未开源） | **P1-EXT-A loud NO_DETECT D0**（`20260726_085311`；hang/slow=0；C4/C0≈3.67 vs Probing D4/3.10 / GH D2）；**P1-EXT-B loud NO_DETECT D0**（`20260726_104136-p1extb-xputimer-contrast`；hang/slow=0；C4/C0≈1.689 vs Probing D4/1.69 / GH D2）；**P3-EXT-A loud NO_DETECT D0**（`20260726_120830-p3exta-xputimer-contrast`；hang/slow=0；C4/C0≈3.11 vs Probing D4/2.51 / GH D2）；**P3-SW-A loud NO_DETECT D0**（`20260726_134335-p3swa-xputimer-contrast`；hang/slow=0；C4/C0≈2.750 vs Probing D4/2.72 / GH D2）；**P3-EXT-C loud NO_DETECT D0**（`20260726_145900-p3extc-xputimer-contrast`；hang/slow=0；C4/C0≈4.247 vs Probing D4/3.43 / GH D2）；**P3-SW-B loud NO_DETECT D0**（`20260726_164500-p3swb-xputimer-contrast`；hang/slow=0；C4/C0≈2.756 vs Probing D4/2.74 / GH D2）；**P3-SW-C loud NO_DETECT D0**（`20260726_183100-p3swc-xputimer-contrast`；hang/slow=0；C4/C0≈3.313 vs Probing D4/2.85 / GH D2）；**P1-SW-A loud NO_DETECT D0**（`20260726_195140-p1swa-xputimer-contrast`；hang/slow=0；C4/C0≈3.407 vs Probing DONE_PARTIAL D3/3.40 / GH D2；**B-core 齐**）；**P1-SW-C loud NO_DETECT D0** tip（`20260726_202956-p1swc-xputimer-contrast`；hang/slow=0；tip_max≈3.32 med≈1.03 盲；C4/C0≈1.025 vs Probing DONE_PARTIAL D3 tip / GH D2 tip；**B-core 齐**）；**P1-HW-B loud NO_DETECT D0**（`20260726_210800-p1hwb-xputimer-contrast`；hang/slow=0；C4/C0≈1.398 vs Probing D4/1.35 / GH D2；**B-core 齐**）；**P2-SW-B loud NO_DETECT D0**（`20260726_215200-p2swb-xputimer-contrast`；hang/slow=0；C4/C0 step≈1.136/comm≈1.715 vs Probing DONE_PARTIAL D3 / GH D0；**B-core 齐**）；**P1-SW-B loud NO_DETECT D0**（`20260726_224130-p1swb-xputimer-contrast`；hang/slow=0；C4/C0≈1.374 vs Probing DONE_PARTIAL D3/1.35 / GH D2；**B-core 齐**） |
| **Dynolog + Profiler + HTA** | 新 baseline（trade-off「极深极贵」极点，本轮要真跑） | Dynolog daemon + oracle `torch.profiler`（MetaX）；HTA 离线 | 全栈 kernel 级 profiling；HTA 事后分解 | D3–D4（事后、极贵；**oracle 触发不算检出率**） | **P1-EXT-A loud ORACLE-TRIGGERED · DEPTH D3**（`20260726_093233-p1exta-dynolog-contrast`；HTA r7 non_compute 18.8×r0；C6/C0≈3.71；**不算**检出率；代价 +20%/dump≈51MB）；**P1-EXT-B loud ORACLE-TRIGGERED · DEPTH D3**（`20260726_105400-p1extb-dynolog-contrast`；HTA r7 non_compute 193×r0；C6/C0≈1.703；**不算**检出率；代价 +0.8%/dump≈52MB）；**P3-EXT-A loud ORACLE-TRIGGERED · DEPTH D1**（`20260726_123330-p3exta-dynolog-contrast`；HTA nc≈0.77 idle≈1.14×；同机采样无 D3；C6/C0≈4.334；**不算**检出率；代价 +73%/dump≈51.6MB）；**P3-SW-A loud ORACLE-TRIGGERED · DEPTH D3**（`20260726_135900-p3swa-dynolog-contrast`；HTA idle≈37.97× nc≈1.42；C6/C0≈4.167；**不算**检出率；代价 +53%/dump≈48.9MB）；**P3-EXT-C loud ORACLE-TRIGGERED · DEPTH D3**（`20260726_152045-p3extc-dynolog-contrast`；HTA idle≈2.16× nc≈1.68；C6/C0≈4.894；**不算**检出率；代价 +43%/dump≈49MB）；**P3-SW-B loud ORACLE-TRIGGERED · DEPTH D3**（`20260726_165722-p3swb-dynolog-contrast`；HTA idle≈25.95× nc≈1.14；C6/C0≈2.747；**不算**检出率；代价 +0.3%/dump≈48.9MB）；**P3-SW-C loud ORACLE-TRIGGERED · DEPTH D1**（`20260726_184930-p3swc-dynolog-contrast`；HTA idle≈1.30× nc≈0.70；同机弱对比无 D3；C6/C0≈4.246；**不算**检出率；代价 +49%/dump≈51.4MB） |
| **PyTorch Flight Recorder** | 新 baseline（trade-off「极轻极窄」极点，本轮要真跑） | 环境变量启用环形缓冲（如 `TORCH_NCCL_TRACE_BUFFER_SIZE`）；`fr_trace` 解析 | 只记 collective 元数据，做 hang/desync | **D1**（P2 in-scope；P1 芯片 / P3 主机结构上看不到） | **P1-EXT-A loud STRUCTURAL_NA**（`20260726_101249-p1exta-fr-contrast`；C5/C0≈3.59；FR NO_HANG_DESYNC；**≠D0**；dump≈51MB；vs Probing D4；P1-EXT-A 四工具收口）；**P1-EXT-B loud STRUCTURAL_NA**（`20260726_111650-p1extb-fr-contrast`；C5/C0≈1.700；FR NO_HANG_DESYNC；**≠D0**；dump≈29.5MB；vs Probing D4；P1-EXT-B 四工具收口）；**P3-EXT-A loud STRUCTURAL_NA**（`20260726_125935-p3exta-fr-contrast`；C5/C0≈2.543；FR NO_HANG_DESYNC；**≠D0**；dump≈29.47MB；vs Probing D4；P3-EXT-A 四工具收口）；**P3-SW-A loud STRUCTURAL_NA**（`20260726_141900-p3swa-fr-contrast`；C5/C0≈2.728；FR NO_HANG_DESYNC；**≠D0**；dump≈29.47MB；vs Probing D4；P3-SW-A 四工具收口）；**P3-EXT-C loud STRUCTURAL_NA**（`20260726_154506-p3extc-fr-contrast`；C5/C0≈2.945；FR NO_HANG_DESYNC；**≠D0**；dump≈29.47MB；vs Probing D4；P3-EXT-C 四工具收口）；**P3-SW-B loud STRUCTURAL_NA**（`20260726_172401-p3swb-fr-contrast`；C5/C0≈2.749；FR NO_HANG_DESYNC；**≠D0**；dump≈29.47MB；vs Probing D4；P3-SW-B 四工具收口）；**P3-SW-C / P1-SW-A / P1-SW-C / P1-HW-B FR DEFER→B-ext**（软切）；P2-SW-B×GH **NO_DETECT D0**（`20260726_213527`）；P2-SW-B×XT **NO_DETECT D0**（`20260726_215200`；hang/slow=0；step≈1.136/comm≈1.715；**B-core 齐**）；跳过 GAVE_UP P3-EXT-B；P1-SW-B×GH hold64 PASS（8/8 shm=32G；skip preflight；loud=`093941` rare_shape/2b SEQ=1536）；P1-SW-B×GH **DETECT D2**（`20260726_220917`；step-max≈1.24×/1.50× IoU≈0.913）；P1-SW-B×XT **NO_DETECT D0**（`20260726_224130`；hang/slow=0；C4/C0≈1.374；**B-core 齐**）；P2-SW-C×GH hold64 PASS（8/8 shm=32G；skip preflight；loud=`105912` dose=5c AR=256+SHM_DISABLE；Probing D3≈1.26 pilot16）；P2-SW-C×GH **NO_DETECT D0**（`20260726_235900`；env-wide；gap≈1.07× IoU≈0.425）；下一 **P2-SW-C / xputimer / contrast_run**（dose=loud；skip preflight；hold64 近 PASS；skip Dyn/FR→B-ext） |
| StragglerAnalysis | 离线可选补充 | 离线喂 B-run trace 转成 parquet | 依赖图仿真理想 timeline → slowdown 分解 | D2（无 PID/温频/编译事件） | 转换脚本待写；标“离线”，不并入在线检出率 |

> **两个新 baseline 与 outline 的关系**：Dynolog / Flight Recorder 在 `OUTLINE-v5.md` 里目前是「引用不跑」的 trade-off 极点；本轮决定**升级为真跑**（2026-07-24 拍板），outline 正文待跑出数后回改。它俩的 preflight / 触发策略 / verdict schema 依据 `SOP-COMPATIBILITY-DYNOLOG-FLIGHT-RECORDER.md`。
>
> **触发协议注意**（`rules.md` §三·五 B）：这两个是**按需触发**型，不是常驻检测。若用「已知故障时刻」触发采集 = **oracle 触发**，只能比「采到后诊断多深 + 代价」，**不能**算它的检出率 / trigger 延迟。用前必须在此标清是 oracle 触发还是自主检出。

## 3.2b baseline 代价记录（五项，每个 baseline + Probing 都填）

> 指标定义见 `rules.md` §三·五 B。同 seed、对齐窗口、看中位数（控变 ①②）。

| 工具 | 1 常驻开销% | 2 注入期扰动 | 3 trigger 延迟 | 4 分析延迟 | 5 存储/内存 |
|---|---|---|---|---|---|
| Probing | 待填 | 待填 | 待填（SET 热更 <200ms） | 待填 | `PROBING_COLD_MAX_TOTAL_MB` |
| Greyhound | 自报 ~0.39%（本轮健康线未测） | P1-EXT-A：+16~20%；P1-EXT-B：+0.7%；P3-EXT-A：≈0%；P3-SW-A：+2%；P3-EXT-C：+24%；P3-SW-B：+0.5%；P3-SW-C：+21%；**P1-SW-A**：C3/C0≈3.395 vs Loud 3.40 → **≈0%**；**P1-SW-C** tip：C3/C0 med≈1.017 vs Loud tip med≈1.01 → **≈0%**；**P1-HW-B**：C3/C0≈1.339 vs Loud 1.35 → **≈0%**；**P2-SW-B**：step≈1.116 vs Loud 1.117 → **≈0%**；**P1-SW-B**：C3/C0≈1.369 vs Loud 1.35 → **≈+1.4%** ；**P2-SW-C**：within-C3≈0%（C0=pilot16 不报公平%） | **N/A**（collect-min 无在线 trigger） | 离线变点秒级（未跑 20s 微基准） | P1-EXT-A/B/P3-EXT-A/P3-SW-A/P3-EXT-C/P3-SW-B/**P1-SW-A**/P1-SW-C/**P1-HW-B**/P1-SW-B dump **≈63MB**；**P2-SW-B** dump **≈137MB**（含作废212612 append；late≈68MB）；**P2-SW-C** dump **≈2050MB**（AR=256 膨胀）；P3-SW-C ≈145MB（含作废轮 append；本训窗≈58MB） |
| XPUTimer | 自报 ~0.43%（本轮健康线未测） | P1-EXT-A：C4/C0≈3.67 vs Loud 3.10 → **+18%**；P1-EXT-B：C4/C0≈1.689 vs Loud 1.69 → **≈0%**；P3-EXT-A：C4/C0≈3.11 vs Loud 2.51 → **+24%**；P3-SW-A：C4/C0≈2.750 vs Loud 2.72 → **+1%**；P3-EXT-C：C4/C0≈4.247 vs Loud 3.43 → **+24%**；**P3-SW-B**：C4/C0≈2.756 vs Loud 2.74 → **+0.6%**；**P3-SW-C**：C4/C0≈3.313 vs Loud 2.85 → **+16%**；**P1-SW-A**：C4/C0≈3.407 vs Loud 3.40 → **≈0%**；**P1-SW-C** tip：C4/C0 med≈1.025 vs Loud tip med≈1.01 → **≈0%**；**P1-HW-B**：C4/C0≈1.398 vs Loud 1.35 → **+3.6%**；**P2-SW-B**：step≈1.136 vs Loud 1.117 → **+1.7%**；**P1-SW-B**：C4/C0≈1.374 vs Loud 1.35 → **+1.8%** | **N/A**（hang/slow=0；timeout env 60s 未触发） | **N/A**（无 analyzer；自动 RCA 未开源） | P1-EXT-A ≈194 MiB；P1-EXT-B / P3-EXT-A / P3-SW-A / P3-EXT-C / P3-SW-B / P3-SW-C / P1-SW-A / P1-SW-C / P1-HW-B / P2-SW-B / **P1-SW-B** prom+trace **≈100–102 MB**（~12 MiB/pod；~1.5 MiB/rank；64+64） |
| Dynolog+HTA | 常驻未测（daemon IPC 未挂上 trainer） | P1-EXT-A：C6/C0≈3.71 vs Loud 3.10 → **+20%**；P1-EXT-B：C6/C0≈1.703 vs Loud 1.69 → **+0.8%**；P3-EXT-A：C6/C0≈4.334 vs Loud 2.51 → **+73%**；P3-SW-A：C6/C0≈4.167 vs Loud 2.72 → **+53%**；P3-EXT-C：C6/C0≈4.894 vs Loud 3.43 → **+43%**；**P3-SW-B**：C6/C0≈2.747 vs Loud 2.74 → **+0.3%**；**P3-SW-C**：C6/C0≈4.246 vs Loud 2.85 → **+49%** | **oracle 触发（不算）** | HTA parse ≈**2–12 s**（temporal OK；本轮 P3-SW-C≈12s） | P1-EXT-A 短窗 2-rank **≈51.3 MB**；P1-EXT-B ≈52.1 MB；P3-EXT-A ≈51.6 MB；P3-SW-A ≈48.9 MB；P3-EXT-C ≈49.0 MB；**P3-SW-B ≈48.9 MB**（~24.4 MB/rank；[120,128]）；**P3-SW-C ≈51.4 MB**（~25.7 MB/rank） |
| Flight Recorder | 常驻未测（环形缓冲预期极轻） | P1-EXT-A：C5/C0≈3.59 vs Loud 3.10 → **+16%**；P1-EXT-B：C5/C0≈1.700 vs Loud 1.69 → **+0.6%**；P3-EXT-A：C5/C0≈2.543 vs Loud 2.51 → **+1.3%**；P3-SW-A：C5/C0≈2.728 vs Loud 2.72 → **+0.3%**；P3-EXT-C：C5/C0≈2.945 vs Loud 3.43 → **−14%**（本跑注入窗弱于冻结 Loud）；**P3-SW-B**：C5/C0≈2.749 vs Loud 2.74 → **+0.3%** | **N/A**（structural_na；无自主 hang/desync 告警） | 离线 pickle 秒级（官方 `fr_trace` 未入 wheel） | P1-EXT-A dump **≈51.34 MB**；P1-EXT-B / P3-EXT-A / P3-SW-A / P3-EXT-C / **P3-SW-B ≈29.47 MB**（step300+end 64+64；~0.46 MB/rank） |

> “自报”= 来自该工具论文/文档，**须在本环境实测复核**后替换。

## 3.3 判分证据口径（当前实测结论）

- **D0–D3**：训练埋点（C1/C0、`data_ms`、窗 IoU、同机 victim 命中）即可支撑。
- **D4**：需 Probing SQL 或同窗旁路（PSI / mx-smi / 已有表 RSS）。
  - P3-EXT：`cpu.tasks` 只见本进程 → 允许 `host_psi_cpu` / `host_psi_io`。
  - P3-EXT-C（`stress_vm`）：MetaX 上 memory.some 常为 0；允许同窗 **`host_psi_cpu`**（via_vm overlay）升 D4，须注明 memory 未 hit；**勿裸 pgrep**。
  - P3-SW：允许 `cpu.utilization` 进程 `rss_kb` 超阈 **或窗内明显抬升**（`cpu.utilization_rss`；阈 max≥700k 或 rise≥50k）。
  - P3-SW-C（`sidecar_8c`）：外挂不在 probing attach PID 时 rss 窗升常弱；允许同窗 **`host_psi_cpu`**（8c overlay）升 D4，须注明 rss 弱；**格仍标 P3-SW**；**勿裸 pgrep**。
  - P1-EXT：MetaX 缺 `gpu.utilization` / `process.gpu_users` → 允许同窗 `mx-smi`（`host_gpu.json`：`host_mx_smi_gpu_util` / `host_mx_smi_hbm_bw`）。**勿把 PSI 误套到 P1**。
  - P1-EXT-C（`3c` timeslice）：与 P1-EXT-A 同证 **`host_mx_smi_gpu_util`**；D3=`min_wait_among_slow`；Loud EARLY-after-warmup（PRE_TRAIN 易晚到假阴）；强争用下 C1/C2 jsonl 可能截断，须在 note 写明；**勿把 PSI 误套到 P1**。
  - P1-HW-A（`freq` / `mx-smi --set-dpm-max xcore,N`）：同窗 mx-smi → **`host_mx_smi_dpm_freq`**（hit：`xcore_dpm_max≤1`；旁记 xcore_mhz / board_power）；D3=`min_wait_among_slow`；格标 **P1-HW**；Loud dose accept≥1.3 → 离线 D1 thr=1.3。**勿把 PSI 误套到 P1**；**勿用 cube-proxy 冒充真改频主路径**。
  - P1-HW-C（`freq_pulse` / 间歇 `xcore,0↔9` on/off）：**勿当恒定 1A**；Loud tip med/p99/max 闸门（本跑 med≈2.05）；D3=`min_compute_ms`（barrier 拉齐 wait，`min_wait` 会误指）；D4 期望同 **`host_mx_smi_dpm_freq`**，但单次 dump 可能落在 PULSE_HIGH / 本跑 dump 未采 dpm → **D3+DONE_PARTIAL**；**禁 injection.log 升 D4**；**勿把 PSI 误套到 P1**。
  - P3-HW-A（`stress_page` / OUTLINE 7A 换页·ECC **代理**）：Loud thr≥**1.15**；剂量 a4=`64×6G mlock=0`+drop_caches；**≠真实 ECC**；**≠ EXT-C `stress_vm`**（勿用 `host_psi_cpu` overlay 升 D4）。D3=`max_data_ms`（host_bound；same_host 可）。D4 期望同窗 **`host_pgmajfault`**（`host_vmstat.json`）或 **PSI memory**；本跑 dump 窗 pgmaj Δ=0 / mem PSI=0（SwapTotal=0）→ **D3+DONE_PARTIAL**；inject 窗 pgmajΔ 仅旁证；**禁 injection.log 升 D4**。
  - P3-HW-B（`cpufreq` / OUTLINE 7B 主机 CPU 温墙）：Loud thr≥**1.15**；真·`scaling_max_freq` mid@100（本跑 1200MHz）；host_bound；**≠ campaign 误写 `stress_vm`**；**≠ HW-A page**；**≠ EXT-A PSI-cpu**。D3=`max_data_ms`（same_host 可）。D4 同窗 **`host_cpufreq`**（`host_cpufreq.json` hit=`host_cpufreq_scaling_max_locked`）；本跑 128/128 核 max=1200000 → **D4+DONE**；C2 jsonl 缺 rank（h1444）记 note 不 FAIL；**禁 injection.log 升 D4**。
  - P3-HW-C（`disk_lat` / OUTLINE 7C 本地盘读延迟）：Loud thr≥**1.15**；真·`dm-delay` mid@100（本跑 `delay_ms=50`）；host_bound IO_PAYLOAD O_DIRECT；**≠ campaign ecc**；**≠ EXT-B `stress_io`/fio**。D3=`max_data_ms`（±1 / same_host 可）。D4 同窗 **`host_disk_lat`**（`host_disk_lat.json` hit=`host_disk_lat_dm_delay_odirect`）；本跑 dm=50 / O_DIRECT≈58.1ms / iowaitΔ=701 → **D4+DONE**；**禁 injection.log 升 D4**。
  - P1-HW-B（`inline_hbm` ramp）：与 P1-EXT-B 同证 **`host_mx_smi_hbm_bw`**；D3=`min_compute_ms`；格标 **P1-HW**；Loud dose accept≥1.3 → 离线 D1 thr=1.3。**勿把 PSI 误套到 P1**。
  - P1-SW-A（`inline_2a`）：D3 用 `min_compute_ms`（全员 step 被 barrier 拉齐，`min_wait` 会误指）。探索指望的 `cuda_frag_gap` 趋势实测常 **C1−C0≈0**；`mx-smi` 标 `host_mx_smi_unused` 非主证。当前 **无合法 SQL/旁路升 D4** → 记 D3+dump / **DONE_PARTIAL**；**勿 ENV-BLOCKED**。
  - P1-SW-B（`inline_2b` / `rare_shape`）：Loud thr≥**1.15**；D3=`shape_seq_rare`（窗内唯一 rare_seq 的 rank；`min_wait`/`min_compute` 齐平会误指）。旁证 `score_shape_bimodal`（shape+compute 双峰）。`mx-smi`/`PSI` 非主证。当前 **无合法 SQL 升 D4** → D3+dump / **DONE_PARTIAL**；**勿 ENV-BLOCKED**。
  - P1-SW-C（`inline_2c` tip）：**median 盲、尖刺可见**；D1 用 tip victim L7 的 max/p99 闸门（对齐 `accept_p1swc_spike`）；D3=`min_compute_at_tip_step`→victim。SQL dump 常 **connection closed**；`mx-smi`/`PSI` 非 tip 主证。当前 **无合法 SQL 升 D4** → D3+dump / **DONE_PARTIAL**；**勿 ENV-BLOCKED**。
  - P2-SW-A（`mccl_fallback` / OUTLINE 5A 代理）：Loud **主证=comm_ms**（step 亦过闸；实测 step≈84 / comm≈470）；剂量=`fabric_off`+`IB_DISABLE`+`STRESS=1024`（SHM keep；**禁 NET=Socket** hang；**禁 P2P_DISABLE**）。离线 D1=`comm_ms` thr≥1.3；D3=`comm_phase_envwide`（env-wide 回退，对象=GT victim/attach）。`comm_collective`/`mlx_hca` present 但 dump **无 duration/HCA-order 查询**；mx-smi/PSI 非主证 → 当前 **无合法 SQL 升 D4** → D3+dump / **DONE_PARTIAL**；本轮仅 **pilot16**（64 未复核）；**勿 ENV-BLOCKED**；**勿把 mx-smi/PSI 误套到 P2**。
  - P2-SW-B（`mccl_algo`）：Loud **主证=comm_ratio + MCCL 标定**；step&lt;1.15 **不自动 FAIL**（对齐 h3c）。离线 D1=`comm_ms` thr≥1.3；D3=`comm_phase_envwide`（env-wide 钳制，对象=GT victim/attach）。`python.comm_collective` 表常 present 但 dump **无 duration 查询** → 当前 **无合法 SQL 升 D4** → D3+dump / **DONE_PARTIAL**；**勿 ENV-BLOCKED**；**勿把 mx-smi/PSI 误套到 P2**。
  - P2-SW-C（`topo_5c`）：Loud **主证=step_ms** thr≥**1.15**（`comm_ms`≈0，EXTRA_AR 进 residual）；**禁 P2P_DISABLE**。离线 D3=`topo_phase_envwide`（env-wide；对象=GT victim/attach；`min_wait` 会误指）。tables 可见 `comm_collective`/`rdma.mlx_hca` 但 dump **无 duration/HCA-order 查询**；mx-smi/PSI 非主证 → 当前 **无合法 SQL 升 D4** → D3+dump / **DONE_PARTIAL**；本轮仅 **pilot16**（64 未复核）；**勿 ENV-BLOCKED**；**勿把 mx-smi/PSI 误套到 P2**。
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
| 跨 rank 联邦查询 | ⚠️ 待探索实测：是否支持 `global.*`；当前管线可对各 rank 分别查再外部汇总 |

---

## 附：本台账与其他文档的关系

| 内容 | 落点 |
|---|---|
| 方法论（红线/控变/三阶段） | [`rules.md`](rules.md) |
| case 故障定义 | `OUTLINE`（论文侧 27-case 真相源） |
| 注入配方 / 检测脚本 | `scripts/fail-slow/`（含 `dose_recipes.yaml`） |
| 历史拍板决策 | [`decisions.md`](decisions.md) |
| 落盘路径 | [`layout.md`](layout.md) |
| 冻结战役 raw | `reports/fail-slow-mohe/20260724-first-tier-loud-d4/` |
