# mohe Fail-Slow 报告与原始归档

## 冻结战役（改指南前必读）

**[`20260724-first-tier-loud-d4/`](./20260724-first-tier-loud-d4/)** — 2026-07-24 第一梯队 Loud→D4

| 文件 | 说明 |
|---|---|
| [`CAMPAIGN.md`](./20260724-first-tier-loud-d4/CAMPAIGN.md) | 全过程 / 参数 / 判分口径 |
| [`MANIFEST.yaml`](./20260724-first-tier-loud-d4/MANIFEST.yaml) | 机器可读摘要 |
| [`SUMMARY.md`](./20260724-first-tier-loud-d4/SUMMARY.md) | 一页结果表 |
| `raw/<run_id>/` | **完整原始数据**（jsonl + probing dump + logs） |
| `params/` | `dose_recipes.yaml` 与 git HEAD 快照 |
| `verdicts/` | 判分 md 副本 |

| case | run_id | D |
|---|---|---|
| P3-EXT-A | `20260724_090823-p3-live-d4e` | **D4** |
| P3-SW-A | `20260724_115002-p3swa-loud` | **D4** |
| P1-EXT-A | `20260724_112745-p1exta-loud` | **D4** |
| P1-EXT-B | `20260724_124947-p1extb-loud` | **D4** |
| P3-EXT-B | `20260724_104828-p3extb-bite5` | 暂搁 |

本机镜像：`myportal/results/muxi-mohe/<run_id>/`。  
文档：[`../../docs/fail-slow/`](../../docs/fail-slow/)。

## 轻量 VERDICT 槽（历史）

各 `YYYYMMDD_*-*/` 目录下仅 `.md` / `.csv` / `run.txt`（早期约定）；**完整 raw 以 `20260724-first-tier-loud-d4/raw/` 为准**。
