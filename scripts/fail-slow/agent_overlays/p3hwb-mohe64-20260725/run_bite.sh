#!/usr/bin/env bash
# P3-HW-B mohe-64 Loud bite：主机 CPU 温度墙（中途锁低 scaling_max_freq）
# OUTLINE 7B；≠ run_campaign 误写 stress_vm；≠ P3-HW-A 换页
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export LOCAL_RESULT_ROOT="${LOCAL_RESULT_ROOT:-/Users/yinjinrun/Codespace/myportal/results/muxi-mohe/${RUN_ID:?need RUN_ID}}"
export ABC_CONFIGS="${ABC_CONFIGS:-C0_baseline,C1_inject_none}"
export NNODES="${NNODES:-8}"
export NPROC="${NPROC:-8}"
export ENSURE_SHM="${ENSURE_SHM:-0}"
export ACCEPT_GATE="${ACCEPT_GATE:-0}"
export CASE_ID="${CASE_ID:-P3-HW-B}"
export INJECT_ARGS="${INJECT_ARGS:-khz=1200000}"
export MODE="${MODE:-host_bound}"
export ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}"
export SIDECAR_LOCAL_RANK="${SIDECAR_LOCAL_RANK:-7}"
export CPU_FREQ_KHZ="${CPU_FREQ_KHZ:-1200000}"
export CPU_FREQ_RESTORE_KHZ="${CPU_FREQ_RESTORE_KHZ:-2700000}"
export ITERS="${ITERS:-500}"
export WARMUP="${WARMUP:-50}"
export SEED="${SEED:-42}"
export MODEL="${MODEL:-gpt2}"

CASE_ID="$CASE_ID" RUN_ID="$RUN_ID" PODS="$PODS" KUBECONFIG="$KUBECONFIG" \
  LOCAL_RESULT_ROOT="$LOCAL_RESULT_ROOT" ABC_CONFIGS="$ABC_CONFIGS" \
  NNODES="$NNODES" NPROC="$NPROC" ENSURE_SHM="$ENSURE_SHM" \
  ACCEPT_MIN_RATIO="$ACCEPT_MIN_RATIO" INJECT_ARGS="$INJECT_ARGS" MODE="$MODE" \
  SIDECAR_LOCAL_RANK="$SIDECAR_LOCAL_RANK" \
  CPU_FREQ_KHZ="$CPU_FREQ_KHZ" CPU_FREQ_RESTORE_KHZ="$CPU_FREQ_RESTORE_KHZ" \
  ITERS="$ITERS" WARMUP="$WARMUP" SEED="$SEED" MODEL="$MODEL" ROUNDS="${ROUNDS:-1}" \
  PIPELINE_SH="$HERE/pipeline_cpufreq_mid.sh" \
  bash "$HERE/run_abc.sh"
