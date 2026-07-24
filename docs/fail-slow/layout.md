# Fail-Slow 落盘与路径

> 方法论见 [`rules.md`](rules.md)；现状见 [`ledger.md`](ledger.md)。

## 1. 脚本真相源

目录：`scripts/fail-slow/`

| 用途 | 入口 |
|------|------|
| 单 case C0/C1/C2 | `run_case_abc.sh` → `run_case_pipeline_v4.sh` |
| `/dev/shm` | `ensure_shm.sh` |
| 剂量 | `dose_recipes.yaml` |
| C2 dump / 判分 | `dump_probing_sql.sh`、`score_dlevel_offline.py`、`score_dlevel_sql.py` |
| 注入 | `sidecar_inject.py`（管线默认）；`sidecar_inject_v2.py` 仅历史对照 |
| 镜像 / env | `image/` |

Case 定义 / 配方 / 检测：`OUTLINE` + `dose_recipes.yaml` + 探索冻结进 `scripts/fail-slow/`（**无**预写 `cases/`）。

## 2. 结果落点

| 集群 | 本机备份 | 远端（若挂 AFS） |
|------|----------|------------------|
| mohe-241 | myportal `results/muxi-mohe/<run_id>/` | `/afs-a3-weight-share/yinjinrun.p/results/muxi-mohe/<run_id>/` |
| h3c-test | myportal `results/muxi-h3c/<run_id>/` | 同上前缀 |

默认 **pod 本地落盘 → 立刻回拉**；不依赖 AFS。  
冻结战役 raw：`reports/fail-slow-mohe/20260724-first-tier-loud-d4/`。

## 3. 集群入口（身份各自配置）

| 阶段 | kubeconfig（示例） | 说明 |
|------|-------------------|------|
| 先 | `~/.kube/config-vc-c550-mohe-241.yaml` | mohe-241；现状实验 2×8=16 rank |
| 后 | h3c 对应 kube | 大池 |

身份默认 `yinjinrun.p`；细节在 myportal `config/`，不进本仓。
