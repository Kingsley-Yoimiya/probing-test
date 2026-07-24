# P1-SW-A（2A）+ P2-SW-C（5C）隔离战役

多 Agent 并行：本目录自带配方、训练副本与 pipeline 副本，**不改**共享 `run_case_abc.sh` / `dose_recipes.yaml`。

| 文件 | 用途 |
|------|------|
| `env.sh` | kube / pods / 64 卡 hold 默认 |
| `dose_recipes.yaml` | Loud/Quiet/Masked |
| `run_abc.sh` | 入口 → `pipeline_local.sh` |
| `pipeline_local.sh` | v4 隔离副本（含 2a / 5c） |
| `train_bench_probe_2a.py` | 显存碎片化→骤停内联注入 |
| `score_trend.py` | 2A 趋势型离线线索（gap / stall） |
| `baseline_notes.md` | 对手接入状态 |
| `install_baseline_libs.sh` | Greyhound/XPUTimer stub .so |

OUTLINE：`2A` 显存碎片化→骤停；`5C` 拓扑映射漂移（错误 HCA 序 + P2P disable）。

资源：`POD_PREFIX=yjr-p1swa`，weibozhen.p 访问，落盘 `yinjinrun.p` → `results/muxi-h3c/<run_id>/`。
