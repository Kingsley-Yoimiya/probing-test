#!/usr/bin/env bash
# supervise_p2_bite2.sh — 等 C0 完成后串行跑 C1/C2（Mac 编排易掉线时用）
set -uo pipefail
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7897}"
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7897}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"
unset ALL_PROXY || true
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-vc-c550-h3c-test-weibozhen.yaml}"

SWB="$(cd "$(dirname "$0")" && pwd)"
PODS=(yjr-swb-h145231 yjr-swb-h145230 yjr-swb-h144222 yjr-swb-h145219 yjr-swb-h144217 yjr-swb-h145217 yjr-swb-h145216 yjr-swb-h144215)
PODS_CSV=$(IFS=,; echo "${PODS[*]}")
OUT_C0=/workspace/probe-bundle/swb/out/P2-SW-B/round_1/C0_baseline
RUN_ID=20260724_171825-swb64-p2-bite2

echo "=== wait C0 $(date) ==="
for i in $(seq 1 90); do
  done_n=0
  for n in 0 1 2 3 4 5 6 7; do
    if kubectl -n default exec "${PODS[$n]}" -- test -f "$OUT_C0/node_${n}.done" 2>/dev/null; then
      done_n=$((done_n + 1))
    fi
  done
  lines=$(kubectl -n default exec "${PODS[0]}" -- bash -c "wc -l < $OUT_C0/ranks/rank_0000.jsonl 2>/dev/null || echo 0" 2>/dev/null | tr -d '[:space:]')
  echo "$(date +%H:%M:%S) C0 done=$done_n/8 lines=${lines:-0}"
  if [ "$done_n" -ge 8 ]; then
    echo C0_COMPLETE
    break
  fi
  # if no torchrun and incomplete, still proceed to C1 after timeout once lines stuck
  up=0
  for pod in "${PODS[@]}"; do
    kubectl -n default exec "$pod" -- pgrep -f '[t]orchrun' >/dev/null 2>&1 && up=$((up + 1)) || true
  done
  if [ "$up" = "0" ] && [ "${lines:-0}" -ge 350 ]; then
    echo "C0 likely done (no torchrun, lines>=350)"
    break
  fi
  sleep 20
done

run_one() {
  local cfg="$1" gid="$2"
  echo "=== run $cfg gid=$gid $(date) ==="
  CASE=P2-SW-B INJECT_KIND=mccl_algo INJECT_ARGS="algo=Ring,proto=Simple,min_ch=4,max_ch=4" \
    RUN_ID="$RUN_ID" GROUP_ID="$gid" \
    PODS="$PODS_CSV" NNODES=8 NPROC=8 ITERS=350 WARMUP=50 ROUNDS=1 \
    MODE=gpu_bound LOCAL_FS=1 MCCL_STRESS_MB=64 \
    LOCAL_CODE=/workspace/probe-bundle/swb LOCAL_OUT=/workspace/probe-bundle/swb/out \
    CONFIGS_ONLY="$cfg" DUMP_PROBING_SQL=1 KUBECONFIG="$KUBECONFIG" \
    bash "$SWB/pipeline_swb.sh"
  echo "${cfg}_RC=$?"
}

# C0 may still be running from prior orch — only start C1/C2
run_one C1_inject_none 1
run_one C2_probing 2
echo "=== ALL_DONE $(date) ==="
