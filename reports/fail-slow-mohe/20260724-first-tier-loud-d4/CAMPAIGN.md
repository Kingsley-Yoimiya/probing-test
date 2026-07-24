# 第一梯队 Loud → D4 战役归档（2026-07-24，mohe-241）

> **用途**：SOP / 操作指南改版前的**冻结参考**。含过程、参数、判分口径与原始数据指针。  
> **仓内落点**：本目录；原始 run 在 `raw/<run_id>/`。  
> **本机主备份**（同内容）：`myportal/results/muxi-mohe/<run_id>/`。

---

## 0. 一句话结论

| Case | 格 | 锚点 run_id | C1/C0 | SQL/D4 | 证据 |
|---|---|---|---:|---|---|
| P3-EXT-A | 9A | `20260724_090823-p3-live-d4e` | ~2.97 | **D4** | `host_psi_cpu` |
| P3-SW-A | 8A | `20260724_115002-p3swa-loud` | 2.17 | **D4** | `cpu.utilization_rss` |
| P1-EXT-A | 3A | `20260724_112745-p1exta-loud` | 3.78 | **D4** | `host_mx_smi_gpu_util` |
| P1-EXT-B | 3B | `20260724_124947-p1extb-loud` | 1.74 | **D4** | `host_mx_smi_hbm_bw` |
| P3-EXT-B | 9B | `20260724_104828-p3extb-bite5` 等 | — | **暂搁** | IO 未咬进 `step_ms` |

**4/5 Loud 到 D4**；9B 不进分母。

---

## 1. 环境与控制变量（本战役固定）

| 项 | 值 |
|---|---|
| 集群 | mohe-241（`config-vc-c550-mohe-241.yaml`） |
| 身份 | `yinjinrun.p` |
| Pods | `yjr-fs-h14410` + `yjr-fs-h14411`（2×8=16 rank） |
| 代理 | Clash `:7897`；`NO_PROXY=127.0.0.1,localhost`；**unset** `ALL_PROXY` |
| `/dev/shm` | **32G**（`ensure_shm.sh`；禁训练中途 remount） |
| 模型 | GPT-2 124M，bf16，batch=8，seq=1024，seed=42 |
| iters / warmup | 500 / 50；注入窗 measure step **[100, 300]** |
| victim | local_rank **7** |
| Probing | Probing_plus **0.2.5**（gpu+mx-smi）；C0/C1 `unset PROBING`；C2 挂 probing |
| 禁 | 默认 `PROBING_TORCH_PROFILING=on`；cu-bridge `libcuda`；裸 `pgrep -n` |

脚本真相源（本战役已同步进仓）：`scripts/fail-slow/`  
配方快照：`params/dose_recipes.yaml`

---

## 2. 跑法（串行 SOP：Pilot → 固化 → 正式 Loud）

同一对 pod，**禁止并行 subagent 抢卡**。每 case：

1. **Pilot 咬合**：`ABC_CONFIGS=C0_baseline,C1_inject_none` + `ACCEPT_GATE=1`  
2. **固化**：改注入/dump/score，直到 C1/C0 ≥ 门槛  
3. **正式 Loud**：全量 C0/C1/C2 → `score_dlevel_offline.py` + `score_dlevel_sql.py`

主入口：

```bash
export KUBECONFIG=$HOME/.kube/config-vc-c550-mohe-241.yaml
export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897
export NO_PROXY=127.0.0.1,localhost
unset ALL_PROXY ABC_CONFIGS
HERE=scripts/fail-slow   # 在 probing-test 仓内
PODS=yjr-fs-h14410,yjr-fs-h14411
bash "$HERE/ensure_shm.sh"
# CASE_ID=… RUN_ID=… ITERS=500 WARMUP=50 ENSURE_SHM=1 ACCEPT_GATE=1 \
#   bash "$HERE/run_case_abc.sh"
```

回拉若 `kubectl cp` tar 截断：用流式  
`kubectl exec $p -- tar -C <remote> -cf - . | tar -C <local> -xf -`。

---

## 3. 各 case 过程与参数

### 3.1 P3-EXT-A（9A）— 首个 D4

| 项 | 值 |
|---|---|
| 注入 | `stress_cpu`，`cpu_load=90`，host_bound |
| 门槛 | C1/C0 ≥ 1.3 |
| 卡点 | SQL `cpu.tasks` 只见本进程，见不到 host `stress-ng` |
| 固化 | dump 同窗 `/proc/pressure/cpu` → `host_pressure.json`；score 认 `host_psi_cpu` |
| 锚点 | `raw/20260724_090823-p3-live-d4e/` |
| 证据 | `host_psi_cpu`（rate ≥ 2e5 us/s 量级） |

### 3.2 P3-SW-A（8A）

