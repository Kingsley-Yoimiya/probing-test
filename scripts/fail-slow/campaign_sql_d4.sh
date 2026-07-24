#!/usr/bin/env bash
# SQL-D4 战役：Loud 三 PASS case + Quiet P1-EXT-B；分 dose 子目录避免覆盖。
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
mkdir -p "$STATE_ROOT/logs" "$STATE_ROOT/Loud" "$STATE_ROOT/Quiet"
export ACCEPT_GATE=0
export SIDECAR_WARMUP=8
export DUMP_PROBING_SQL=1
# 强制 500：父 shell 若残留 ITERS=200，会在 SIDECAR_WARMUP 未结束就收工 → C1/C0 假阴性
export ITERS="${ITERS:-500}"
if [ "$ITERS" -lt 500 ]; then
  echo "WARN: overriding ITERS=$ITERS → 500 for sql_d4 campaign" | tee -a "$STATE_ROOT/campaign.log"
  export ITERS=500
fi

IFS=',' read -r -a POD_ARRAY <<< "$PODS"
for pod in "${POD_ARRAY[@]}"; do
  kubectl --kubeconfig="$KUBECONFIG" exec "$pod" -- mkdir -p /workspace/probe-bundle
  for f in dump_probing_sql.sh train_bench_probe.py sidecar_inject.py; do
    kubectl --kubeconfig="$KUBECONFIG" cp "$HERE/$f" "$pod:/workspace/probe-bundle/$f" || true
  done
done

echo "sql_d4 start RUN_ID=$RUN_ID PODS=$PODS" | tee -a "$STATE_ROOT/campaign.log"
date -Iseconds >> "$STATE_ROOT/campaign.log"

run_one() {
  local case_id="$1"
  local dose="$2"
  local inject_args="$3"
  local dest="$STATE_ROOT/$dose"
  mkdir -p "$dest/logs"
  echo "===== START $case_id dose=$dose $(date -Iseconds) =====" | tee -a "$STATE_ROOT/campaign.log"
  echo "${case_id}:${dose}" > "$STATE_ROOT/current_case.txt"
  set +e
  CASE_ID="$case_id" RUN_ID="${RUN_ID}-${dose}" PODS="$PODS" KUBECONFIG="$KUBECONFIG" \
    LOCAL_RESULT_ROOT="$dest" ACCEPT_GATE=0 SIDECAR_WARMUP=8 \
    INJECT_ARGS="$inject_args" \
    bash "$HERE/run_case_abc.sh" > "$STATE_ROOT/logs/${case_id}_${dose}.log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    touch "$STATE_ROOT/.done_${case_id}_${dose}"
    echo "===== DONE $case_id $dose rc=0 $(date -Iseconds) =====" | tee -a "$STATE_ROOT/campaign.log"
  else
    echo "===== FAIL $case_id $dose rc=$rc $(date -Iseconds) =====" | tee -a "$STATE_ROOT/campaign.log"
    echo "${case_id}:${dose}" >> "$STATE_ROOT/failed_cases.txt"
  fi
  return 0
}

run_one P1-EXT-A Loud "duty=0.9,size=8192"
run_one P1-EXT-B Loud "duty=0.9,size=8192"
run_one P3-EXT-A Loud ""
run_one P1-EXT-B Quiet "duty=0.4,size=4096"

echo "IDLE" > "$STATE_ROOT/current_case.txt"
echo "scoring…" | tee -a "$STATE_ROOT/campaign.log"
python3 "$HERE/score_dlevel_sql.py" \
  --result-root "$STATE_ROOT/Loud" \
  --cases P1-EXT-A,P1-EXT-B,P3-EXT-A \
  --dose Loud | tee "$STATE_ROOT/VERDICT_SQL_Loud.md" | tee -a "$STATE_ROOT/campaign.log"
python3 "$HERE/score_dlevel_sql.py" \
  --result-root "$STATE_ROOT/Quiet" \
  --cases P1-EXT-B \
  --dose Quiet | tee "$STATE_ROOT/VERDICT_SQL_Quiet.md" | tee -a "$STATE_ROOT/campaign.log"
# also copy CSVs to root
cp -f "$STATE_ROOT/Loud/scoring_table_SQL_Loud.csv" "$STATE_ROOT/" 2>/dev/null || true
cp -f "$STATE_ROOT/Quiet/scoring_table_SQL_Quiet.csv" "$STATE_ROOT/" 2>/dev/null || true
echo "sql_d4 finished $(date -Iseconds)" | tee -a "$STATE_ROOT/campaign.log"
echo "SQLD4_END rc=0 $(date -Iseconds)" | tee -a "$STATE_ROOT/campaign.log"
exit 0
