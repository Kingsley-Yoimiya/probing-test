# 战役检查点：P1-HW-B / P3-SW-C（集群中断时冻结）

> 时间：2026-07-24 ~19:25 CST  
> 原因：vc-c550-h3c-test / kubectl 路径中断；本机结果与隔离代码已落盘。  
> 恢复后再开干，以本文件 + `cases/p1hwb_p3swc/` 为准。

---

## 1. 环境与资源（已拍板）

| 项 | 值 |
|---|---|
| 集群 | `vc-c550-h3c-test`（1024 卡面） |
| kube | **借用** `weibozhen.p`（`~/.kube/config-vc-c550-h3c-test-weibozhen.yaml`） |
| 落盘身份 | **yinjinrun.p**（本机 `results/muxi-h3c/`；AFS `/afs-a3-weight-share/yinjinrun.p/`） |
| 实验 pods | `yjr-1b8c-h144147,149,152,154,157,159,160,162`（前缀隔离，避开 `yjr-fs64-*` / `yjr-swb-*`） |
| 节点 | host-10-12-144-{147,149,152,154,157,159,160,162} |
| reserve（只记账） | host-10-12-144-164,165 |
| world | **8×8 = 64 rank** |
| 镜像/环境 | megatron-lm maca 底包 + Probing_plus **0.2.5**（md5 `fe3b76db…`） |
| shm | 64G |
| 训练固定 | GPT-2 124M，batch=8，seq=1024，bf16，seed=42，ITERS=500，warmup=50，victim local_rank=7 |

---

## 2. 代码落点（隔离，已保存）

真相目录（仓内，勿与并行 Agent 抢共享脚本）：

`project/probing-test/scripts/fail-slow/cases/p1hwb_p3swc/`

| 文件 | 用途 |
|---|---|
| `run_abc.sh` | 本战役入口（P1-HW-B / P3-SW-C） |
| `run_case_pipeline_v4_retry.sh` | 共享 v4 副本 + **发射重试**（防 7/8 rendezvous） |
| `train_bench_probe_1b_ramp.py` | OUTLINE 1B：窗内 copies **6→48** 渐进 inline HBM |
| `sidecar_inject_v2_8c_loud.py` | OUTLINE 8C Loud：8MB/0.2s + 线程 + 短忙等 |
| `dose_recipes.yaml` | 本战役剂量（未改共享 dose） |
| `registry_fragment.txt` | 纠正 `P1-HW-B\|1b`（共享 campaign 误写 freq） |
| `baseline_notes.md` | 对手接入 + Dynolog oracle 协议 |
| `freeze_*.md` / `score_*.py` / `LEDGER_PATCH.md` | 冻结草案与台账补丁 |

本机归档副本：

`results/muxi-h3c/20260724_campaign-p1hwb-p3swc-checkpoint/code_snapshot/`  
（含 `CODE_SHA256` 见 formal 目录；另有本地 `libmcclprobe.so` / `libxpu_timer_metax.so` 若当时拉到 `/tmp`）

**未改（或刻意少改）共享**：`run_case_abc.sh`、`dose_recipes.yaml`、`run_campaign.sh`——避免并行冲突。

---

## 3. 全局小参数（注入 / 门闩）

### P1-HW-B（OUTLINE 1B）

| 参数 | 值 | 备注 |
|---|---|---|
| 名义 inject_kind | `1b` | OUTLINE 显存带宽渐进 |
| 实际执行 | `hbm` + **渐进 inline** | 外挂 v2 与 pipeline `SIDECAR_START`/injection.log 约定不齐；MetaX 外挂 HBM 亦有咬空先例 |
| INLINE_HBM_MB | 512 | |
| INLINE_HBM_COPIES | 6 | 窗起点 |
| INLINE_HBM_COPIES_MAX | 48 | 窗终点（线性） |
| inject 窗 | measure [100,300]（全局 step 150–350） | |
| MODE | gpu_bound | |
| Loud 阈值 | C1/C0 ≥ 1.3 | |

### P3-SW-C（OUTLINE 8C）

