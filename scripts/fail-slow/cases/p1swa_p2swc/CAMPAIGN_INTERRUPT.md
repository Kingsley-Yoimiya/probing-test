# P1-SW-A / P2-SW-C 战役快照（集群中断收口）

- 时间：2026-07-24
- 集群：`vc-c550-h3c-test`；kube 借用 `weibozhen.p`；落盘 `yinjinrun.p`
- 本机结果根：`results/muxi-h3c/`
- 隔离代码：`project/probing-test/scripts/fail-slow/cases/p1swa_p2swc/`（本目录已 rsync 到 `code/`）
- 快照时刻见 `snapshot_at.txt`

## 1. 资源 hold

| 项 | 值 |
|---|---|
| hold run_id | `20260724_173001-p1swa-hold64` |
| POD_PREFIX | `yjr-p1swa` |
| 节点（8×8=64） | `host-10-12-144-{198,201,203,206,207,69,80,84}` |
| pods | `yjr-p1swa-h144198,...h14484` |
| 镜像 | megatron-lm maca 底包 + `PULL_SECRET=megatronmuxi` |
| shm | 已 `ensure_shm` → 32G |
| Probing | `/tmp/probing-full.whl` → Probing_plus **0.2.5**（`install_env_to_pods`） |

首次 pin `144-164..197` 因 `rdma-training/roce Available=0` AdmissionError；改选上表节点后 Ready。

## 2. 全局固定参数（ledger 对齐）

| 参数 | 值 |
|---|---|
| model | GPT-2 124M（`--model gpt2`） |
| batch / seq / dtype | 8 / 1024 / bf16 |
| seed | 42 |
| iters / warmup | 500 / 50 |
| inject 窗（measure step） | **[100, 300]**（全局约 150–350） |
| victim | node0 `local_rank=7` |
| mode | `gpu_bound`（两 case） |

## 3. P1-SW-A（2A 碎片化→骤停）— 已出数

### 冻结 Loud 剂量（以 FREEZE 为准；比 dose_recipes.yaml 初稿更强）

| env | Loud 实测值 |
|---|---|
| `INLINE_INJECT` | `2a` |
| `INLINE_2A_CHUNKS` | **12** |
| `INLINE_2A_STALL_MB` | **768** |
| `INLINE_2A_STALL_S` | **0.25**（barrier 前最小 stall 地板） |

机制：交错尺寸 alloc/释放造碎片；窗后约 2/3 步在 **AllReduce/barrier 前** 大块 fill+sync；stall 必须在同步点前，否则 rank0 中位咬不动。

### 关键 run

| run_id | 规模 | 内容 | 结论 |
|---|---|---|---|
| `…-p1swa-loud-pilot`（173926） | 2×8 | 初版 2a（stall 在 barrier 外） | C1/C0≈**1.005** ineffective |
| `…-p1swa-loud-pilot3`（175729） | 2×8 | 修复后 Loud C0/C1 | **PASS C1/C0=3.579** |
| `…-p1swa-formal16`（180849） | 2×8 | C0–C5 正式 | **PASS C1/C0=3.531；C2/C0=3.526** |

### formal16 平行线

| config | 状态 | 备注 |
|---|---|---|
| C0_baseline | OK | med step≈97.2 ms |
| C1_inject_none | OK | med≈343.3 ms |
| C2_probing | OK | SQL dump 已落；常驻开销≈0（相对 C1） |
| C3_greyhound | COMPLETE | 仅 stub `.so` 加载，非完整 ACF → PENDING |
| C4_xputimer | **FAILED** | stub 跑挂 → PENDING |
| C5_flight_recorder | COMPLETE | env 环形缓冲；触发协议偏 oracle |

判分：共享 `score_dlevel_*` 的 `GT` **尚未登记 P1-SW-A**（KeyError）；当前以 `accept_loud` + trend + probing dump 为准。见 formal 目录 `SCORE_NOTES.md` / `baseline_cost.yaml`。

### 未做

- Quiet / Masked
- P1 正式 **64 卡** Eval-D
- 把 P1-SW-A 加法进共享 GT 后跑完整 D0–D5

## 4. P2-SW-C（5C 拓扑映射）— 半成品 / 未咬合

### 注入演进

1. HCA 逆序 + `P2P_DISABLE=1` → **64 卡 C1 init hang / fail**
2. 去掉 P2P，加 `SHM_DISABLE` → 仍易 fail
3. 最新：HCA 逆序 + `TOPO_EXTRA_AR=16`（训练内额外 AllReduce，模拟绕远）+ `train_bench_probe_topo.py`

### 关键 run

| run_id | 规模 | 结果 |
|---|---|---|
| `…-p2swc-loud-pilot64`（183530） | 8×8 | C0 完成（world=64）；C1 P2P 注入 hang |
| `…-p2swc-loud-pilot64b`（185423） | 8×8 | C0 OK；C1 仅 7/8 点火 → warmup timeout / FAIL；回拉时开始 EOF |
| `…-p2swc-loud-pilot16`（191610） | 2×8 | C0 master fail；C1 标 COMPLETE 但 accept **DATA_MISSING**（C1 jsonl 不完整）；集群已抖 |

**没有得到可用的 C1/C0 比值。** 恢复后应：先 16 卡把 topo+EXTRA_AR Loud 咬合标定，再 64 卡；并修 8 路并行 `kubectl exec` 偶发少 1 路点火。

## 5. 工程坑（恢复后必用）

1. LOCAL_FS：每轮 fire 前清各 pod 上该 config 的 out，否则残留 `node_*.done` 假完成  
2. 2a stall 必须在 barrier 前  
3. `NCCL/MCCL_P2P_DISABLE=1` 在本集群 64 卡上不安全  
4. 多 Agent 并行：只用 `cases/p1swa_p2swc/` + `POD_PREFIX=yjr-p1swa`，勿改共享 abc/dose  

## 6. 落盘索引

```
results/muxi-h3c/
  20260724_173001-p1swa-hold64/          # hold + 安装日志
  20260724_175729-p1swa-loud-pilot3/     # P1 Loud pilot PASS
  20260724_180849-p1swa-formal16/        # P1 正式 C0–C5（主成果）
  20260724_183530-p2swc-loud-pilot64/
  20260724_185423-p2swc-loud-pilot64b/
  20260724_191610-p2swc-loud-pilot16/    # 中断前最后尝试
  20260724_p1swa_p2swc-campaign-snapshot/  # 本收口：CAMPAIGN.md + code/
project/probing-test/scripts/fail-slow/cases/p1swa_p2swc/  # 工作拷贝（未 commit）
```

恢复集群后建议顺序：确认 hold pod 是否还在 → 没有则按 `hold_meta.yaml` 重占 → 复跑 P2 Loud 16 → 扩 64 → 补 P1 Quiet/64 与 GT 判分。
