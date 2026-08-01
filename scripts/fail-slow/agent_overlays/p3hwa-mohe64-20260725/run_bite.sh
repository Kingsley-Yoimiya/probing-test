#!/usr/bin/env bash
# P3-HW-A mohe-64 Loud bite：ECC/换页代理（drop_caches + page-in + mlock）
# ≠ P3-EXT-C stress_vm 96×6G 带宽叙事；证据优先 pgmajfault / PSI memory
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export LOCAL_RESULT_ROOT="${LOCAL_RESULT_ROOT:-/Users/yinjinrun/Codespace/myportal/results/muxi-mohe/${RUN_ID:?need RUN_ID}}"
export ABC_CONFIGS="${ABC_CONFIGS:-C0_baseline,C1_inject_none}"
export NNODES="${NNODES:-8}"
export NPROC="${NPROC:-8}"
export ENSURE_SHM="${ENSURE_SHM:-0}"
export ACCEPT_GATE="${ACCEPT_GATE:-0}"
export CASE_ID="${CASE_ID:-P3-HW-A}"
# a4 默认：更多 workers×较小 bytes（64×6G），mlock=0；换可复现路径（≠a1 mlock；≠a2/a3 少 worker×大块）
# 叙事仍 7A stress_page+drop_caches+pgmajfault；≠ EXT-C stress_vm 96×6G（无 drop / PSI-cpu 主证）
export INJECT_ARGS="${INJECT_ARGS:-vm_n=64,vm_bytes=6G,mlock_n=0}"
export MODE="${MODE:-host_bound}"
export ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}"
export STRESS_TIMEOUT_S="${STRESS_TIMEOUT_S:-900}"
export SIDECAR_LOCAL_RANK="${SIDECAR_LOCAL_RANK:-7}"
export DROP_CACHES_BEFORE_INJECT="${DROP_CACHES_BEFORE_INJECT:-1}"
export ITERS="${ITERS:-500}"
export WARMUP="${WARMUP:-50}"
export SEED="${SEED:-42}"
export MODEL="${MODEL:-gpt2}"

CASE_ID="$CASE_ID" RUN_ID="$RUN_ID" PODS="$PODS" KUBECONFIG="$KUBECONFIG" \
  LOCAL_RESULT_ROOT="$LOCAL_RESULT_ROOT" ABC_CONFIGS="$ABC_CONFIGS" \
  NNODES="$NNODES" NPROC="$NPROC" ENSURE_SHM="$ENSURE_SHM" \
  ACCEPT_MIN_RATIO="$ACCEPT_MIN_RATIO" INJECT_ARGS="$INJECT_ARGS" MODE="$MODE" \
  SIDECAR_LOCAL_RANK="$SIDECAR_LOCAL_RANK" \
  DROP_CACHES_BEFORE_INJECT="$DROP_CACHES_BEFORE_INJECT" \
  ITERS="$ITERS" WARMUP="$WARMUP" SEED="$SEED" MODEL="$MODEL" ROUNDS="${ROUNDS:-1}" \
  PIPELINE_SH="$HERE/pipeline_page.sh" \
  bash "$HERE/run_abc.sh"
