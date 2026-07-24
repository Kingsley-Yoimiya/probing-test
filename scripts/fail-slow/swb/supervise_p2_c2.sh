#!/usr/bin/env bash
# 仅跑 P2 C2（C0/C1 已冻结 …-p2-s512）。隔离目录内，不碰父 pipeline。
set -uo pipefail
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7897}"
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7897}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"
unset ALL_PROXY || true
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-vc-c550-h3c-test-weibozhen.yaml}"

SWB="$(cd "$(dirname "$0")" && pwd)"
PODS="${PODS:-yjr-swb-h145231,yjr-swb-h145230,yjr-swb-h144222,yjr-swb-h145219,yjr-swb-h144217,yjr-swb-h145217,yjr-swb-h145216,yjr-swb-h144215}"
RUN_ID="${RUN_ID:-20260724_171825-swb64-p2-s512}"

echo "=== supervise C2 $(date) run_id=$RUN_ID ==="
CASE=P2-SW-B INJECT_KIND=mccl_algo INJECT_ARGS=algo=Ring,proto=Simple,min_ch=4,max_ch=4 \
  RUN_ID="$RUN_ID" GROUP_ID=2 \
  PODS="$PODS" NNODES=8 NPROC=8 ITERS="${ITERS:-350}" WARMUP="${WARMUP:-50}" ROUNDS=1 \
  MODE=gpu_bound LOCAL_FS=1 MCCL_STRESS_MB="${MCCL_STRESS_MB:-512}" \
  LOCAL_CODE=/workspace/probe-bundle/swb LOCAL_OUT=/workspace/probe-bundle/swb/out \
  CONFIGS_ONLY=C2_probing DUMP_PROBING_SQL=1 KUBECONFIG="$KUBECONFIG" \
  bash "$SWB/pipeline_swb.sh"
echo "C2_RC=$? $(date)"
