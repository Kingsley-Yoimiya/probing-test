# 今晚双任务：SQL missing 修复 + 标准工作流（mohe-241）

> 日期：2026-07-23/24　落点：`scripts/fail-slow/`  
> 结果：`results/muxi-mohe/<run_id>/`　身份：`yinjinrun.p`　kube：`~/.kube/config-vc-c550-mohe-241.yaml`

## 目标（两条）

1. **修好 case / missing key**：C2 dump 能连上 probing，`SHOW TABLES` 成功；`cpu.utilization` / `python.torch_trace` 有表；再判 D3→D4。
2. **固化标准工作流**：门禁 → 环境/SQL → 单 case 冒烟 → 战役跑完 → 回拉/判分；并留下 handoff prompt + 提醒。

## 根因（已核实）

| 现象 | 根因 |
|---|---|
| 全部 `tables_missing` + `Connection refused` | `pip --target=pydeps` 的 `probing.pth` **不会**被 site 加载；`PROBING=2` 未挂上训练 worker |
| `gpu.utilization` 仍缺 | MetaX 上 `CudaBackend::try_load` 失败；硬塞 cu-bridge `libcuda` → cudarc 缺符号 **SIGSEGV** |
| C2 训练直接 SIGSEGV | `PROBING_TORCH_PROFILING=on` 在 import `torch.distributed.rpc` 时 Failed SET → nounwind panic；**默认必须 unset** |
| `process.gpu_users` / `process.cpu_stats` | 主线无表 → D4 EXT 证据仍可能 `SQL_NO_EXT_EVIDENCE`（如实记） |
| P1 Loud C1/C0≈1 | **已修（2026-07-24）**：见下方「P1 cube/hbm 咬合」；与 SQL attach 独立 |

## 修复点（代码）

- `train_bench_probe.py`：入口显式 `run_site_hook()`
- `image/install_env_to_pods.sh` + `Dockerfile`：site-packages 挂 `probing.pth` / 包软链
- `dump_probing_sql.sh`：多 PID 探测 attach；manifest 记 `attach=ok|no`
- `run_case_pipeline_v4.sh`：DUTY/SIZE 默认对齐 Loud；sidecar `python -u`

## 标准工作流（逐步）

### 0) 通道 / 身份门禁

```bash
unset ALL_PROXY all_proxy
export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897
export NO_PROXY=127.0.0.1,localhost
export KUBECONFIG=~/.kube/config-vc-c550-mohe-241.yaml
kubectl get pods -l app=yjr-fs 2>/dev/null | head
# 或已知 pod：
PODS=yjr-fs-h14410,yjr-fs-h14411
kubectl get pod yjr-fs-h14410 yjr-fs-h14411 -o wide
```

不盲目 re-setup；pod Running 再继续。

### 1) 环境（统一镜像等价灌装）

```bash
PODS=yjr-fs-h14410,yjr-fs-h14411 WHEEL=/tmp/probing-full.whl \
  bash scripts/fail-slow/image/install_env_to_pods.sh
```

验收：`python3 -c "import probing"`；`PROBING=2` 短进程可 `probing -t $PID query 'SHOW TABLES'` 看到 `cpu.utilization`。

### 2) 同步最新脚本到 pod

```bash
HERE=project/lab-workspace/projects/probing-test/scripts/fail-slow
for p in ${PODS//,/ }; do
  for f in train_bench_probe.py dump_probing_sql.sh sidecar_inject.py run_case_pipeline_v4.sh; do
    kubectl cp "$HERE/$f" "$p:/workspace/probe-bundle/$f"
  done
done
```

### 3) 清场（每战役前）

```bash
for p in ${PODS//,/ }; do
  kubectl exec "$p" -- bash -lc 'pkill -9 -f tbp.py; pkill -9 -f torchrun; pkill -9 -f sidecar_inject; pkill -9 stress-ng; true'
done
```

### 4) SQL 冒烟（只跑 C2，约 6–8 min）

