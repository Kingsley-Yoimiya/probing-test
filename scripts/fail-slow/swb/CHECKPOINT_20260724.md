# SW-B 集群中断检查点（2026-07-24 ~19:25 CST）

> 集群侧作业中断；本文件冻结参数与已得结果，供恢复后续跑。  
> 代码隔离目录：`project/probing-test/scripts/fail-slow/swb/`  
> 本机结果：`results/muxi-h3c/20260724_171825-swb64*`

## 1. 环境与身份

| 项 | 值 |
|---|---|
| 集群 | vc-c550-h3c-test |
| kube 进门 | `weibozhen.p` → `~/.kube/config-vc-c550-h3c-test-weibozhen.yaml` |
| 落盘 | `yinjinrun.p`；本机 `results/muxi-h3c/`；pod AFS 不写他人前缀 |
| 规模 | 8 节点 × 8 卡 = **64 rank**（DDP，未开 FSDP） |
| Pod 前缀 | `yjr-swb`（勿碰其它 Agent 的 `yjr-fs64-*`） |
| Pods | `yjr-swb-h145231,h145230,h144222,h145219,h144217,h145217,h145216,h144215` |
| Nodes | host-10-12-145-231/230,144-222,145-219,144-217,145-217/216,144-215 |
| 代码根（pod） | `/workspace/probe-bundle/swb` |
| Probing | **0.2.5**（MD5 `fe3b76db…`），装在 `…/swb/pydeps` |
| shm | 32G |
| 训练 | GPT-2 124M，`mode=gpu_bound`，`seq=1024`，`batch=8` |
| 迭代 | `ITERS=350`，`WARMUP=50`；注入窗 measure step **[100,300]** |
| victim | node0 local_rank **7**（sidecar_local_rank=7） |

## 2. Case 配方（剂量）

### P2-SW-B（OUTLINE 5B / MCCL 通道钳制）— **主结果已冻结**

| 项 | 值 |
|---|---|
| `INJECT_KIND` | `mccl_algo` |
| Loud args | `algo=Ring,proto=Simple,min_ch=4,max_ch=4` |
| C0 | 默认 MCCL + **`MCCL_STRESS_MB=512`**（同开大 AllReduce） |
| C1/C2 | 同上 stress + `MCCL_ALGO=Ring` `MCCL_PROTO=Simple` `MCCL_MIN/MAX_NCHANNELS=4` |
| Quiet / Masked（未正式跑） | ch=8 / ch=16，见 `dose_swb.yaml` |
| 正式 RUN_ID | `20260724_171825-swb64-p2-s512` |

### P1-SW-B（OUTLINE 2B / rare shape）— **中断于 C0**

| 项 | 值 |
|---|---|
| `INJECT_KIND` | `rare_shape` → `INLINE_INJECT=2b` |
| Loud args | `rare_seq=1536,every=1` |
| RUN_ID | `20260724_171825-swb64-p1` |
| 中断点 | C0 已 `fired` + `warmup ok`；**本机无 rank 回拉**；编排已停 |

## 3. 中间小参数扫（P2 Loud 爬坡）

| 轮次 | RUN / 目录 | stress | 本机 rank C0/C1/C2 | step_ratio | comm_ratio | 备注 |
|---|---|---|---|---|---|---|
| 无 stress / loud | `…-p2-loud` | 0（comm~0） | 64 / 56 / 16 | **1.023** | **1.0** | 计算主导，咬不动 |
| stress=64 | `…-p2-bite2` | 64 | 56 / 48 / ? | **1.040** | **1.271** | 通道开始见效 |
| **stress=512（正式）** | `…-p2-s512` | **512** | **64 / 56 / 64** | **1.132** | **1.688** | 冻结验收轮 |

冻结判分（master 8 文件窗，与全量本地重算一致到小数点后 3 位）：

- 窗 `[100,300]` 中位：C0 step **113.98** / comm **18.43**；C1 step **129.05** / comm **31.08**
- `loud_step_met=false`（目标 1.15）；主证 = 标定 **2.13** + `comm_ratio≈1.69`

## 4. MCCL 带宽标定（64 卡 AllReduce 64MiB）

| 配置 | bus_bw GB/s | ms/iter |
|---|---|---|
| default | **61.85** | 2.14 |
| Ring/Simple ch=4 | **29.03** | 4.55 |
| ratio | **2.13**（fabric 参考 ~2.14） | |

落点：`results/muxi-h3c/20260724_171825-swb64/mccl_calibrate/`

## 5. 本机产物清单

| 路径 | 内容 |
|---|---|
| `results/muxi-h3c/20260724_171825-swb64/mccl_calibrate/` | 标定 json + log |
| `results/muxi-h3c/20260724_171825-swb64-p2-s512/verdict_ratio.json` | 冻结 verdict |
| `…-p2-s512/P2-SW-B/round_1/{C0,C1,C2}/ranks/` | jsonl（C1 缺 8 个 rank=1 节点） |
| `…-p2-s512/P2-SW-B/round_1/C2_probing/probing/` | Probing dump（~22 项） |
| `…-p2-s512/straggler/trace-C1.csv` + `meta-C1.yaml` | 离线 Straggler 转换 |
| `…-p2-loud/`、`…-p2-bite2/` | 爬坡半成品 |
| `…-p1/logs/p1_orch_interrupted.txt` | P1 中断编排日志 |
| `scripts/fail-slow/swb/` | 隔离代码（见下） |

## 6. 代码隔离目录（已本地保存 / 待 commit）

`project/probing-test/scripts/fail-slow/swb/`：

- `train_bench_swb.py` — fork 训练；修 `comm_ms`；`INLINE_INJECT=2b`；`MCCL_STRESS_MB`
- `pipeline_swb.sh` — 串行点火+补点；点火前清陈旧 done/fail
- `run_case_swb.sh` / `run_swb_pair.sh` / `supervise_p*.sh`
- `calibrate_mccl.sh`、`dose_swb.yaml`、`score_*.py`
- `baselines/*` — Greyhound/XPUTimer **缺 .so → PENDING**；C5 Flight Recorder 未跑；Straggler stub 已用

## 7. 对手线状态

| 工具 | 状态 |
|---|---|
| Probing（C2） | P2 正式轮已跑通 `rc=0` |
| StragglerAnalysis | 离线 CSV 已出（非在线分母） |
| Greyhound / XPUTimer | PENDING（缺 `.so`，未写 ENV-BLOCKED） |
| Flight Recorder / Dynolog | PENDING |

## 8. 恢复后续跑清单（勿提前动共享管线）

1. `verify_channels` / 确认 `yjr-swb` pods Ready + shm + Probing 0.2.5  
2. 补拉 C1 缺失 8 rank（若 pod 盘还在）  
3. 重跑 **P1-SW-B** `…-p1`（C0→C1→C2）  
4. 有空档再跑 C5 Flight Recorder；Greyhound/XPUTimer 待 `.so`  
5. 仍只改 `swb/`，不碰父目录与其它 Agent pod

## 9. 中断时动作

- 已停止本机 `supervise_p1` / `pipeline_swb` 编排  
- 未强制删集群资源（等恢复再决定）
