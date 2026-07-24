# Fail-Slow × Probing 实验（文档真相源）

> **自 2026-07-24 起**：本目录为 Fail-Slow 实验文档的**唯一维护点**。  
> myportal `plans/probing-*` 仅保留入口 stub，指向此处。  
> 编排脚本真相源：[`../../scripts/fail-slow/`](../../scripts/fail-slow/)。

## 文档索引

| 文件 | 用途 |
|------|------|
| [`sop.md`](sop.md) | 标准实验流程（Pilot → 固化 → 正式） |
| [`decisions.md`](decisions.md) | 已拍板决策（含 A5 D4 证据） |
| [`layout.md`](layout.md) | 落盘 / 路径约定 |
| [`open-questions.md`](open-questions.md) | 待决问题 |
| [`p3-d4-first-case-runbook.md`](p3-d4-first-case-runbook.md) | **P3-EXT-A 首个 D4 跑通实录**（转发首选） |
| [`d4-live-sql-watch.md`](d4-live-sql-watch.md) | D4 SQL 盯梢笔记 |
| [`sql-d4-night-workflow.md`](sql-d4-night-workflow.md) | SQL-D4 夜间战役流程 |
| [`profiling-deep-dive.md`](profiling-deep-dive.md) | Probing 机制深挖 |
| [`cases/`](cases/) | 27 格 case 文档 + `TEMPLATE.md` |

## 与 myportal 的分工

| 内容 | 落点 |
|------|------|
| 实验文档 / case / SOP | **本仓** `docs/fail-slow/` |
| 编排 / 注入 / 判分脚本 | **本仓** `scripts/fail-slow/` |
| 身份 / kube / vault / 通道 | myportal `config/`（不迁） |
| 大体积 jsonl 结果备份 | myportal `results/<node>/<run_id>/`；**冻结战役完整 raw** 亦在本仓见下 |
| 小体积 VERDICT 摘要 | 本仓 `reports/fail-slow-mohe/` |

## 冻结战役（改指南前参考）

**[`reports/fail-slow-mohe/20260724-first-tier-loud-d4/CAMPAIGN.md`](../../reports/fail-slow-mohe/20260724-first-tier-loud-d4/CAMPAIGN.md)**  
过程 + 参数 + 判分口径 + `raw/<run_id>/` 完整原始数据（约 40MB）。

## 成功锚点（Loud，2026-07-24）

| Case | 级别 | 结果摘要 |
|------|------|----------|
| P3-EXT-A | **D4** | `host_psi_cpu`；`…/20260724_090823-p3-live-d4e/` |
| P3-SW-A | **D4** | `cpu.utilization_rss`；`…/20260724_115002-p3swa-loud/` |
| P1-EXT-A | **D4** | `host_mx_smi_gpu_util`；`…/20260724_112745-p1exta-loud/` |
| P1-EXT-B | **D4** | `host_mx_smi_hbm_bw`（内联 HBM）；`…/20260724_124947-p1extb-loud/` |
| P3-EXT-B | 暂搁 | IO 未咬合；不进分母 |

集群 setup、代理、shm 门禁见 [`p3-d4-first-case-runbook.md`](p3-d4-first-case-runbook.md) §1 / §3；台账 [`ledger.md`](ledger.md)。
