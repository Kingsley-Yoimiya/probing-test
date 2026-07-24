# Open Questions 决策记录（已关闭）

> 此文档记录 `probing-experiment-open-questions.md` 中各项的决策结果。已关闭的项不再是 open question。
> 日期：2026-07-23。

---

## A 类（必须拍板）—— 决策结果

| # | 问题 | 决策 | 落到哪 |
|---|---|---|---|
| A1 | Workload 规格 | **GPT-2 124M / 500 步 / seq1024 / DDP**（SOP 写的）。TinyGPT 仅作 pilot 快速验证管线,论文数字用 GPT-2。 | SOP §2.1 已写死 |
| A2 | 本轮 case 白名单 | 第一梯队(3A/3B/9A/9B/8A)先跑;❌ 的(4A-4C)跳过不进分母;◐ 的视权限推进 | case 文档各自标注 |
| A3 | 规模阶梯 | **现状默认 2×8=16 rank**（ledger）；Eval-D 另扫 8/32/128/512 | `ledger.md` |
| A4 | 平行 run 集合 | 最低 C0/C1/C2（Probing）；对手 PENDING，穷尽后才 N/A | `rules.md` / `ledger.md` |
| A5 | 判分主证据 | **Probing SQL 表为主**;训练内 compute_ms/wait_ms 仅作离线验证,不作检测证据。**P3-EXT 附注(2026-07-24)**：`cpu.tasks` 实测仅本进程线程、见不到 host `stress-ng`；允许 `dump_probing_sql.sh` 同窗采集的 `/proc/pressure`（`host_pressure.json`，证据名 `host_psi_cpu`）升 D4。**P1-EXT 附注(2026-07-24)**：MetaX 上 CudaBackend 起不来 → `gpu.utilization`/`process.gpu_users` 长期 missing；允许同窗 `mx-smi`（`host_gpu.json`：`host_mx_smi_hbm_bw` / `host_mx_smi_gpu_util`）升 D4。**禁止**仅用 `injection.log` / 裸 `pgrep` | SOP §2.4 + `score_dlevel_sql.py` |

---

## B 类（Case/注入层）—— 决策结果

| # | 问题 | 决策 | 落到哪 |
|---|---|---|---|
| B1 | case 文档 | **2026-07-24 删除 `cases/`**：预写 SQL 违反红线 2 / 三阶段；定义→OUTLINE，配方→`dose_recipes.yaml`，检测→探索冻结进 `scripts/fail-slow/`，结果→`ledger.md` | README / ledger 维护纪律 |
| B2 | 注入脚本路径 | 统一为 `scripts/fail-slow/` + `INJECT_KIND`；kind 见 `dose_recipes.yaml` / `run_case_abc.sh` | 脚本 |
| B3 | SQL 表/字段确认 | **2026-07-23 复测（Probing_plus 0.2.5）**：见 `ledger.md` §3.4；PyPI 0.2.4 勿用 | `ledger.md` + `image/` |
| B4 | P1-HW 频率注入 | **"启动即带档"**：训练前设好降频，整 run 带档；恢复档 `xcore=9,mc=3` | OUTLINE / 探索冻结 |
| B5 | P2-HW tc/netem | **标 ❌ 跳过**（RoCE 绕过 tc） | OUTLINE |
| B6 | P3 host 咬不动 | `num_workers=2` + `prefetch_factor=2` + `host_bound`；仍无效 → `injection_ineffective` | `ledger.md` / `rules.md` |
| B7 | P1-SW / P2-SW 占位 | 探索阶段实现或标跳过不进分母 | OUTLINE + ledger |
| B8 | 间歇/渐进时序 | OUTLINE / dose 注释写 on-off / 线性递增 | OUTLINE |
| B9 | 多节点 ground-truth | rank0 写 step counter；AFS 不可靠时用 pod 本地+回拉（见 layout） | `layout.md` |

---

## C 类（检测/对手/判分）—— 决策结果

| # | 问题 | 决策 | 落到哪 |
|---|---|---|---|
| C1 | 冻结流程 | Loud pilot 调参→冻结进 scripts→Quiet/Masked 不改；对手同等机会 | `rules.md` |
| C2 | 跨 rank 汇总 | 对各 rank 分别查→外部汇总（`global.*` 待实测） | `ledger.md` §3.4 |
| C3 | Greyhound/XPUTimer MetaX | **PENDING / 待接入**（非 ENV-BLOCKED）；穷尽后才 N/A | `ledger.md` §3.2 |
| C4 | 离线对手 trace 转换 | 一律用 B/C1-run 导出；转换脚本待写 | 工程 TODO |
| C5 | D2/D3 口径 | IoU≥0.5=D2；**以 `rules.md` D3 为准**（P1/P2=rank，P3=host）；勿用已删 SOP 的 ±1/D3.5 | `rules.md` |
| C6 | FPR≤2% + ROC | ≤2% 可接受；和检测率一起报 | `rules.md` |

---

## D 类（工程/落盘）—— 决策结果

| # | 问题 | 决策 | 落到哪 |
|---|---|---|---|
| D1 | AFS 不可靠 | 默认 pod 本地落盘 + 立即回拉 `results/`；不强制 AFS | `layout.md` / `ledger.md` |
| D2 | provision 脚本 | 按 layout 本地落盘；工程侧对齐 | `layout.md` |
| D3 | PVC/secret | 按实际环境；不进方法论 | 工程侧 |
| D4 | 结果目录 schema | 见 `layout.md` / ledger §1.5 | `layout.md` |
| D5 | 数据卫生 | case 间 clean；发射前查外来 torchrun（ledger 门禁 #9） | `ledger.md` |

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