| 项 | 值 |
|---|---|
| 注入 | **内联** `INLINE_INJECT=8a`（外挂 GC 咬不到） |
| Loud 剂量 | 窗内每步 leak 4MiB + `gc.collect` + **stall 0.25s**（`INLINE_GC_EVERY=1`） |
| 门槛 | C1/C0 ≥ 1.3 |
| Pilot | `113721` C1/C0=0.89 无效 → 加强 STW |
| bite2 | `114257` C1/C0=**3.15** PASS → D3 |
| Loud | `115002` C1/C0=**2.17** → **D4** |
| 证据 | `cpu.utilization` 进程 `rss_kb` ≥ 700000（`cpu.utilization_rss`） |

### 3.3 P1-EXT-A（3A）

| 项 | 值 |
|---|---|
| 注入 | sidecar `cube`，`duty=0.9,size=8192`（矩阵边长），gpu_bound |
| 门槛 | C1/C0 ≥ 1.8 |
| Loud | `112745` C1/C0=**3.78**，离线 D3 |
| 卡点 | MetaX CudaBackend 起不来 → 无 `gpu.utilization` / `process.gpu_users` |
| 固化 | dump 同窗 `mx-smi -i7 --show-usage` → `host_gpu.json` |
| 补 C2 | 同 run 重跑 C2 + host_gpu → **D4** `host_mx_smi_gpu_util`（util=99%） |

### 3.4 P1-EXT-B（3B）

| 项 | 值 |
|---|---|
| 注入（终态） | **内联** `INLINE_INJECT=hbm`，`INLINE_HBM_MB=512`，`INLINE_HBM_COPIES=48` |
| 门槛 | C1/C0 ≥ 1.6 |
| 外挂 sidecar | 多轮咬空（size=8192MB 误用 / 多流 queue 超时 / 单流仍 C1/C0≈1.0）→ 放弃 |
| bite5 | `124504` C1/C0≈1.597（临界）→ Loud 用 copies=48 |
| Loud | `124947` C1/C0=**1.74**，离线 D3 |
| 固化 | 同窗 `mx-smi --show-hbm-bandwidth` → **D4** `host_mx_smi_hbm_bw`（≈6.4e5 MB/s） |

### 3.5 P3-EXT-B（9B）— 暂搁

| 项 | 值 |
|---|---|
| 注入 | `stress_io`（fio）+ ckpt/io-payload 尝试 |
| 结果 | bite 多轮 `injection_ineffective` 或 NCCL/超时；**不进分母** |
| 证据留存 | `raw/20260724_104828-p3extb-bite5/`（含 `PILOT_VERDICT.md`） |

---

## 4. D4 判分口径（本战役拍板）

| Case 族 | 主证据（禁止 injection.log / 裸 pgrep） |
|---|---|
| P3-EXT | SQL stress 优先；否则 **`host_psi_cpu` / `host_psi_io`** |
| P3-SW | **`cpu.utilization_rss`** |
| P1-EXT | SQL `process.gpu_users` / `gpu.utilization` 优先；MetaX 缺表时 **`host_gpu.json`（mx-smi）** |

见 `docs/fail-slow/decisions.md` A5 附注（2026-07-24）。

---

## 5. 原始数据索引

| 路径 | 内容 |
|---|---|
| `raw/<run_id>/` | 完整回拉：ranks jsonl、C2 `probing/`、logs、acceptance、VERDICT |
| `verdicts/` | 各 run 判分 md 副本 |
| `params/dose_recipes.yaml` | 本战役配方快照 |
| `SUMMARY.md` | 一页表 |

关键文件（每 D4 run 内）：

- `VERDICT_SQL_Loud.md` / `scoring_table_SQL_Loud.csv`
- `acceptance_<CASE>.md`
- `*/round_1/C2_probing/probing/{query_manifest.json,host_pressure.json\|host_gpu.json}`
- `*/round_1/{C0,C1,C2}/ranks/rank_*.jsonl`

---

## 6. 后续改指南时注意

1. **P1-EXT-B 正式路径是内联 HBM**，不是外挂 sidecar（MetaX 外挂带宽争用失效）。  
2. **P1 D4 依赖 mx-smi 旁路**，勿假定 `gpu.utilization` 表可用。  
3. **shm=32G + unset ALL_PROXY** 为硬门禁。  
4. 改全局控制变量（§1）会使本归档 run **不可比**——需新战役重跑。  
5. 9B 复测需先重做「计时内 IO」咬合，再谈 D4。

---

## 7. 脚本 / commit 快照

见 `params/probing-test-git-head.txt`、`params/lab-workspace-git-head.txt`（归档当时 HEAD）。  
本战役相对旧脚本的关键 diff：`dump_probing_sql.sh`（host_gpu）、`score_dlevel_sql.py`（P1/P3-SW 旁路）、`train_bench_probe.py`（inline 8a/hbm）、`run_case_pipeline_v4.sh`、`dose_recipes.yaml`。
