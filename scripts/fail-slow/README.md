# Fail-Slow 编排脚本（真相源）

> **自 2026-07-24 起**：本目录为 Fail-Slow 可执行脚本的**唯一维护点**。  
> 旧路径 `lab-workspace/scripts/probing-failslow/` 仅保留兼容副本 + stub，**后续改这里**。

## 常用入口

| 脚本 | 用途 |
|------|------|
| `run_case_abc.sh` | 单 case C0/C1/C2 |
| `run_case_pipeline_v4.sh` | 底层管线（被 abc 调用） |
| `ensure_shm.sh` | 开训前 `/dev/shm` → 32G |
| `dump_probing_sql.sh` | C2 注入窗 Probing SQL + host PSI |
| `score_dlevel_offline.py` | 离线 D0–D3 |
| `score_dlevel_sql.py` | SQL / PSI → D4 |
| `dose_recipes.yaml` | 剂量配方 |
| `image/` | Probing_plus 镜像与 env（勿提交 `.cache/` wheel） |

## 从 myportal 会话调用示例

```bash
# 仓内路径（经 lab-workspace submodule）
HERE=project/lab-workspace/projects/probing-test/scripts/fail-slow
# 或本仓根：
# HERE=/path/to/probing-test/scripts/fail-slow

unset ALL_PROXY all_proxy
export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897
export NO_PROXY=127.0.0.1,localhost
export KUBECONFIG="$HOME/.kube/config-vc-c550-mohe-241.yaml"

PODS=yjr-fs-h14410,yjr-fs-h14411 bash "$HERE/ensure_shm.sh"
env -u PROBING -u PROBING_TORCH_PROFILING \
  CASE_ID=P3-EXT-A RUN_ID=$(date +%Y%m%d_%H%M%S)-p3 \
  PODS=yjr-fs-h14410,yjr-fs-h14411 \
  ITERS=500 ACCEPT_GATE=1 ENSURE_SHM=1 \
  bash "$HERE/run_case_abc.sh"
```

文档：[`../../docs/fail-slow/`](../../docs/fail-slow/)。
