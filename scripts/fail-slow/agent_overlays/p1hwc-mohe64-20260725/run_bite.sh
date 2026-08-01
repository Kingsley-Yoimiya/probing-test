#!/usr/bin/env bash
# P1-HW-C mohe-64 Loud bite：measure 窗间歇 victim dpm 打低再恢复（tip/p99/max 叙事）
# 默认间歇 xcore,0（2s on / 8s off）；FREQ_DOMAIN=mc 可切显存档
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export LOCAL_RESULT_ROOT="${LOCAL_RESULT_ROOT:-/Users/yinjinrun/Codespace/myportal/results/muxi-mohe/${RUN_ID:?need RUN_ID}}"
export ABC_CONFIGS="${ABC_CONFIGS:-C0_baseline,C1_inject_none}"
export NNODES="${NNODES:-8}"
export NPROC="${NPROC:-8}"
export ENSURE_SHM="${ENSURE_SHM:-0}"
export ACCEPT_GATE="${ACCEPT_GATE:-0}"
export CASE_ID="${CASE_ID:-P1-HW-C}"
export INJECT_ARGS="${INJECT_ARGS:-level=0,pulse=1}"
export MODE="${MODE:-gpu_bound}"
export SIDECAR_LOCAL_RANK="${SIDECAR_LOCAL_RANK:-7}"
export FREQ_DOMAIN="${FREQ_DOMAIN:-xcore}"
export FREQ_LEVEL="${FREQ_LEVEL:-0}"
export FREQ_RESTORE_LEVEL="${FREQ_RESTORE_LEVEL:-9}"
export PULSE_ON_S="${PULSE_ON_S:-2}"
export PULSE_OFF_S="${PULSE_OFF_S:-8}"
export ITERS="${ITERS:-500}"
export WARMUP="${WARMUP:-50}"
export SEED="${SEED:-42}"
export MODEL="${MODEL:-gpt2}"
# tip 闸门对齐 P1-SW-C
export ACCEPT_SCRIPT="${ACCEPT_SCRIPT:-$HERE/accept_p1hwc_tip.py}"
export ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"

CASE_ID="$CASE_ID" RUN_ID="$RUN_ID" PODS="$PODS" KUBECONFIG="$KUBECONFIG" \
  LOCAL_RESULT_ROOT="$LOCAL_RESULT_ROOT" ABC_CONFIGS="$ABC_CONFIGS" \
  NNODES="$NNODES" NPROC="$NPROC" ENSURE_SHM="$ENSURE_SHM" \
  ACCEPT_MIN_RATIO="$ACCEPT_MIN_RATIO" INJECT_ARGS="$INJECT_ARGS" MODE="$MODE" \
  SIDECAR_LOCAL_RANK="$SIDECAR_LOCAL_RANK" \
  FREQ_DOMAIN="$FREQ_DOMAIN" FREQ_LEVEL="$FREQ_LEVEL" \
  FREQ_RESTORE_LEVEL="$FREQ_RESTORE_LEVEL" \
  PULSE_ON_S="$PULSE_ON_S" PULSE_OFF_S="$PULSE_OFF_S" \
  ITERS="$ITERS" WARMUP="$WARMUP" SEED="$SEED" MODEL="$MODEL" ROUNDS="${ROUNDS:-1}" \
  ACCEPT_SCRIPT="$ACCEPT_SCRIPT" \
  PIPELINE_SH="$HERE/pipeline_freq_pulse.sh" \
  bash "$HERE/run_abc.sh"
