# Probing Fail-Slow 实验：落盘与脚本布局

> 日期：2026-07-23（2026-07-24 迁入 probing-test）  
> 顺序约定：**先 mohe-241 → 再 h3c-test**。做不到的 case 先跳过，不进本轮分母。  
> 仓内路径：`docs/fail-slow/` + `scripts/fail-slow/`；本机主备份仍在 **myportal** `results/<node>/<run_id>/`。  
> **例外（冻结战役）**：`reports/fail-slow-mohe/20260724-first-tier-loud-d4/raw/` 含完整 jsonl / probing，改指南前作参考。

---

## 1. 脚本（仓内真相源）

| 用途 | 路径 |
|---|---|
| 编排 / 训练 / 注入 / 回拉（从 `tmp/baseline-compare-bundle` 回收） | `scripts/fail-slow/` |
| 主入口（v4） | `…/run_case_pipeline_v4.sh` |
| privileged 起停 | `…/provision_priv_pods.sh` |
| 结果回拉 | `…/pull_campaign_results.sh` |
| 训练 microbench | `…/train_bench_probe.py` |
| sidecar 注入 | `…/sidecar_inject_v2.py` |
| 离线汇总 | `…/collect.py` |
| 剂量配方 | `…/dose_recipes.yaml` |
| Loud 验收 | `…/accept_loud.py` |
| 离线判分 | `…/score_dlevel_offline.py` |
| Loud2 / Quiet 战役 | `…/campaign_loud2.sh` / `campaign_quiet_pass3.sh` |

Case 定义 / 配方 / 检测：`OUTLINE` + `dose_recipes.yaml` + 探索冻结进 `scripts/fail-slow/`（**无** `cases/` 预写文档，见 ledger 维护纪律）。

---

## 2. 结果落点（开发机 + 仓内）

| 集群 | 本机 / 仓内备份 | 远端（若挂上 AFS） |
|---|---|---|
| mohe-241（先） | myportal `results/muxi-mohe/<run_id>/`；仓内冻结 raw 见 `reports/fail-slow-mohe/20260724-first-tier-loud-d4/raw/` | `/afs-a3-weight-share/yinjinrun.p/results/muxi-mohe/<run_id>/` |
| h3c-test（后） | `results/muxi-h3c/<run_id>/` | `/afs-a3-weight-share/yinjinrun.p/results/muxi-h3c/<run_id>/` |

`run_id` 带时间戳，例如 `20260724_153000-p1exta-loud-s42`。

每个 run 建议至少保留：

- `manifest.yaml`（节点、commit、剂量、seed、world_size）
- `training/*.jsonl`（step timing）
- `injection/ground_truth.yaml` + injector log
- `probing/` 或检测输出
- `verdict/`（判分）
- `system/env_snapshot.yaml`

历史批次（已有）：`results/muxi-h3c/20260723-27case/` 等。

---

## 3. AFS（weight-share）结论（2026-07-23 实测）

- 盘名：**`/afs-a3-weight-share`**（identity 里的 weight-share）。
- h3c 上已有 Bound PVC：`pvc-rmrnm`（`afs.endpoint=csi://019a90c2-2530-7e58-b47a-a86def77ad95`，secret `muxi-dev1`）。
- 生产 vcjob（如 `muxi-128node-*`）用**按作业下发的 PVC**挂同一 endpoint，**非 privileged**，可正常读写。
- 本轮对 **raw Pod**（privileged / 非 privileged 各一）显式挂 `pvc-rmrnm`：长时间 **Pending、无 Events**，随后对象消失；对照「无 PVC raw Pod」同样不稳定。  
  → **不是「privileged 单独禁挂」的清晰证据**；更像 **raw Pod + CSI 在 vcluster 路径不可靠**，而平台注入的 per-job PVC 才稳定。
- **执行策略（已拍板）**：fail-slow / privileged 战役 **不依赖 AFS**；结果写 pod 本地 → **立刻** `kubectl exec tar` / `pull_campaign_results.sh` 回拉到本机 `results/...`，并在仓内保留脚本与报告。频率复位 / 进程清理仍按既有 SOP。

---

## 4. 集群与身份速查

| 阶段 | shortcut | kubeconfig | 说明 |
|---|---|---|---|
| 先 | `muxi-local` | `~/.kube/config-vc-c550-mohe-241.yaml` | 128 卡面；空闲可能 <128 |
| 后 | `muxi-h3c` | `~/.kube/config-vc-c550-h3c-test.yaml` | 大池；128=16×8 |

身份：`yinjinrun.p`。本机 Clash `:7897`，`NO_PROXY=127.0.0.1,localhost`（勿留 `10/8`）。

---

## 5. 待他方 Agent 补全

见同目录 `docs/fail-slow/open-questions.md`。