| 参数 | 值 | 备注 |
|---|---|---|
| inject_kind | `8c` | 监控泄漏 |
| sidecar | 隔离 `8c_loud`（覆盖 pod 上 v2） | 默认 1MB/3s 太弱 |
| MODE | **host_bound** | 必须 |
| 状态 | C0 曾跑通；C1 因 **7/8 节点发射** rendezvous 超时失败；pilot2 在 C0 warmup 后集群中断 | 尚无 Loud PASS |

### 对手

| Config | 工具 | 状态 |
|---|---|---|
| C3 | Greyhound `libmcclprobe.so` | 已扇出；formal **跑完**（有 jsonl） |
| C4 | XPUTimer MetaX hook（g++ 直编 65KB） | .so 有；formal **FAILED**（无 rank jsonl）→ PENDING |
| C5 | Flight Recorder env | formal 日志 COMPLETE；本机 master 侧 rank0 jsonl 需核对（部分 pod 有 log） |
| Dynolog | 未进 CONFIGS | oracle 协议已写；未跑 |

---

## 4. 已得到的结果（本机可复现数字）

### 4.1 P1-HW-B Loud pilot（咬合）

- run_id: `20260724_180014-p1hwb-loud-ramp`
- C0 median step_ms ≈ **102.56**
- C1 median step_ms ≈ **138.19**
- **C1/C0 = 1.347 → PASS**（≥1.3）

### 4.2 P1-HW-B Loud formal（64 卡，主结果）

- run_id: `20260724_180721-p1hwb-loud-formal`
- 本机备份 ≈ **45MB**（`results/muxi-h3c/20260724_180721-p1hwb-loud-formal/`）

| config | 状态 | median step_ms (rank0 窗) | vs C0 |
|---|---|---:|---:|
| C0_baseline | COMPLETE | 102.27 | 1.00 |
| C1_inject_none | COMPLETE | 140.34 | **1.37** |
| C2_probing | COMPLETE + SQL dump | 137.55 | 1.35 |
| C3_greyhound | COMPLETE | （未单独验收表） | — |
| C4_xputimer | **FAILED** | 无 jsonl | PENDING |
| C5_flight_recorder | COMPLETE（日志） | 本机 rank0 路径需再扫 | — |

验收：`acceptance_P1-HW-B.md` → **PASS**；`VERDICT.md` 已写。

C2 旁路证据（victim 卡 7）：`host_gpu.json` 记到 `hbm_bw_mbs≈608456`、`gpu_util_pct=82`；脚本当时 `evidence=host_mx_smi_unused`（阈值逻辑需恢复后复核，**不**据此单独抬 D4）。

### 4.3 P3-SW-C

| run_id | 阶段 | 结果 |
|---|---|---|
| `20260724_185509-p3swc-loud-pilot` | C0 OK；C1 FAILED | DistStore **7/8 clients** 超时；已回拉部分 C0 |
| `20260724_192038-p3swc-loud-pilot2` | C0 fired + warmup ok | **集群中断**，无完整回拉 |

→ P3-SW-C **尚无** Loud C1/C0 数字。

---

## 5. 平台踩坑（恢复后优先处理）

1. 外挂 `sidecar_inject_v2 --case 1b` 打 `SIDECAR_1B_START`，共享 pipeline 等 `SIDECAR_START` + `injection.log` → 本战役改用隔离渐进 inline。  
2. 8 节点并行 `kubectl exec` 偶发只成功 7 台 → `run_case_pipeline_v4_retry.sh`。  
3. XPUTimer MetaX `.so` 单机可编，64 卡 LD_PRELOAD formal 挂死 → PENDING，勿急标 ENV-BLOCKED。  
4. 多 Agent 并行：只用 `yjr-1b8c-*` 与 `cases/p1hwb_p3swc/`，勿抢 `yjr-fs64-*`。

---

## 6. 恢复后建议顺序

1. `kubectl auth whoami` + ping 8 pods；必要时重建同前缀 pod。  
2. 确认隔离代码仍在 / 从 `code_snapshot` 再同步。  
3. **先补完 P3-SW-C**：Loud C0/C1（retry pipeline + 8c_loud）→ 正式 C0–C5。  
4. 回补 P1：C4 重试或记清 PENDING；C5/C3 离线判分；可选 Dynolog oracle 短窗。  
5. 合并 `LEDGER_PATCH.md` 进共享 ledger（人工合，避冲突）。
