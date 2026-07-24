#!/usr/bin/env bash
# run_swb_pair.sh — 串行跑单个 case 的 C0+C1(+可选C2)，带 request-timeout
set -uo pipefail
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7897}"
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7897}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"
unset ALL_PROXY || true
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-vc-c550-h3c-test-weibozhen.yaml}"

SWB="$(cd "$(dirname "$0")" && pwd)"
CASE_ID="${CASE_ID:?P2-SW-B|P1-SW-B}"
RUN_ID="${RUN_ID:?}"
PODS="${PODS:?}"
ITERS="${ITERS:-350}"
WARMUP="${WARMUP:-50}"
DO_C2="${DO_C2:-1}"
MCCL_STRESS_MB="${MCCL_STRESS_MB:-512}"

case "$CASE_ID" in
  P2-SW-B)
    KIND=mccl_algo
    ARGS="${INJECT_ARGS:-algo=Ring,proto=Simple,min_ch=4,max_ch=4}"
    ;;
  P1-SW-B)
    KIND=rare_shape
    ARGS="${INJECT_ARGS:-rare_seq=1536,every=1}"
    ;;
  *) echo bad case; exit 2 ;;
esac

run_cfg() {
  local cfg="$1" gid="$2"
  echo "=== $CASE_ID $cfg $(date) ==="
  CASE="$CASE_ID" INJECT_KIND="$KIND" INJECT_ARGS="$ARGS" \
    RUN_ID="$RUN_ID" GROUP_ID="$gid" \
    PODS="$PODS" NNODES="${NNODES:-8}" NPROC="${NPROC:-8}" \
    ITERS="$ITERS" WARMUP="$WARMUP" ROUNDS=1 \
    MODE=gpu_bound LOCAL_FS=1 MCCL_STRESS_MB="$MCCL_STRESS_MB" \
    LOCAL_CODE=/workspace/probe-bundle/swb LOCAL_OUT=/workspace/probe-bundle/swb/out \
    CONFIGS_ONLY="$cfg" DUMP_PROBING_SQL=1 KUBECONFIG="$KUBECONFIG" \
    bash "$SWB/pipeline_swb.sh"
  echo "${cfg}_RC=$?"
}

run_cfg C0_baseline 0
run_cfg C1_inject_none 1
if [ "$DO_C2" = "1" ]; then
  run_cfg C2_probing 2
fi
echo ALL_DONE
