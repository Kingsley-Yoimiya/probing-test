#!/usr/bin/env bash
# P1-SW-B：C0→C1→C2（rare_shape）。隔离目录，不碰父 pipeline / 其它 Agent。
set -uo pipefail
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7897}"
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7897}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"
unset ALL_PROXY || true
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-vc-c550-h3c-test-weibozhen.yaml}"

SWB="$(cd "$(dirname "$0")" && pwd)"
PODS="${PODS:-yjr-swb-h145231,yjr-swb-h145230,yjr-swb-h144222,yjr-swb-h145219,yjr-swb-h144217,yjr-swb-h145217,yjr-swb-h145216,yjr-swb-h144215}"
RUN_ID="${RUN_ID:-20260724_171825-swb64-p1}"

echo "=== supervise P1 $(date) run_id=$RUN_ID ==="
CASE_ID=P1-SW-B RUN_ID="$RUN_ID" PODS="$PODS" \
  NNODES=8 NPROC=8 ITERS="${ITERS:-350}" WARMUP="${WARMUP:-50}" DO_C2="${DO_C2:-1}" \
  INJECT_ARGS="${INJECT_ARGS:-rare_seq=1536,every=1}" \
  bash "$SWB/run_swb_pair.sh"
echo "P1_ALL_RC=$? $(date)"
