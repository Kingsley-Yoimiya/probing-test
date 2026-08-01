#!/usr/bin/env bash
# P2-EXT-A Loud bite：C0 基线 + C1 邻居 RoCE 持续打流
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PARENT="$(cd "$HERE/../.." && pwd)"
export LOCAL_RESULT_ROOT="${LOCAL_RESULT_ROOT:-/Users/yinjinrun/Codespace/myportal/results/muxi-mohe/${RUN_ID:?need RUN_ID}}"
export ABC_CONFIGS="${ABC_CONFIGS:-C0_baseline,C1_inject_none}"
export NNODES="${NNODES:-8}"
export NPROC="${NPROC:-8}"
export ENSURE_SHM="${ENSURE_SHM:-0}"
export ACCEPT_GATE="${ACCEPT_GATE:-0}"
export CASE_ID="${CASE_ID:-P2-EXT-A}"
export MODE="${MODE:-gpu_bound}"
export ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}"
export ITERS="${ITERS:-500}"
export WARMUP="${WARMUP:-50}"
export SEED="${SEED:-42}"
export MODEL="${MODEL:-gpt2}"
export NEIGHBOR_POD="${NEIGHBOR_POD:-yjr-fs-h14410}"

CASE_ID="$CASE_ID" RUN_ID="$RUN_ID" PODS="$PODS" KUBECONFIG="$KUBECONFIG" \
  LOCAL_RESULT_ROOT="$LOCAL_RESULT_ROOT" ABC_CONFIGS="$ABC_CONFIGS" \
  NNODES="$NNODES" NPROC="$NPROC" ENSURE_SHM="$ENSURE_SHM" \
  ACCEPT_MIN_RATIO="$ACCEPT_MIN_RATIO" MODE="$MODE" \
  ITERS="$ITERS" WARMUP="$WARMUP" SEED="$SEED" MODEL="$MODEL" \
  ROUNDS="${ROUNDS:-1}" NEIGHBOR_POD="$NEIGHBOR_POD" \
  bash "$HERE/run_abc.sh"
