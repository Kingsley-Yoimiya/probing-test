#!/usr/bin/env bash
# Loud2：先 P1-EXT-A C0+C1 smoke 闸门，再第一梯队全量（ACCEPT_GATE=1，C1 不过跳过 C2）。
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
export ACCEPT_GATE=1
export SIDECAR_WARMUP=8

echo "loud2 start RUN_ID=$RUN_ID PODS=$PODS" | tee -a "$STATE_ROOT/campaign.log"
date -Iseconds >> "$STATE_ROOT/campaign.log"

run_one() {
  local case_id="$1"
  local configs="${2:-}"
  echo "===== START $case_id configs=${configs:-A/B/C} $(date -Iseconds) =====" | tee -a "$STATE_ROOT/campaign.log"
  echo "$case_id" > "$STATE_ROOT/current_case.txt"
  set +e
  if [ -n "$configs" ]; then
    ABC_CONFIGS="$configs" CASE_ID="$case_id" RUN_ID="$RUN_ID" PODS="$PODS" KUBECONFIG="$KUBECONFIG" \
      LOCAL_RESULT_ROOT="$STATE_ROOT" ACCEPT_GATE="$ACCEPT_GATE" \
      bash "$HERE/run_case_abc.sh" > "$STATE_ROOT/logs/${case_id}.log" 2>&1
  else
    CASE_ID="$case_id" RUN_ID="$RUN_ID" PODS="$PODS" KUBECONFIG="$KUBECONFIG" \
      LOCAL_RESULT_ROOT="$STATE_ROOT" ACCEPT_GATE="$ACCEPT_GATE" \
      bash "$HERE/run_case_abc.sh" > "$STATE_ROOT/logs/${case_id}.log" 2>&1
  fi
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    touch "$STATE_ROOT/.done_$case_id"
    echo "===== DONE $case_id rc=0 $(date -Iseconds) =====" | tee -a "$STATE_ROOT/campaign.log"
  else
    echo "===== FAIL $case_id rc=$rc $(date -Iseconds) =====" | tee -a "$STATE_ROOT/campaign.log"
    echo "$case_id" >> "$STATE_ROOT/failed_cases.txt"
  fi
  return "$rc"
}

# 1) smoke：仅 C0+C1
echo "SMOKE P1-EXT-A C0+C1" | tee -a "$STATE_ROOT/campaign.log"
if ! run_one P1-EXT-A "C0_baseline,C1_inject_none"; then
  echo "SMOKE_GATE failed — stop loud2 (fix cube/same-GPU/warmup then retry)" | tee -a "$STATE_ROOT/campaign.log"
  echo "IDLE" > "$STATE_ROOT/current_case.txt"
  exit 1
fi
# smoke 过了：清 .done 以便完整 A/B/C 再跑一遍（含 C2）
rm -f "$STATE_ROOT/.done_P1-EXT-A"
# 从 failed 列表去掉 smoke 失败残留
if [ -f "$STATE_ROOT/failed_cases.txt" ]; then
  grep -v '^P1-EXT-A$' "$STATE_ROOT/failed_cases.txt" > "$STATE_ROOT/failed_cases.txt.tmp" || true
  mv "$STATE_ROOT/failed_cases.txt.tmp" "$STATE_ROOT/failed_cases.txt"
fi

# 2) 第一梯队全量
for case_id in P1-EXT-A P1-EXT-B P3-EXT-A P3-EXT-B P3-SW-A; do
  if [ -f "$STATE_ROOT/.done_$case_id" ]; then
    echo "skip done $case_id" | tee -a "$STATE_ROOT/campaign.log"
    continue
  fi
  run_one "$case_id" || true
done

echo "loud2 finished $(date -Iseconds)" | tee -a "$STATE_ROOT/campaign.log"
echo "IDLE" > "$STATE_ROOT/current_case.txt"
# 合并各 case 验收表已由 accept_loud 写入 acceptance_table.md
cp -f "$STATE_ROOT/acceptance_table.md" "$STATE_ROOT/SUMMARY_ACCEPTANCE.md" 2>/dev/null || true
exit 0
