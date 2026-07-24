# Fail-Slow × Probing 实验（文档真相源）

> **自 2026-07-24 起**：本目录为 Fail-Slow 实验文档的**唯一维护点**。  
> Agent 运行时核心三份：`rules.md` + `ledger.md` + 论文侧 `OUTLINE`（见 myportal agent pack）。  
> 编排脚本：[`../../scripts/fail-slow/`](../../scripts/fail-slow/)。

## 文档索引（仅保留这些）

| 文件 | 用途 |
|------|------|
| [`rules.md`](rules.md) | **Skill / 方法论**：红线、控变、三阶段、D0–D5 |
| [`ledger.md`](ledger.md) | **台账**：门禁、平台 know-how、控制变量、已跑 case、baseline 状态 |
| [`decisions.md`](decisions.md) | 历史拍板（含 A5 D4 证据口径、删 `cases/`） |
| [`layout.md`](layout.md) | 落盘 / 路径约定 |

**已删除（勿再引用）**：`sop.md`、`cases/`、`open-questions.md`、各类 runbook / night-workflow / profiling-deep-dive——内容与 rules/ledger 冲突或重复，会误导 Agent。

> Case 故障定义 → 论文 `OUTLINE`；注入配方 → `scripts/fail-slow/dose_recipes.yaml`；检测方案 → 探索后冻结进 `scripts/fail-slow/`。

## 与 myportal 的分工

| 内容 | 落点 |
|------|------|
| 规则 / 台账 | **本仓** `docs/fail-slow/` |
| 编排 / 注入 / 判分 | **本仓** `scripts/fail-slow/` |
| 身份 / kube / vault | myportal `config/`（各自配置） |
| 结果备份 | myportal `results/<node>/<run_id>/` |
| 冻结战役 raw | `reports/fail-slow-mohe/20260724-first-tier-loud-d4/` |

## 成功锚点（Loud，2026-07-24）

| Case | 级别 | 证据 / run |
|------|------|------------|
| P3-EXT-A | **D4** | `host_psi_cpu`；`20260724_090823-p3-live-d4e`（复现 `…-p3exta-repro`） |
| P3-SW-A | **D4** | `cpu.utilization_rss`；`20260724_115002-p3swa-loud` |
| P1-EXT-A | **D4** | `host_mx_smi_gpu_util`；`20260724_112745-p1exta-loud` |
| P1-EXT-B | **D4** | `host_mx_smi_hbm_bw`；`20260724_124947-p1extb-loud` |
| P3-EXT-B | 暂搁 | IO 未咬合；不进分母 |

门禁与 know-how 一律见 [`ledger.md`](ledger.md)。
