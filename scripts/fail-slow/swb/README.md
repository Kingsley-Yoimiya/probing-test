# SW-B 隔离实验目录

本目录是 **Fail-Slow P1-SW-B / P2-SW-B** 的独立工作面，与父目录
`scripts/fail-slow/` 的 probe 主线并行，**不要改父脚本**（其它 agent 同时在改）。

## 隔离约定

| 项 | 值 |
|----|-----|
| 代码落点（pod） | `LOCAL_CODE=/workspace/probe-bundle/swb` |
| 结果落点（pod） | `LOCAL_OUT=/workspace/probe-bundle/swb/out` |
| Pod 前缀建议 | `POD_PREFIX=yjr-swb`（调用方保证 `PODS=`） |
| 训练脚本 | `train_bench_swb.py`（pipeline 内 cp → `/tmp/tbp.py`） |
| 编排 | `run_case_swb.sh` → `pipeline_swb.sh` |
| 父目录只读复用 | `ensure_shm.sh`、`accept_loud.py`、`dump_probing_sql.sh` |

## 案例

### P2-SW-B（`INJECT_KIND=mccl_algo`）

- 无 sidecar；inject config 的 denv 设 `MCCL_ALGO` / `MCCL_PROTO` / `MCCL_MIN_NCHANNELS` / `MCCL_MAX_NCHANNELS`
- **C0 绝不设** channel clamp
- Loud 默认：`algo=Ring,proto=Simple,min_ch=4,max_ch=4`（fabric：81.8→38.2 GB/s）
- 标定：`calibrate_mccl.sh`；离线：`score_comm_phase.py`

### P1-SW-B（`INJECT_KIND=rare_shape` / `2b`）

- `INLINE_INJECT=2b`；victim（node0, `INLINE_VICTIM_LOCAL_RANK`）在窗内用 `RARE_SHAPE_SEQ`
- jsonl 字段 `shape_seq`；窗外 / 非 victim 保持 `--seq`
- Loud 默认：`rare_seq=1536,every=1`
- 离线：`score_shape_bimodal.py`

## 并行策略

- 默认 **DDP**（meta `parallel=ddp`）。124M @ 64-rank 足够。
- `USE_FSDP=1` **暂忽略**（共享 Embedding + 动态 seq 风险高）。

## 快速跑

```bash
export KUBECONFIG=~/.kube/config-vc-c550-h3c-test.yaml
export PODS=yjr-swb-0,yjr-swb-1,...,yjr-swb-7
export RUN_ID=$(date +%Y%m%d_%H%M%S)-p2swb-loud
CASE_ID=P2-SW-B DOSE=loud NNODES=8 NPROC=8 \
  bash run_case_swb.sh
```

剂量细节见 `dose_swb.yaml`；对手工具见 `baselines/`。
