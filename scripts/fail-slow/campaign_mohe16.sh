#!/usr/bin/env bash
# mohe 16 卡战役：按 queue 逐 case 跑 A/B/C（兼容 bash 3.2）
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
QUEUE_FILE="${QUEUE_FILE:-$STATE_ROOT/campaign_queue.txt}"
mkdir -p "$STATE_ROOT/logs"

echo "campaign start RUN_ID=$RUN_ID PODS=$PODS" | tee -a "$STATE_ROOT/campaign.log"
date -Iseconds >> "$STATE_ROOT/campaign.log"

# 预读队列到数组（避免 while-read 在部分环境下只跑一轮）
CASES=()
while IFS= read -r line || [ -n "$line" ]; do
  line="$(printf '%s' "$line" | tr -d '[:space:]')"
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  CASES+=("$line")
done < "$QUEUE_FILE"
echo "queue size=${#CASES[@]}: ${CASES[*]}" | tee -a "$STATE_ROOT/campaign.log"

i=0
while [ "$i" -lt "${#CASES[@]}" ]; do
  CASE_ID="${CASES[$i]}"
  i=$((i+1))
  marker="$STATE_ROOT/.done_$CASE_ID"
  if [ -f "$marker" ]; then
    echo "skip done $CASE_ID" | tee -a "$STATE_ROOT/campaign.log"
    continue
  fi
  echo "===== START $CASE_ID $(date -Iseconds) =====" | tee -a "$STATE_ROOT/campaign.log"
  echo "$CASE_ID" > "$STATE_ROOT/current_case.txt"
  set +e
  CASE_ID="$CASE_ID" RUN_ID="$RUN_ID" PODS="$PODS" KUBECONFIG="$KUBECONFIG" \
    LOCAL_RESULT_ROOT="$STATE_ROOT" \
    bash "$HERE/run_case_abc.sh" > "$STATE_ROOT/logs/${CASE_ID}.log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    touch "$marker"
    echo "===== DONE $CASE_ID rc=0 $(date -Iseconds) =====" | tee -a "$STATE_ROOT/campaign.log"
  else
    echo "===== FAIL $CASE_ID rc=$rc $(date -Iseconds) =====" | tee -a "$STATE_ROOT/campaign.log"
    echo "$CASE_ID" >> "$STATE_ROOT/failed_cases.txt"
  fi
  rm -f "$STATE_ROOT/current_case.txt"
done

echo "campaign finished $(date -Iseconds)" | tee -a "$STATE_ROOT/campaign.log"
echo "IDLE" > "$STATE_ROOT/current_case.txt"
