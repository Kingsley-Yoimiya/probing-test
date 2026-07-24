# baselines/ — SW-B 对手工具接线说明

本目录只服务 `scripts/fail-slow/swb/` 隔离战役。父目录 `run_case_pipeline_v4.sh` 的 C3–C5 denv stub 在 `pipeline_swb.sh` 中原样保留；**此处不改父脚本**。

## 与 pipeline 的对应关系

| Config | 工具 | denv（`pipeline_swb.sh`） | 状态 |
|--------|------|---------------------------|------|
| C3_greyhound | Greyhound | `LD_PRELOAD=$CODE_DIR/greyhound/libmcclprobe.so` | stub：需把 `.so` 放到 `$LOCAL_CODE/greyhound/` |
| C4_xputimer | XPUTimer | `LD_PRELOAD=$CODE_DIR/xputimer/libxpu_timer_metax.so` | stub：MetaX 版 `.so` 待接入 |
| C5_flight_recorder | PyTorch Flight Recorder | `TORCH_NCCL_TRACE_BUFFER_SIZE` + `TORCH_NCCL_DUMP_ON_TIMEOUT=1` | stub：触发协议见 ledger；oracle 触发不算检出率 |
| （可选）Dynolog | Dynolog | 未在 C0–C5 占位；见 `baseline_status.md` | 独立 daemon，本战役未绑 config 名 |

`LOCAL_CODE` 默认 `/workspace/probe-bundle/swb`，因此 preload 路径落在 **swb 子树**，不会与其它 agent 的 `/workspace/probe-bundle` 抢文件。

## StragglerAnalysis（离线）

- 入口 stub：`convert_timeline_to_straggler.py`
- 输入：本仓 `rank_*.jsonl`（含 `step_ms` / `compute_ms` / `comm_ms` / `wait_ms` / `shape_seq`）
- 输出：尽量写最小 parquet；缺依赖时打印 schema TODO
- **不并入在线检出率**（ledger：离线补充）

## 跑 baselines config

```bash
ABC_CONFIGS=C0_baseline,C1_inject_none,C3_greyhound,C5_flight_recorder \
  CASE_ID=P2-SW-B RUN_ID=... PODS=... KUBECONFIG=... \
  bash run_case_swb.sh
```

细节与当前 verdict 语义见同目录 `baseline_status.md`。
