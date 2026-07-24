# P1C 64 卡战役中断快照（2026-07-24 ~19:25）

> 集群突然中断后本地存档。恢复后从本文件 + overlay 代码续跑。  
> **未跑**：P1-EXT-C（3c）；P1-SW-C 的 C3/C4/C5 对手线未完整产出。

## 1. 资源与环境参数

| 项 | 值 |
|---|---|
| 集群 | vc-c550-h3c-test（1024 卡池） |
| kube | `~/.kube/config-vc-c550-h3c-test-weibozhen.yaml`（借 weibozhen.p 访问） |
| 落盘归属 | yinjinrun.p；本机 `results/muxi-h3c/<run_id>/` |
| 规模 | `NNODES=8 NPROC=8` → **world=64** |
| Pod 前缀 | `yjr-p1c64`（与 `yjr-fs64` / 其它 Agent 隔离） |
| Pods CSV | `yjr-p1c64-h144164,h144165,h144166,h144167,h144193,h144195,h144196,h144197` |
| Nodes | `host-10-12-144-{164,165,166,167,193,195,196,197}` |
| 供给 run | `20260724_172457-p1c64`（`PULL_SECRET=megatronmuxi`） |
| 镜像 | megatron-lm maca.ai3.3.0.11 torch2.6 py312 |
| shm | 已 `ensure_shm` → **/dev/shm=32G** |
| Probing | wheel MD5 `fe3b76db…`（0.2.5 full）经 `install_env_to_pods.sh` |
| Baseline .so | 本批 pod 内编译 stub：`greyhound/libmcclprobe.so`、`xputimer/libxpu_timer_metax.so` |
| Dynolog | 未接入（管线无 C6）；备注见 overlay `NOTES_DYNOLOG.md` |

### 训练全局固定（沿用 ledger §2.1）

- 模型 GPT-2 124M，batch=8，seq=1024，bf16，seed=42  
- warmup=50，正式 iters=500（pilot 曾用 400）  
- mode=`gpu_bound`，victim `local_rank=7`（node0）  
- 注入窗 measure `[100,300]`（全局约 step 150–350）

## 2. 隔离代码落点（已写盘，勿丢）

路径：`project/probing-test/scripts/fail-slow/agent_overlays/p1c-20260724/`

| 文件 | 作用 |
|---|---|
| `run_p1c.sh` | CASE→2c/3c；同步 overlay；C0–C5；SKIP_SYNC；P1-SW-C 用 tip 验收闸门 |
| `pipeline_p1c.sh` | 从 v4 fork：2c INLINE、3c→injection.log、wait_done heal、pgrep 修 |
| `train_bench_p1c.py` | `INLINE_INJECT=2c`：compile one-shot + fallback sleep |
| `sidecar_inject_p1c.py` | 3c/2c 打 `SIDECAR_START`；3c 默认 6×4096 |
| `accept_p1swc_spike.py` | tip 验收：victim max≥2.5 或 p99≥1.5 或 median≥1.3 |
| `install_baseline_libs.sh` | Greyhound/XPUTimer stub |
| `NOTES_DYNOLOG.md` | Dynolog 后续窗 |

git：`probing-test` 下为 **未跟踪** `?? scripts/fail-slow/agent_overlays/p1c-20260724/`（本快照时）。

本机额外备份：`results/muxi-h3c/_p1c_overlay_backup_20260724/`（见下）。

## 3. 关键小参数（调参轨迹）

| 旋钮 | 试过的值 | 备注 |
|---|---|---|
| `INLINE_2C_N` | 1536 → 2048 → **1024** | 过大时 64 卡易 MCCL/teardown 炸 |
| `INLINE_2C_EVERY` | 1（每步） | Loud；与 OUTLINE one-shot 不同，属剂量近似 |
| `INLINE_2C_FALLBACK_S` | **0.2** | MetaX `torch.compile` 失败时 sleep 保咬合 |
| tip 闸门 max | 3.0 → **2.5** | 正式轮曾 2.88 差一截 |
| tip 闸门 p99 | 2.0 → **1.5** | |
| `ACCEPT_GATE` | 1（pilot）/ **0**（强制跑对手） | |
| `SIDECAR_3C_NPROC/MAT` | 6 / 4096 | **尚未实跑** P1-EXT-C |
| wait_done | 原 900s → overlay heal≤360s | 补 done/fail 防拆连接挂死 |

