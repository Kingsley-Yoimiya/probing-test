#!/usr/bin/env bash
# run_baselines_swb.sh — 在同一批 PODS / 同一注入上跑对手 config（C3–C5 + 离线转换）
#
# 用法（P2 正式 C0–C2 完成后）:
#   CASE_ID=P2-SW-B RUN_ID=... PODS=... KUBECONFIG=... \
#   ABC_CONFIGS=C3_greyhound,C4_xputimer,C5_flight_recorder \
#   bash run_baselines_swb.sh
#
# Greyhound/XPUTimer：若 $LOCAL_CODE/{greyhound,xputimer}/*.so 缺失，
# 本脚本会先做 preflight，记录 PENDING 步骤到 baseline_cost.jsonl，不写 ENV-BLOCKED。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWB="$(cd "$HERE/.." && pwd)"
CASE_ID="${CASE_ID:?need CASE_ID}"
RUN_ID="${RUN_ID:?need RUN_ID}"
PODS="${PODS:?need PODS}"
KUBECONFIG="${KUBECONFIG:?need KUBECONFIG}"
LOCAL_CODE="${LOCAL_CODE:-/workspace/probe-bundle/swb}"
LOCAL_RESULT_ROOT="${LOCAL_RESULT_ROOT:-/Users/yinjinrun/Codespace/myportal/results/muxi-h3c/$RUN_ID}"
COST_LOG="$LOCAL_RESULT_ROOT/baseline_cost.jsonl"
mkdir -p "$LOCAL_RESULT_ROOT"

export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7897}"
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7897}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"
unset ALL_PROXY || true

MASTER="${PODS%%,*}"
preflight_so() {
  local kind="$1" rel="$2"
  if kubectl --kubeconfig="$KUBECONFIG" -n "${NS:-default}" exec "$MASTER" -- \
      test -f "$LOCAL_CODE/$rel" 2>/dev/null; then
    echo "$kind:so_ok"
    return 0
  fi
  echo "$kind:so_missing"
  printf '%s\n' "{\"ts\":$(date +%s),\"case\":\"$CASE_ID\",\"tool\":\"$kind\",\"status\":\"PENDING_MISSING_SO\",\"path\":\"$LOCAL_CODE/$rel\",\"note\":\"穷尽前不写 ENV-BLOCKED\"}" >> "$COST_LOG"
  return 1
}

# Dynolog：记录触发协议（oracle），本轮若无 daemon 则记 PENDING
printf '%s\n' "{\"ts\":$(date +%s),\"case\":\"$CASE_ID\",\"tool\":\"Dynolog\",\"status\":\"PENDING\",\"trigger\":\"oracle_window\",\"note\":\"oracle 触发不算检出率/TTD\"}" >> "$COST_LOG"

CFGS=()
if preflight_so Greyhound "greyhound/libmcclprobe.so"; then
  CFGS+=(C3_greyhound)
else
  echo "SKIP C3_greyhound (so missing) — 继续穷尽接入路径见 baselines/README.md"
fi
if preflight_so XPUTimer "xputimer/libxpu_timer_metax.so"; then
  CFGS+=(C4_xputimer)
else
  echo "SKIP C4_xputimer (so missing)"
fi
# Flight Recorder：纯 env，总能跑
CFGS+=(C5_flight_recorder)

if [ "${#CFGS[@]}" -eq 0 ]; then
  echo "no online baseline configs to run"
  exit 0
fi

ABC_JOIN=$(IFS=,; echo "${CFGS[*]}")
echo "Running baseline configs: $ABC_JOIN"
CASE_ID="$CASE_ID" RUN_ID="$RUN_ID" PODS="$PODS" KUBECONFIG="$KUBECONFIG" \
  NNODES="${NNODES:-8}" NPROC="${NPROC:-8}" ITERS="${ITERS:-500}" WARMUP="${WARMUP:-50}" \
  ABC_CONFIGS="$ABC_JOIN" DOSE="${DOSE:-loud}" ENSURE_SHM=0 \
  LOCAL_CODE="$LOCAL_CODE" LOCAL_RESULT_ROOT="$LOCAL_RESULT_ROOT" \
  bash "$SWB/run_case_swb.sh"

# 离线 StragglerAnalysis 转换（若有 C1 结果）
C1_DIR=$(find "$LOCAL_RESULT_ROOT" -type d -path '*/round_1/C1_inject_none/ranks' 2>/dev/null | head -1 || true)
if [ -n "$C1_DIR" ]; then
  OUT_PARQUET="$LOCAL_RESULT_ROOT/straggler/trace-C1.parquet"
  mkdir -p "$(dirname "$OUT_PARQUET")"
  python3 "$HERE/convert_timeline_to_straggler.py" \
    --ranks-dir "$C1_DIR" --out "$OUT_PARQUET" \
    --meta-out "$LOCAL_RESULT_ROOT/straggler/meta-C1.yaml" \
    2>&1 | tee "$LOCAL_RESULT_ROOT/straggler/convert.log" || true
  printf '%s\n' "{\"ts\":$(date +%s),\"case\":\"$CASE_ID\",\"tool\":\"StragglerAnalysis\",\"status\":\"OFFLINE_CONVERT\",\"out\":\"$OUT_PARQUET\"}" >> "$COST_LOG"
fi

echo "baselines done; cost log → $COST_LOG"
