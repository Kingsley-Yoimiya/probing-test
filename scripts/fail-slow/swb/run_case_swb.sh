#!/usr/bin/env bash
# run_case_swb.sh — SW-B 独立 ABC（+可选 baselines）编排
#
# CASE_ID=P2-SW-B|P1-SW-B
# 默认 8 节点 × 8 卡、GPT-2 124M、500 measure + 50 warmup。
#
# 隔离约定：
#   LOCAL_CODE=/workspace/probe-bundle/swb
#   POD_PREFIX 建议 yjr-swb（由调用方保证 PODS）
#   不改父目录 pipeline / train_bench_probe
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PARENT="$(cd "$HERE/.." && pwd)"

# 门禁：/dev/shm 默认 64Mi 会 SIGBUS
if [ "${ENSURE_SHM:-1}" = "1" ] && [ -f "$PARENT/ensure_shm.sh" ]; then
  PODS="$PODS" KUBECONFIG="$KUBECONFIG" NS="${NS:-default}" SHM_SIZE="${SHM_SIZE:-32G}" \
    bash "$PARENT/ensure_shm.sh" || echo "WARN: ensure_shm failed (继续跑可能 SIGBUS)" >&2
fi

CASE_ID="${CASE_ID:?need CASE_ID=P2-SW-B|P1-SW-B}"
RUN_ID="${RUN_ID:?need RUN_ID (timestamped)}"
PODS="${PODS:?need PODS csv}"
KUBECONFIG="${KUBECONFIG:?need KUBECONFIG}"
NS="${NS:-default}"
NNODES="${NNODES:-8}"
NPROC="${NPROC:-8}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
ROUNDS="${ROUNDS:-1}"
SEED="${SEED:-42}"
MODEL="${MODEL:-gpt2}"
MODE="${MODE:-gpu_bound}"
LOCAL_CODE="${LOCAL_CODE:-/workspace/probe-bundle/swb}"
LOCAL_OUT="${LOCAL_OUT:-/workspace/probe-bundle/swb/out}"
LOCAL_RESULT_ROOT="${LOCAL_RESULT_ROOT:-/Users/yinjinrun/Codespace/myportal/results/muxi-h3c/$RUN_ID}"
ACCEPT_GATE="${ACCEPT_GATE:-0}"
ACCEPT_SCRIPT="${ACCEPT_SCRIPT:-$PARENT/accept_loud.py}"
SIDECAR_WARMUP="${SIDECAR_WARMUP:-8}"
export ITERS WARMUP SIDECAR_WARMUP

if [ "$ITERS" -lt 350 ] 2>/dev/null; then
  echo "WARN: ITERS=$ITERS < 350；注入窗/验收不可信" >&2
fi

# 剂量：INJECT_ARGS 可由 DOSE=loud|quiet|masked 或显式 INJECT_ARGS 覆盖
DOSE="${DOSE:-loud}"
case "$CASE_ID" in
  P2-SW-B)
    CASE="P2-SW-B"; INJECT_KIND="mccl_algo"
    case "$DOSE" in
      quiet)  INJECT_ARGS="${INJECT_ARGS:-algo=Ring,proto=Simple,min_ch=8,max_ch=8}"
              ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}" ;;
      masked) INJECT_ARGS="${INJECT_ARGS:-algo=Ring,proto=Simple,min_ch=16,max_ch=16}"
              ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.05}" ;;
      *)      INJECT_ARGS="${INJECT_ARGS:-algo=Ring,proto=Simple,min_ch=4,max_ch=4}"
              ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}" ;;
    esac
    MODE="${MODE:-gpu_bound}"
    ;;
  P1-SW-B)
    CASE="P1-SW-B"; INJECT_KIND="rare_shape"
    case "$DOSE" in
      quiet)  INJECT_ARGS="${INJECT_ARGS:-rare_seq=1280,every=4}"
              ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}" ;;
      masked) INJECT_ARGS="${INJECT_ARGS:-rare_seq=1152,every=8}"
              ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.05}" ;;
      *)      INJECT_ARGS="${INJECT_ARGS:-rare_seq=1536,every=1}"
              ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}" ;;
    esac
    MODE="${MODE:-gpu_bound}"
    ;;
  *) echo "unsupported CASE_ID=$CASE_ID (P2-SW-B|P1-SW-B)" >&2; exit 2 ;;
