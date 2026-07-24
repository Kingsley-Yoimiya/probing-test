#!/usr/bin/env bash
# run_all.sh — 全量 13 runs 并行编排
#
# 从跳板 ais-cf3e61a5 运行:
#   export KUBECONFIG=/tmp/config-vc-c550-h3c-test-weibozhen.yaml
#   bash /workspace/baseline-exp/run_all.sh  (或 /tmp/run_all.sh)
#
# 两轮并行：
#   第一轮: 7 组并行（baseline + 3a×4 + 9a×2）
#   第二轮: 6 组并行（9a×2 + 8a×4）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SEED=42 ITERS=30 WARMUP=10
JOB="muxi-test-1"

# Pod groups (8 pods each)
# Total 56 pods for 7 parallel groups from worker-63..126 (skip 78)
GROUP_A="${JOB}-worker-119,${JOB}-worker-120,${JOB}-worker-121,${JOB}-worker-122,${JOB}-worker-123,${JOB}-worker-124,${JOB}-worker-125,${JOB}-worker-126"
GROUP_B="${JOB}-worker-110,${JOB}-worker-111,${JOB}-worker-112,${JOB}-worker-113,${JOB}-worker-114,${JOB}-worker-115,${JOB}-worker-116,${JOB}-worker-118"
GROUP_C="${JOB}-worker-102,${JOB}-worker-103,${JOB}-worker-104,${JOB}-worker-105,${JOB}-worker-106,${JOB}-worker-107,${JOB}-worker-108,${JOB}-worker-109"
GROUP_D="${JOB}-worker-94,${JOB}-worker-95,${JOB}-worker-96,${JOB}-worker-97,${JOB}-worker-98,${JOB}-worker-99,${JOB}-worker-100,${JOB}-worker-101"
GROUP_E="${JOB}-worker-86,${JOB}-worker-87,${JOB}-worker-88,${JOB}-worker-89,${JOB}-worker-90,${JOB}-worker-91,${JOB}-worker-92,${JOB}-worker-93"
GROUP_F="${JOB}-worker-63,${JOB}-worker-79,${JOB}-worker-80,${JOB}-worker-81,${JOB}-worker-82,${JOB}-worker-83,${JOB}-worker-84,${JOB}-worker-85"
GROUP_G="${JOB}-worker-64,${JOB}-worker-65,${JOB}-worker-66,${JOB}-worker-67,${JOB}-worker-68,${JOB}-worker-69,${JOB}-worker-70,${JOB}-worker-71"

mkdir -p /tmp/baseline-compare-logs

run_one() {
  local case="$1" detector="$2" pods="$3" port="$4" tag="${1}_${2}"
  echo "[START] $tag port=$port"
  bash "$SCRIPT_DIR/run_group.sh" "$case" "$detector" "$pods" "$port" "$tag" \
    > "/tmp/baseline-compare-logs/${tag}.log" 2>&1
  local rc=$?
  echo "[DONE] $tag exit=$rc"
  return $rc
}

echo "==============================================="
echo "BASELINE COMPARE: 13 runs, 2 rounds"
echo "  SEED=$SEED ITERS=$ITERS WARMUP=$WARMUP"
echo "==============================================="

########################################
# Round 1: 7 groups parallel
########################################
echo ""
echo "===== ROUND 1 (7 parallel) ====="

run_one baseline none      "$GROUP_A" 30001 &
run_one 3a      none      "$GROUP_B" 30002 &
run_one 3a      probing   "$GROUP_C" 30003 &
run_one 3a      greyhound "$GROUP_D" 30004 &
run_one 3a      xputimer  "$GROUP_E" 30005 &
run_one 9a      none      "$GROUP_F" 30006 &
run_one 9a      probing   "$GROUP_G" 30007 &

echo "Waiting for Round 1..."
wait
echo "===== ROUND 1 COMPLETE ====="

# Brief cooldown between rounds
sleep 5

########################################
# Round 2: 6 groups parallel
########################################
echo ""
echo "===== ROUND 2 (6 parallel) ====="

run_one 9a      greyhound "$GROUP_A" 30011 &
run_one 9a      xputimer  "$GROUP_B" 30012 &
run_one 8a      none      "$GROUP_C" 30013 &
run_one 8a      probing   "$GROUP_D" 30014 &
run_one 8a      greyhound "$GROUP_E" 30015 &
run_one 8a      xputimer  "$GROUP_F" 30016 &

echo "Waiting for Round 2..."
wait
echo "===== ROUND 2 COMPLETE ====="

echo ""
echo "ALL 13 RUNS COMPLETE."
echo "Results: per-pod /workspace/baseline-exp/output/<tag>/ranks/"
echo "Logs: /tmp/baseline-compare-logs/"
echo ""
echo "Next: collect results from each pod's node_rank=0 to build comparison table."
