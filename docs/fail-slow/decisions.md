# Open Questions 决策记录（已关闭）

> 此文档记录 `probing-experiment-open-questions.md` 中各项的决策结果。已关闭的项不再是 open question。
> 日期：2026-07-23。

---

## A 类（必须拍板）—— 决策结果

| # | 问题 | 决策 | 落到哪 |
|---|---|---|---|
| A1 | Workload 规格 | **GPT-2 124M / 500 步 / seq1024 / DDP**（SOP 写的）。TinyGPT 仅作 pilot 快速验证管线,论文数字用 GPT-2。 | SOP §2.1 已写死 |
| A2 | 本轮 case 白名单 | 第一梯队(3A/3B/9A/9B/8A)先跑;❌ 的(4A-4C)跳过不进分母;◐ 的视权限推进 | case 文档各自标注 |
| A3 | 规模阶梯 | 默认 8 卡(单节点);Eval-D 扫 8/32/128/512;超 512 卡视资源 | SOP §5.2.4 A-sys |
| A4 | 平行 run 集合 | 最低: A/B/C(Probing);对手视环境:能跑就加 D/E,ENV-BLOCKED 标 N/A | SOP §5.1.1 |
| A5 | 判分主证据 | **Probing SQL 表为主**;训练内 compute_ms/wait_ms 仅作离线验证,不作检测证据。**P3-EXT 附注(2026-07-24)**：`cpu.tasks` 实测仅本进程线程、见不到 host `stress-ng`；允许 `dump_probing_sql.sh` 同窗采集的 `/proc/pressure`（`host_pressure.json`，证据名 `host_psi_cpu`）升 D4。**P1-EXT 附注(2026-07-24)**：MetaX 上 CudaBackend 起不来 → `gpu.utilization`/`process.gpu_users` 长期 missing；允许同窗 `mx-smi`（`host_gpu.json`：`host_mx_smi_hbm_bw` / `host_mx_smi_gpu_util`）升 D4。**禁止**仅用 `injection.log` / 裸 `pgrep` | SOP §2.4 + `score_dlevel_sql.py` |

---

## B 类（Case/注入层）—— 决策结果

| # | 问题 | 决策 | 落到哪 |
|---|---|---|---|
| B1 | case 文档 | **2026-07-24 删除 `cases/`**：预写 SQL 违反红线 2 / 三阶段；定义→OUTLINE，配方→`dose_recipes.yaml`，检测→探索冻结进 `scripts/fail-slow/`，结果→`ledger.md` | README / ledger 维护纪律 |
| B2 | 注入脚本路径 | 统一为 `scripts/fail-slow/` + `INJECT_KIND` 分支;case 文档 §1.2 写具体 kind | case 文档各自 |
| B3 | SQL 表/字段确认 | **2026-07-23 复测（Probing_plus 0.2.5 wheel）**: `cpu.utilization`✅ / `gpu.devices`✅(可空) / `python.torch_trace`✅(需 `PROBING_TORCH_PROFILING=on`) / `python.comm_collective`✅；`gpu.utilization`⚠ 采样未自动起表（`SET probing.gpu.sample_interval` 亦失败，待查 backend）；`process.gpu_users`❌ 主线无表。PyPI `0.2.4` **无** gpu/cpu 扩展，勿用。统一环境见 `scripts/fail-slow/image/` | case 文档 §2 + image/README |
| B4 | P1-HW 频率注入 | **"启动即带档"协议**:训练启动前设好降频,整 run 带档(不中途改);恢复档 `xcore=9,mc=3` | P1-HW-A 文档 |
| B5 | P2-HW tc/netem | **标 ❌ 跳过**(RoCE 绕过 tc);检测方案照写(证明"检测就绪") | P2-HW 文档 |
| B6 | P3 host 咬不动 | SOP 已规定 num_workers=2 + prefetch_factor=2;Loud 档若仍无效标 `injection_ineffective` | case 文档 §1 + SOP §7.1 |
| B7 | P1-SW / P2-SW 占位 | 本轮实现;若无法实现标 ◐ 但仍写检测方案 | case 文档 |
| B8 | 间歇/渐进时序 | case 文档 §1.4 各自写特殊时序(on-off 周期 / 线性递增) | case 文档 |
| B9 | 多节点 ground-truth | SOP §2.4 已加:rank0 写 `/dev/shm/training_step`,注入器 watch;多节点用 AFS 原子文件 | SOP §2.4 |

---

## C 类（检测/对手/判分）—— 决策结果

