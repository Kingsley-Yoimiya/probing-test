#!/usr/bin/env bash
# P1-HW-A mohe-64 Loud bite：中途 victim-only xcore 降频（freq level=4）
# 叙事=真·改频（非 cube 热墙代理）；结果写 muxi-mohe
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export LOCAL_RESULT_ROOT="${LOCAL_RESULT_ROOT:-/Users/yinjinrun/Codespace/myportal/results/muxi-mohe/${RUN_ID:?need RUN_ID}}"
export ABC_CONFIGS="${ABC_CONFIGS:-C0_baseline,C1_inject_none}"
export NNODES="${NNODES:-8}"
export NPROC="${NPROC:-8}"
export ENSURE_SHM="${ENSURE_SHM:-0}"
export ACCEPT_GATE="${ACCEPT_GATE:-0}"
export CASE_ID="${CASE_ID:-P1-HW-A}"
export INJECT_ARGS="${INJECT_ARGS:-level=4}"
export MODE="${MODE:-gpu_bound}"
export ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"
export SIDECAR_LOCAL_RANK="${SIDECAR_LOCAL_RANK:-7}"
export FREQ_LEVEL="${FREQ_LEVEL:-4}"
export ITERS="${ITERS:-500}"
export WARMUP="${WARMUP:-50}"
export SEED="${SEED:-42}"
export MODEL="${MODEL:-gpt2}"

CASE_ID="$CASE_ID" RUN_ID="$RUN_ID" PODS="$PODS" KUBECONFIG="$KUBECONFIG" \
  LOCAL_RESULT_ROOT="$LOCAL_RESULT_ROOT" ABC_CONFIGS="$ABC_CONFIGS" \
  NNODES="$NNODES" NPROC="$NPROC" ENSURE_SHM="$ENSURE_SHM" \
  ACCEPT_MIN_RATIO="$ACCEPT_MIN_RATIO" INJECT_ARGS="$INJECT_ARGS" MODE="$MODE" \
  SIDECAR_LOCAL_RANK="$SIDECAR_LOCAL_RANK" FREQ_LEVEL="$FREQ_LEVEL" \
  ITERS="$ITERS" WARMUP="$WARMUP" SEED="$SEED" MODEL="$MODEL" ROUNDS="${ROUNDS:-1}" \
  PIPELINE_SH="$HERE/pipeline_freq_mid.sh" \
  bash "$HERE/run_abc.sh"
