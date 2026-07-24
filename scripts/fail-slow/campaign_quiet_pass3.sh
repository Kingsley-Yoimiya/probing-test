#!/usr/bin/env bash
# 对 Loud 已 PASS 的三 case 跑 Quiet（SOP §九 步骤 5），验收+离线判分。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7897}"
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7897}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"
unset ALL_PROXY all_proxy || true

RUN_ID="${RUN_ID:?}"
PODS="${PODS:?}"
KUBECONFIG="${KUBECONFIG:?}"
STATE_ROOT="${STATE_ROOT:-/Users/yinjinrun/Codespace/myportal/results/muxi-mohe/$RUN_ID}"
mkdir -p "$STATE_ROOT/logs"
export ACCEPT_GATE=0
export SIDECAR_WARMUP=8

echo "quiet_pass3 start RUN_ID=$RUN_ID" | tee -a "$STATE_ROOT/campaign.log"
date -Iseconds >> "$STATE_ROOT/campaign.log"

run_quiet() {
  local case_id="$1"
  local inject_args="$2"
  local min_ratio="${3:-1.15}"
  echo "===== START $case_id Quiet $(date -Iseconds) =====" | tee -a "$STATE_ROOT/campaign.log"
  echo "$case_id" > "$STATE_ROOT/current_case.txt"
  set +e
  CASE_ID="$case_id" INJECT_ARGS="$inject_args" ACCEPT_MIN_RATIO="$min_ratio" \
    RUN_ID="$RUN_ID" PODS="$PODS" KUBECONFIG="$KUBECONFIG" \
    LOCAL_RESULT_ROOT="$STATE_ROOT" ACCEPT_GATE=0 SIDECAR_WARMUP=8 \
    bash "$HERE/run_case_abc.sh" > "$STATE_ROOT/logs/${case_id}.log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    touch "$STATE_ROOT/.done_$case_id"
    echo "===== DONE $case_id Quiet rc=0 $(date -Iseconds) =====" | tee -a "$STATE_ROOT/campaign.log"
  else
    echo "===== FAIL $case_id Quiet rc=$rc $(date -Iseconds) =====" | tee -a "$STATE_ROOT/campaign.log"
    echo "$case_id" >> "$STATE_ROOT/failed_cases.txt"
  fi
}

# Quiet 配方（对齐 case 文档）
run_quiet P1-EXT-A "duty=0.3,size=4096" 1.15
run_quiet P1-EXT-B "duty=0.4,size=4096" 1.15
run_quiet P3-EXT-A "cpu_frac=0.5,cpu_load=70" 1.15

python3 "$HERE/score_dlevel_offline.py" \
  --result-root "$STATE_ROOT" \
  --cases P1-EXT-A,P1-EXT-B,P3-EXT-A \
  --dose Quiet || true

echo "quiet_pass3 finished $(date -Iseconds)" | tee -a "$STATE_ROOT/campaign.log"
echo "IDLE" > "$STATE_ROOT/current_case.txt"
