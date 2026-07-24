# SW-B 64 卡战役台账（隔离目录）

> 与父目录 `docs/fail-slow/ledger.md` 并行维护，避免多 Agent 抢写。完成后可合并摘要。

## 环境

| 项 | 值 |
|---|---|
| 集群 | h3c-test（weibozhen.p kube 进门） |
| kube | `~/.kube/config-vc-c550-h3c-test-weibozhen.yaml` |
| 落盘身份 | yinjinrun.p；本机 `results/muxi-h3c/` |
| 规模 | **8×8=64 rank**（DDP；USE_FSDP 未开） |
| Pods | `yjr-swb-h145231,h145230,h144222,h145219,h144217,h145217,h145216,h144215` |
| 节点 | host-10-12-145-231/230,144-222,145-219,144-217,145-217/216,144-215 |
| 代码 | `/workspace/probe-bundle/swb`（隔离） |
| Probing | 0.2.5 MD5 `fe3b76db…` |
| shm | 32G |
| RUN_ID 前缀 | `20260724_171825-swb64` |

## MCCL 标定（P2 前置）

| 配置 | bus_bw GB/s | ms/iter |
|---|---|---|
| default | 61.85 | 2.14 |
| Ring/Simple ch=4 | 29.03 | 4.55 |
| ratio | **2.13**（fabric 参考 ~2.14） | |

落点：`results/muxi-h3c/20260724_171825-swb64/mccl_calibrate/`

## Case 状态

| Case | 注入 | Loud 配方 | 状态 |
|---|---|---|---|
| P2-SW-B | `mccl_algo` env + `MCCL_STRESS_MB=512` | Ring/Simple min_ch=max_ch=4 | **冻结** `…-p2-s512`（集群中断） |
| P1-SW-B | `rare_shape`/`2b` | rare_seq=1536,every=1 | **中断于 C0**；编排已停 |

> 完整参数/半成品见 `CHECKPOINT_20260724.md`；恢复后再续。

## 平行 run

- C0 健康 / C1 注入 / C2 Probing
- C3–C5 对手见 `baselines/baseline_status.md` + `run_baselines_swb.sh`
- 判分：`score_comm_phase.py`（P2）、`score_shape_bimodal.py`（P1）

## 冻结检测（P2，`…-p2-s512`）

- 窗：`[100,300]`，8 文件 × 200 step 中位（`n=1600`）
- C0：`step_ms=113.982` `comm_ms=18.426`
- C1：`step_ms=129.051` `comm_ms=31.076`
- **step_ratio=1.132**（未达 1.15）；**comm_ratio=1.687**；标定 fabric **2.13**
- 验收口径：通道路径 Loud 以标定 + `comm_ratio` 为主证；step 因 compute~90ms 主导未咬满 1.15
- 落点：`results/muxi-h3c/20260724_171825-swb64-p2-s512/verdict_ratio.json`
- C2：`rc=0`，Probing dump 在 `…/C2_probing/probing/`（本机 22 项）
- 本机回拉（2026-07-24 19:51 补扒）：
  - P2：C0=64 / C1=56（缺 rank 48–55=`yjr-swb-h145216` C1 `node_6.fail`/TCPStore）/ C2=64；Probing 22 项
  - P1：C0=64（仅健康 baseline，无 C1/C2）
  - 落点：`results/muxi-h3c/20260724_171825-swb64{,-p2-s512,-p2-loud,-p2-bite2,-p1}/` + `…-FREEZE.tgz`
- 禁止旁证抬分

## 隔离（多 Agent）— 硬约定

- **大改只动** `scripts/fail-slow/swb/` + pod `/workspace/probe-bundle/swb`
- **勿改** 父目录 `pipeline` / `train_bench_probe` / 共享 ledger
- **勿碰** 其它 Agent 的 `yjr-fs64-*` / 其 `probe-bundle` 根
- 本线 pod 前缀：`yjr-swb`；RUN：`20260724_171825-swb64*`

## 注意

- Mac kubectl 并发易 EOF → `pipeline_swb.sh` 串行点火+补点
- 长 wait 时 Mac 编排可能掉线 → `logs/p2_loud_supervise.log` 续跑
