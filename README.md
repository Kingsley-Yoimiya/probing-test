# probing-test

Probing 相关实验与验证仓（GitHub: `Kingsley-Yoimiya/probing-test`）。

经 myportal 挂载：`project/lab-workspace/projects/probing-test`（lab-workspace submodule）。  
也可在 myportal `project/registry.yaml` 登记直链后使用 `project/probing-test`。

## 两条线

| 线 | 目录 | 说明 |
|----|------|------|
| **Fail-Slow × Probing（主线，2026-07 起）** | [`docs/fail-slow/`](docs/fail-slow/) · [`scripts/fail-slow/`](scripts/fail-slow/) | 27 格注入 case、SOP、D4 判分、mohe 战役 |
| Megatron / 可视化矩阵（既有） | [`experiment-plan.md`](experiment-plan.md) · [`scripts/`](scripts/) · [`docs/`](docs/) | Megatron TC、Web 素材、旧 demo |

**后续 Fail-Slow 文档与脚本只改本仓**；myportal `plans/` 与 `lab-workspace/scripts/probing-failslow/` 为入口 / 兼容指针。

## Fail-Slow 快速入口

- 文档索引：[`docs/fail-slow/README.md`](docs/fail-slow/README.md)
- 首个 D4 跑通实录：[`docs/fail-slow/p3-d4-first-case-runbook.md`](docs/fail-slow/p3-d4-first-case-runbook.md)
- 脚本：[`scripts/fail-slow/README.md`](scripts/fail-slow/README.md)
- 摘要报告：[`reports/fail-slow-mohe/`](reports/fail-slow-mohe/)

身份 / kube / 代理仍以 myportal `config/` 为准，不进本仓。
