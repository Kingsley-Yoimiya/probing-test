#!/usr/bin/env bash
# P1-EXT-A mohe-64 Loud bite overlay：C0+C1 only；fire 带重试；结果写 muxi-mohe
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PARENT="$(cd "$HERE/../.." && pwd)"
export LOCAL_RESULT_ROOT="${LOCAL_RESULT_ROOT:-/Users/yinjinrun/Codespace/myportal/results/muxi-mohe/${RUN_ID:?need RUN_ID}}"
export ABC_CONFIGS="${ABC_CONFIGS:-C0_baseline,C1_inject_none}"
export NNODES="${NNODES:-8}"
export NPROC="${NPROC:-8}"
export ENSURE_SHM="${ENSURE_SHM:-0}"
export ACCEPT_GATE="${ACCEPT_GATE:-0}"
export CASE_ID="${CASE_ID:-P1-EXT-A}"
export INJECT_ARGS="${INJECT_ARGS:-duty=0.9,size=8192}"
export MODE="${MODE:-gpu_bound}"
export ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.8}"
export SIDECAR_LOCAL_RANK="${SIDECAR_LOCAL_RANK:-7}"
export ITERS="${ITERS:-500}"
export WARMUP="${WARMUP:-50}"
export SEED="${SEED:-42}"
export MODEL="${MODEL:-gpt2}"

# reuse run_case_abc but swap pipeline path via sed-free inline: source pattern
# → call abc's mapping then our pipeline
CASE_ID="$CASE_ID" RUN_ID="$RUN_ID" PODS="$PODS" KUBECONFIG="$KUBECONFIG" \
  LOCAL_RESULT_ROOT="$LOCAL_RESULT_ROOT" ABC_CONFIGS="$ABC_CONFIGS" \
  NNODES="$NNODES" NPROC="$NPROC" ENSURE_SHM="$ENSURE_SHM" \
  ACCEPT_MIN_RATIO="$ACCEPT_MIN_RATIO" INJECT_ARGS="$INJECT_ARGS" MODE="$MODE" \
  SIDECAR_LOCAL_RANK="$SIDECAR_LOCAL_RANK" ITERS="$ITERS" WARMUP="$WARMUP" \
  SEED="$SEED" MODEL="$MODEL" ROUNDS="${ROUNDS:-1}" \
  PIPELINE_SH="$HERE/pipeline_v4_retry.sh" \
  bash "$HERE/run_abc_retry.sh"
