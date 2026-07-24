# Probing Fail-Slow：需他方 Agent 细化 / 补全清单

> 给「补实验计划 / case 文档」的 Agent。  
> 执行侧约定见 `docs/fail-slow/layout.md`；宏观规程见 `docs/fail-slow/sop.md`。  
> 日期：2026-07-23。

---

## A. 必须先拍板（否则实现只能脑补）

| # | 模糊点 | 现状 | 需要补成什么 |
|---|---|---|---|
| A1 | **Workload 规格** | SOP：GPT-2 124M / 500 步 / seq1024；已跑通：`train_bench_probe.py` TinyGPT / 默认 ~100 iter | 二选一或分阶段（pilot TinyGPT → 论文 GPT-2），写死表：模型、iters、warmup、`N_inject`、batch、dtype、并行（DDP/FSDP） |
| A2 | **本轮 case 白名单** | 27 格里多类做不到或无效 | 列出「本轮必跑 / 跳过(原因) / 以后再说」；跳过不进 M/27 分母写法 |
| A3 | **规模阶梯** | 顺序 mohe→h3c；mohe 总 128 卡、空闲常 <128 | 每阶段 world_size（8/16/32/64/128）、nnodes×nproc、是否整机 pin |
| A4 | **平行 run 集合** | SOP 要 A/B/C/D/E；上轮只跑 C0–C2 | 本轮最低集合（是否必须 Greyhound/XPUTimer）与 ENV-BLOCKED 记法 |
| A5 | **判分主证据** | SOP 靠 Probing SQL；上轮主证据是训练内 `compute_ms`/`wait_ms` | 论文用哪条证据链；SQL 表在 MetaX 上是否齐（见 B3） |

---

## B. Case / 注入层未写清

| # | 模糊点 | 需要补成什么 |
|---|---|---|
| B1 | 仅有 `P1-EXT-A.md`，其余 26 无独立 case 文档 | 按 `TEMPLATE.md` 填 §1–§4（注入参数、剂量、时序、检查清单） |
| B2 | Case 文档路径写 `scripts/injection/<id>/`，实际在 `scripts/fail-slow/sidecar_inject_v2.py`（kind 分支） | 统一路径与 `INJECT_KIND` 映射表（cube/hbm/freq/stress_* /…） |
| B3 | P1-EXT-A SQL 引用 `gpu.utilization` / `process.gpu_users` / `nccl.proxy_ops` | 在 MetaX+Probing 上确认表/字段是否存在；没有则改写检测方案 |
| B4 | **P1-HW 频率**：铁律不能中途改 DPM，与 SOP step150 注入冲突 | 改为「启动即带档」协议，或标 N/A；写清恢复档 `xcore=9,mc=3` |
| B5 | **P2-HW tc/netem**：RoCE 绕过，注入端做不到 | 明确跳过或仅邻居 `ib_write_bw`（EXT）代理；检测端 `rdma statistic` 是否纳入判分 |
| B6 | **P3 host**：上轮 GPU-bound+prefetch 咬不动 | Loud 可感知的 DataLoader/`host_bound` 配方；咬不动时 `injection_ineffective` 口径 |
| B7 | P1-SW / P2-SW 六格上轮占位 | 实现或本轮剔除 |
| B8 | 间歇/渐进时序（1C/3C/1A） | on-off / 线性递增的具体 step 表 |
| B9 | 多节点 ground-truth / step counter | AFS 不可用时：如何跨节点同步注入触发（rank0 写哪、watch 哪） |

---

## C. 检测 / 对手 / 判分

| # | 模糊点 | 需要补成什么 |
|---|---|---|
| C1 | SOP §5.2「Probing 人写规则 vs 对手出厂规则」 | 冻结流程：仅 Loud pilot 调参 → 文档化 → Quiet/Masked 不改；对手同等机会怎么记 |
| C2 | `cross_rank_compare.py` SOP 有、仓内无 | 实现规格或改口「本轮单节点不需要」 |
| C3 | Greyhound / XPUTimer MetaX（MCCL）可跑性 | 能跑：接入命令与预期 D；不能：ENV-BLOCKED 模板 |
| C4 | StragglerAnalysis / SuperBench 离线喂 B-run | parquet/summary 字段映射与转换脚本落点 |
| C5 | D2 IoU / D3 ±1 rank / D3.5 统计口径 | 填表公式与 scoring_table.csv schema 定稿 |
| C6 | FPR≤2% 与 ROC | 健康 A 线如何跑检测规则、误报怎么计步 |

---

## D. 工程 / 落盘（执行侧已定部分可只对齐文档）

| # | 模糊点 | 需要补成什么 |
|---|---|---|
| D1 | AFS：raw Pod 挂 weight-share 不可靠（见 layout §3） | case/SOP 正文改为「pod 本地 + 本机 `results/` 备份」；勿再写「必须 AFS」除非改走平台 PVC 作业 |
| D2 | `provision_priv_pods.sh` 未挂 PVC、默认假设 AFS | 与 layout 对齐：默认 `deploy_local`；文档标明 |
| D3 | mohe 用哪张 PVC/secret（若将来非 raw 作业要挂盘） | `muxi-mohe-storage` / `card-screen-128` 与 `yinjinrun.p` 家目录对应关系写清 |
| D4 | 结果目录 schema | 与 SOP §6.1 对齐的最小必填文件列表（layout 已给草案） |
| D5 | 上轮数据卫生问题（sidecar 污染 C0、重复 case、口径 +200% vs +170%） | 清洗规则 + 本轮防污染 checklist（case 间 clean_group + 频率复位） |

---

## E. 建议他方 Agent 的交付物顺序

1. 更新 SOP / case：**A1–A5 + B1–B2**（白名单 + workload + 路径映射）  
2. 第一梯队可跑 case 文档补全（至少 P1-EXT-A 已有，再补 9A/9B/8A 若仍在白名单）  
3. 跳过 case 表（B4–B7）与论文分母口径  
4. 对手与判分（C1–C6）能写多少写多少；ENV-BLOCKED 勿算 D0  

执行脚本真相源：`scripts/fail-slow/`。  
结果备份：`results/muxi-mohe/<run_id>/` → 再 `results/muxi-h3c/<run_id>/`。