## 4. 各 run 结果一览

### 4.1 有效咬合锚点（推荐保留）

**`results/muxi-h3c/20260724_175045-p1swc-bite/`**（ITERS=400，INLINE 2c）

- C0/C1 齐；`BITE_OK.txt`  
- victim rank7：**max C1/C0 = 2510/775 ≈ 3.24** → spike **PASS**  
- rank0 median C1/C0 ≈ **0.99**（符合 2C「median 盲、尖刺可见」叙事）  
- injection.log：`warmup+start`（inline 假日志）

**`results/muxi-h3c/20260724_180420-p1swc-loud/`**（ITERS=500）

- C0/C1 齐；spike 重判 **BITE_OK**（max≈2.88≥2.5）  
- 当时 `ACCEPT_GATE=1` + 旧阈值 3.0 → 曾误标 ineffective 并跳过 C2+  
- **无 C2–C5**

### 4.2 早期无效 sidecar pilot

**`20260724_174128-p1swc-pilot`**：外挂 `2c` 未进 `injection.log` / 训练无 compile → median≈1.0，无效。

### 4.3 中断时正在跑的正式轮

**`results/muxi-h3c/20260724_190026-p1swc-loud/`**

| config | 日志态 | 数据可信度 |
|---|---|---|
| C0_baseline | COMPLETE rc=0 | **可信**（jsonl `run_id=20260724_190026-p1swc-loud`） |
| C1_inject_none | COMPLETE rc=0 | **不可信混入**：jsonl 内 `run_id=20260724_180420-p1swc-loud`（pod 旧目录未清干净被回拉） |
| C2_probing | COMPLETE rc=0 | 可疑：`SQL dump skipped: training not running`；需核 jsonl run_id |
| C3_greyhound | **未开始/中断** | — |
| C4_xputimer | 未开始 | — |
| C5_flight_recorder | 未开始 | — |

### 4.4 P1-EXT-C

**未启动**（按计划应在 P1-SW-C 含对手完成后）。

## 5. 已验证的工程结论（恢复后有用）

1. **16→64**：pipeline v4/overlay 环境变量即可；不必改公共硬编码。  
2. **占卡**：严格空闲整机 + `PULL_SECRET=megatronmuxi`；曾与 `yjr-1b8c` 抢节点失败一次。  
3. **公共 `2c` sidecar 不能咬 GPT-2 无 compile 的训练** → 必须 INLINE（overlay `train_bench_p1c.py`）。  
4. **2C 验收应用 tip（max/p99）**，不能只用 rank0 median。  
5. **MetaX 64 卡 teardown** 常不落 `node_*.done` → overlay `wait_done` heal 必要。  
6. **回拉前必须清 pod `out/<CASE>`**，否则会污染后续 run_id（本次 C1 已中招）。  
7. 对手 stub `.so` 已就位；真 Greyhound/XPUTimer/Dynolog 能力仍待接入。

## 6. 恢复后建议续跑顺序

1. `kubectl` 探活；确认 `yjr-p1c64-*` 是否还在，否则按 §1 重占 8 整机。  
2. `SKIP_SYNC=0` 重铺 overlay；**先删**各 pod `/workspace/probe-bundle/out/P1-SW-C`。  
3. 重跑 P1-SW-C 全量 `C0–C5`（`ACCEPT_GATE=0` 或 tip 闸门 2.5），新 `run_id`。  
4. 再跑 P1-EXT-C `INJECT_KIND=3c`。  
5. Dynolog 单独开窗（见 `NOTES_DYNOLOG.md`）。

## 7. 本机路径速查

```text
project/probing-test/scripts/fail-slow/agent_overlays/p1c-20260724/
results/muxi-h3c/20260724_175045-p1swc-bite/          # 最佳 tip 锚点
results/muxi-h3c/20260724_180420-p1swc-loud/           # 正式 C0/C1 tip OK
results/muxi-h3c/20260724_190026-p1swc-loud/           # 中断轮（C0 可信；C1 污染）
results/muxi-h3c/_p1c_overlay_backup_20260724/        # 代码备份
/tmp/p1c_pods.csv /tmp/p1c_nodes.txt
```