esac

run_config() {
  local config="$1"
  local group_id="$2"
  echo "========== $CASE / $config (GROUP_ID=$group_id) =========="
  CASE="$CASE" INJECT_KIND="$INJECT_KIND" INJECT_ARGS="$INJECT_ARGS" \
    RUN_ID="$RUN_ID" RUN_DIR="$LOCAL_OUT" LOCAL_CODE="$LOCAL_CODE" LOCAL_OUT="$LOCAL_OUT" \
    PODS="$PODS" NNODES="$NNODES" NPROC="$NPROC" ITERS="$ITERS" WARMUP="$WARMUP" \
    ROUNDS="$ROUNDS" SEED="$SEED" MODEL="$MODEL" MODE="$MODE" LOCAL_FS=1 \
    GROUP_ID="$group_id" CONFIGS_ONLY="$config" KUBECONFIG="$KUBECONFIG" NS="$NS" \
    SIDECAR_WARMUP="$SIDECAR_WARMUP" \
    CKPT_EVERY="${CKPT_EVERY:-100}" FLUSH_EVERY="${FLUSH_EVERY:-5}" \
    bash "$HERE/pipeline_swb.sh"
}

pull_results() {
  IFS=',' read -r -a POD_ARRAY <<< "$PODS"
  DEST="$LOCAL_RESULT_ROOT/$CASE"
  mkdir -p "$DEST/by_pod"
  for pod in "${POD_ARRAY[@]}"; do
    pod_dest="$DEST/by_pod/$pod"
    mkdir -p "$pod_dest"
    echo "↓ $pod:$LOCAL_OUT/$CASE → $pod_dest"
    kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec -i "$pod" -- \
      bash -c "tar -C '$LOCAL_OUT/$CASE' -cf - ." > "$pod_dest/.pull.tar"
    tar -C "$pod_dest" -xf "$pod_dest/.pull.tar"
    rm -f "$pod_dest/.pull.tar"
  done
  echo "DONE: $DEST (abc_rc=$abc_rc)"
}

if [ -n "${ABC_CONFIGS:-}" ]; then
  echo "ABC_CONFIGS=${ABC_CONFIGS} (override; unset for default C0,C1,C2)"
  IFS=',' read -r -a RUN_CFGS <<< "${ABC_CONFIGS}"
else
  RUN_CFGS=(C0_baseline C1_inject_none C2_probing)
fi

abc_rc=0
ran_c1=0
for cfg in "${RUN_CFGS[@]}"; do
  case "$cfg" in
    C0_baseline) gid=0 ;;
    C1_inject_none) gid=1 ;;
    C2_probing) gid=2 ;;
    C3_greyhound) gid=3 ;;
    C4_xputimer) gid=4 ;;
    C5_flight_recorder) gid=5 ;;
    *) gid=0 ;;
  esac
  if [ "$cfg" = "C2_probing" ] && [ "$ACCEPT_GATE" = "1" ] && [ "$ran_c1" = "1" ]; then
    pull_results || true
    if ! python3 "$ACCEPT_SCRIPT" \
        --result-root "$LOCAL_RESULT_ROOT" \
        --case "$CASE" \
        --min-ratio "$ACCEPT_MIN_RATIO" \
        --configs C0_baseline,C1_inject_none \
        --write-md "$LOCAL_RESULT_ROOT/acceptance_${CASE}.md"; then
      echo "ACCEPT_GATE: $CASE C1/C0 < $ACCEPT_MIN_RATIO → skip C2"
      echo "$CASE" >> "$LOCAL_RESULT_ROOT/injection_ineffective.txt"
      abc_rc=1
      break
    fi
  fi
  run_config "$cfg" "$gid" || abc_rc=1
  [ "$cfg" = "C1_inject_none" ] && ran_c1=1
done

pull_results
python3 "$ACCEPT_SCRIPT" \
  --result-root "$LOCAL_RESULT_ROOT" \
  --case "$CASE" \
  --min-ratio "$ACCEPT_MIN_RATIO" \
  --write-md "$LOCAL_RESULT_ROOT/acceptance_${CASE}.md" \
  || true
exit "$abc_rc"