| # | 问题 | 决策 | 落到哪 |
|---|---|---|---|
| C1 | 冻结流程 | 仅 Loud pilot 调参→文档化→Quiet/Masked 不改;对手同等机会(健康集+Loud pilot 调阈值) | SOP §5.2.1 |
| C2 | cross_rank_compare.py | 本轮方案:对每个 rank 分别查→外部 Python 汇总;SOP §3.8 已给模式 | SOP §3.8 |
| C3 | Greyhound/XPUTimer MetaX | **待接入**（非最终 ENV-BLOCKED）。有依赖坑（Greyhound: NCCL/Redis/Docker；XPUTimer: NCCL≤2.21.5/Bazel），但按红线 5 **先趟通再结论**；穷尽后才记 N/A，且**不**在编排脚本硬编码 blocked | `ledger.md` §3.2 |
| C4 | 离线对手 trace 转换 | 一律用 B run 导出;转换脚本待写(schema 见 BASELINE-SETUP-PLAYBOOK) | case 文档 §3 + 工程 TODO |
| C5 | D2/D3/D3.5 统计口径 | SOP §4.2 已定:IoU≥0.5=D2;D3 ±1 rank 容差;D3.5(位置对来源错)统计时算 D3 | SOP §4.2 |
| C6 | FPR≤2% + ROC | SOP §4.2 已改:≤2% 可接受;和检测率一起报 | SOP §4.2 |

---

## D 类（工程/落盘）—— 决策结果

| # | 问题 | 决策 | 落到哪 |
|---|---|---|---|
| D1 | AFS 不可靠 | 默认 pod 本地落盘 + 每 case 完立即回拉 `results/`;不强制 AFS | SOP §6.1 + AGENTS.md |
| D2 | provision 脚本 | 按 layout 用 `deploy_local`;SOP 不改,工程侧对齐 | 工程侧 |
| D3 | PVC/secret | 按实际环境决定;SOP 不做硬性规定 | 工程侧 |
| D4 | 结果目录 schema | SOP §6.1 已定 | SOP §6.1 |
| D5 | 数据卫生 | case 间: clean_group(停注入器、恢复频率);防污染 checklist 在 SOP §5.4 前置检查 | SOP §5.4 |

---

**所有 open questions 已关闭。** 后续如有新问题,在此文档末尾新增 F/G/... 分区。

---

## E. Loud2 实测闭环（2026-07-23）

| 项 | 结果 |
|---|---|
| run | `results/muxi-mohe/20260723_190341-failslow16-loud2/` |
| 注入 PASS | P1-EXT-A (3.80×)、P1-EXT-B (2.84×)、P3-EXT-A (2.94×) |
| 注入 ineffective | P3-EXT-B（不进分母，待复测）；P3-SW-A bite2 已通（20260724_114257，C1/C0=3.15） |
| 离线判分（训练埋点） | 三 PASS case 均 **D3**；D4 待 Probing SQL |
| 配方真相源 | `scripts/fail-slow/dose_recipes.yaml` |
| Quiet | `campaign_quiet_pass3.sh`（PASS 三 case） |

---

## F. 统一镜像 / Probing_plus 环境（2026-07-23）

| 项 | 结果 |
|---|---|
| wheel | Probing_plus `0.2.5`（features=`gpu,gpu-cuda,kmsg`，含 `mx-smi`）；MD5 `fe3b76db996fece61033c3c12480f2e9` |
| 配方 | `scripts/fail-slow/image/{Dockerfile,env.defaults,build.sh}` |
| 现网灌装 | `install_env_to_pods.sh` → `yjr-fs-h14410/11` 已装 |
| 打镜像推送 | ais 跳板对 `ccr-deeplink/megatron-lm` **unauthorized**；需在有拉底包+推送权限的节点上 `build.sh`，或后续补集群内 Kaniko |
| SQL-D4 战役 | `campaign_sql_d4.sh` + `dump_probing_sql.sh`；结果 `results/muxi-mohe/<ts>-failslow16-sql-d4/` |

---

## G. P1 Loud cube/hbm 咬合修复（2026-07-24）

| 项 | 结果 |
|---|---|
| 根因 | MetaX 上 warmup 末 `synchronize()` 与训练共卡挂死 → 无 `SIDECAR_START`；叠加 `ITERS=200` 假阴性；施压期过频 sync 会冲掉咬合力 |
| 修复 | `sidecar_inject.py`：先落盘 START，施压默认异步投核；pipeline：MACA-only、`wait_sidecar_start`、pkill 防自匹配、清 `/dev/shm/nccl*|mccl*`；战役强制 `ITERS≥500` |
| 冒烟 | cube `20260724_072344-cube-fix` C1/C0=**2.60**；hbm `20260724_072813-hbm-fix` C1/C0=**2.95** |
| 运维 | `yjr-fs-h14410` 曾 CUDA SIGBUS，已 delete+recreate pin `host-10-12-144-10`（新 IP）；cube 冒烟时临时挪走 `site-packages/probing.pth`，SQL 战役前需恢复 |