```bash
RUN_ID=$(date +%Y%m%d_%H%M%S)-sql-attach-smoke
CASE_ID=P3-EXT-A PODS=$PODS RUN_ID=$RUN_ID \
  CONFIGS_ONLY=C2_probing DUMP_WAIT_S=40 SIDECAR_WARMUP=8 \
  bash scripts/fail-slow/run_case_abc.sh
# 查：
cat results/muxi-mohe/$RUN_ID/P3-EXT-A/**/probing/query_manifest.json
# 期望 attach=ok，cpu.utilization / python.torch_trace 至少有一个 present=true
```

门禁：`attach!=ok` → **停**，别开战役。

### 5) 注入冒烟（P1 Loud cube，C0+C1）

```bash
# 必须 ITERS≥500：SIDECAR_WARMUP=8s，ITERS=200 会在 warmup 未结束就收工 → C1/C0≈1
RUN_ID=$(date +%Y%m%d_%H%M%S)-cube-smoke
CASE_ID=P1-EXT-A PODS=$PODS RUN_ID=$RUN_ID ITERS=500 \
  ABC_CONFIGS=C0_baseline,C1_inject_none \
  INJECT_ARGS="duty=0.9,size=8192" SIDECAR_WARMUP=8 \
  bash scripts/fail-slow/run_case_abc.sh
# 期望 C1/C0 ≥ 1.8；injection.log 含 SIDECAR_START（不只 SIDECAR_WARMUP）
```

### 6) 全量 SQL-D4 战役

```bash
RUN_ID=$(date +%Y%m%d_%H%M%S)-failslow16-sql-d4
DUMP_WAIT_S=40 PODS=$PODS RUN_ID=$RUN_ID \
  bash scripts/fail-slow/campaign_sql_d4.sh
```

覆盖：Loud P1-EXT-A/B、P3-EXT-A + Quiet P1-EXT-B。  
完成后看 `VERDICT_SQL_*.md` 与各 case `probing/query_manifest.json`。

### 7) 剩余实验（战役后）

按 `dose_recipes.yaml` + SOP：Quiet 其余 PASS case、Masked 探测；Greyhound/XPUTimer 仍 ENV-BLOCKED。  
正式镜像：有 registry 写权限节点再 `image/build.sh`（ais 对 ccr-deeplink unauthorized）。

## 判读速查

| attach | cpu/torch | gpu.util | process.* | 含义 |
|---|---|---|---|---|
| no | — | — | — | hook 仍坏 |
| ok | yes | no | no | **今晚可接受基线**；D4 可能停在 SQL_NO_EXT_EVIDENCE |
| ok | yes | yes | yes | 理想 D4 路径 |

## P1 cube/hbm 咬合（2026-07-24 已修）

| 根因 | 说明 |
|---|---|
| MetaX sync 挂死 | warmup 无 sync 狂投核后 `torch.cuda.synchronize()` 与训练共卡会卡住 → 日志只有 `SIDECAR_WARMUP`、无 `SIDECAR_START` |
| 短 ITERS | 父 shell 残留 `ITERS=200` 时 inject 窗只有 ~14s，warmup=8s 未结束就收工 → 假阴性；战役须 **ITERS=500** |
| 过频 sync 冲压力 | 施压期每 50ms sync 虽能打出 START，但 C1/C0 仅 ~1.1；须异步投核才咬到 ≥1.8 |
| CUDA+MACA 双设 | sidecar 改为只用 `MACA_VISIBLE_DEVICES`，`env -u CUDA_VISIBLE_DEVICES` |
| pkill 自匹配 | `pkill -f sidecar_inject` 会误杀 `kubectl exec` 的 bash；改为 `[s]idecar_inject` |

修复落点：`sidecar_inject.py`（先打 START，施压默认不 sync）、`run_case_pipeline_v4.sh`（wait_sidecar_start / 清 shm / MACA-only）、`campaign_sql_d4.sh`（强制 ITERS≥500）。

冒烟（mohe-241，`yjr-fs-h14410/11`；h14410 曾因 CUDA SIGBUS 重建）：

| RUN_ID | case | C1/C0 | inj_log |
|---|---|---:|---|
| `20260724_072344-cube-fix` | P1-EXT-A cube | **2.60** ≥1.8 | warmup+start |
| `20260724_072813-hbm-fix` | P1-EXT-B hbm | **2.95** ≥1.6 | warmup+start |

## Handoff

见 `plans/handoff-probing-sql-d4.md`（下一会话直接粘贴的 prompt）。
