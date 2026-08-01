#!/usr/bin/env bash
# P3-HW-C mohe-64 Loud bite：本地盘读延迟（dm-delay mid）
# OUTLINE 7C；≠ run_campaign 误写 ecc；≠ P3-EXT-B stress_io 邻居争用
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export LOCAL_RESULT_ROOT="${LOCAL_RESULT_ROOT:-/Users/yinjinrun/Codespace/myportal/results/muxi-mohe/${RUN_ID:?need RUN_ID}}"
export ABC_CONFIGS="${ABC_CONFIGS:-C0_baseline,C1_inject_none}"
export NNODES="${NNODES:-8}"
export NPROC="${NPROC:-8}"
export ENSURE_SHM="${ENSURE_SHM:-0}"
export ACCEPT_GATE="${ACCEPT_GATE:-0}"
export CASE_ID="${CASE_ID:-P3-HW-C}"
export INJECT_ARGS="${INJECT_ARGS:-delay_ms=50}"
export MODE="${MODE:-host_bound}"
export ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}"
export SIDECAR_LOCAL_RANK="${SIDECAR_LOCAL_RANK:-7}"
export DISK_DELAY_MS="${DISK_DELAY_MS:-50}"
export DISK_DELAY_IMG_MB="${DISK_DELAY_IMG_MB:-512}"
export IO_PAYLOAD="${IO_PAYLOAD:-/mnt/p3hwc_data/payload.bin}"
export IO_READ_KB="${IO_READ_KB:-1024}"
export DL_WORKERS="${DL_WORKERS:-0}"
export ITERS="${ITERS:-500}"
export WARMUP="${WARMUP:-50}"
export SEED="${SEED:-42}"
export MODEL="${MODEL:-gpt2}"

CASE_ID="$CASE_ID" RUN_ID="$RUN_ID" PODS="$PODS" KUBECONFIG="$KUBECONFIG" \
  LOCAL_RESULT_ROOT="$LOCAL_RESULT_ROOT" ABC_CONFIGS="$ABC_CONFIGS" \
  NNODES="$NNODES" NPROC="$NPROC" ENSURE_SHM="$ENSURE_SHM" \
  ACCEPT_MIN_RATIO="$ACCEPT_MIN_RATIO" INJECT_ARGS="$INJECT_ARGS" MODE="$MODE" \
  SIDECAR_LOCAL_RANK="$SIDECAR_LOCAL_RANK" \
  DISK_DELAY_MS="$DISK_DELAY_MS" DISK_DELAY_IMG_MB="$DISK_DELAY_IMG_MB" \
  IO_PAYLOAD="$IO_PAYLOAD" IO_READ_KB="$IO_READ_KB" DL_WORKERS="$DL_WORKERS" \
  ITERS="$ITERS" WARMUP="$WARMUP" SEED="$SEED" MODEL="$MODEL" ROUNDS="${ROUNDS:-1}" \
  PIPELINE_SH="$HERE/pipeline_disk_lat_mid.sh" \
  bash "$HERE/run_abc.sh"
