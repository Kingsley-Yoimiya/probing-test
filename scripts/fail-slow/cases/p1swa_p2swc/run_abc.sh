#!/usr/bin/env bash
# 隔离入口：P1-SW-A（2A）/ P2-SW-C（5C）→ pipeline_local.sh（不改共享 abc）。
#
# 用法:
#   source cases/p1swa_p2swc/env.sh
#   CASE_ID=P1-SW-A RUN_ID=... PODS=$PODS_PILOT NNODES=2 \
#     ABC_CONFIGS=C0_baseline,C1_inject_none bash cases/p1swa_p2swc/run_abc.sh
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$CASE_DIR/env.sh"
HERE="$(cd "$CASE_DIR/../.." && pwd)"
PIPE="$CASE_DIR/pipeline_local.sh"

CASE_ID="${CASE_ID:?need CASE_ID=P1-SW-A|P2-SW-C}"
RUN_ID="${RUN_ID:?need RUN_ID}"
PODS="${PODS:-${PODS_PILOT:?need PODS}}"
KUBECONFIG="${KUBECONFIG:?}"
NS="${NS:-default}"
NNODES="${NNODES:-2}"
NPROC="${NPROC:-8}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
ROUNDS="${ROUNDS:-1}"
SEED="${SEED:-42}"
MODEL="${MODEL:-gpt2}"
LOCAL_CODE="${LOCAL_CODE:-/workspace/probe-bundle}"
LOCAL_OUT="${LOCAL_OUT:-/workspace/probe-bundle/out}"
LOCAL_RESULT_ROOT="${LOCAL_RESULT_ROOT:-/Users/yinjinrun/Codespace/myportal/results/muxi-h3c/$RUN_ID}"
ACCEPT_GATE="${ACCEPT_GATE:-0}"
ACCEPT_SCRIPT="${ACCEPT_SCRIPT:-$HERE/accept_loud.py}"
SIDECAR_WARMUP="${SIDECAR_WARMUP:-8}"
export ITERS WARMUP SIDECAR_WARMUP KUBECONFIG

if [ "${ENSURE_SHM:-1}" = "1" ] && [ -f "$HERE/ensure_shm.sh" ]; then
  PODS="$PODS" KUBECONFIG="$KUBECONFIG" NS="$NS" SHM_SIZE="${SHM_SIZE:-32G}" \
    bash "$HERE/ensure_shm.sh" || echo "WARN: ensure_shm failed" >&2
fi

case "$CASE_ID" in
  P1-SW-A|2a|2A)
    CASE="P1-SW-A"; INJECT_KIND="2a"
    INJECT_ARGS="${INJECT_ARGS:-}"
    MODE="${MODE:-gpu_bound}"
    ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"
    export INLINE_2A_CHUNKS="${INLINE_2A_CHUNKS:-12}"
    export INLINE_2A_STALL_MB="${INLINE_2A_STALL_MB:-768}"
    export INLINE_2A_STALL_S="${INLINE_2A_STALL_S:-0.25}"
    SYNC_TRAIN=1
    ;;
  P2-SW-C|5c|5C)
    CASE="P2-SW-C"; INJECT_KIND="5c"
    INJECT_ARGS="${INJECT_ARGS:-}"
    MODE="${MODE:-gpu_bound}"
    ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}"
    export TOPO_EXTRA_AR="${TOPO_EXTRA_AR:-16}"
    SYNC_TRAIN=2
    ;;
  *) echo "unsupported CASE_ID=$CASE_ID (P1-SW-A / P2-SW-C)" >&2; exit 2 ;;
esac

# 同步隔离训练脚本
if [ "${SYNC_TRAIN:-0}" = "1" ]; then
  echo "sync train_bench_probe_2a.py → pods as train_bench_probe.py"
  IFS=',' read -r -a _pods <<< "$PODS"
  for _p in "${_pods[@]}"; do
    kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec -i "$_p" -- \
      bash -c "mkdir -p $LOCAL_CODE && cat > $LOCAL_CODE/train_bench_probe.py" \
      < "$CASE_DIR/train_bench_probe_2a.py" || echo "WARN: sync fail $_p" >&2
  done
elif [ "${SYNC_TRAIN:-0}" = "2" ]; then
  echo "sync train_bench_probe_topo.py → pods as train_bench_probe.py"
  IFS=',' read -r -a _pods <<< "$PODS"
  for _p in "${_pods[@]}"; do
    kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec -i "$_p" -- \
      bash -c "mkdir -p $LOCAL_CODE && cat > $LOCAL_CODE/train_bench_probe.py" \
      < "$CASE_DIR/train_bench_probe_topo.py" || echo "WARN: sync fail $_p" >&2
  done
fi

run_config() {
  local config="$1" group_id="$2"
  echo "========== $CASE / $config (GROUP_ID=$group_id) =========="
  CASE="$CASE" INJECT_KIND="$INJECT_KIND" INJECT_ARGS="$INJECT_ARGS" \
    RUN_ID="$RUN_ID" RUN_DIR="$LOCAL_OUT" LOCAL_CODE="$LOCAL_CODE" LOCAL_OUT="$LOCAL_OUT" \
    PODS="$PODS" NNODES="$NNODES" NPROC="$NPROC" ITERS="$ITERS" WARMUP="$WARMUP" \
    ROUNDS="$ROUNDS" SEED="$SEED" MODEL="$MODEL" MODE="$MODE" LOCAL_FS=1 \
    GROUP_ID="$group_id" CONFIGS_ONLY="$config" KUBECONFIG="$KUBECONFIG" NS="$NS" \
    SIDECAR_WARMUP="$SIDECAR_WARMUP" SIDECAR_LOCAL_RANK="${SIDECAR_LOCAL_RANK:-7}" \
    CKPT_EVERY="${CKPT_EVERY:-100}" FLUSH_EVERY="${FLUSH_EVERY:-5}" \
    INLINE_2A_CHUNKS="${INLINE_2A_CHUNKS:-12}" INLINE_2A_STALL_MB="${INLINE_2A_STALL_MB:-768}" \
    INLINE_2A_STALL_S="${INLINE_2A_STALL_S:-0.25}" \
    TOPO_EXTRA_AR="${TOPO_EXTRA_AR:-16}" \
    bash "$PIPE"
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
      bash -c "tar -C '$LOCAL_OUT/$CASE' -cf - . 2>/dev/null" > "$pod_dest/.pull.tar" || true
    if [ -s "$pod_dest/.pull.tar" ]; then
      tar -C "$pod_dest" -xf "$pod_dest/.pull.tar" 2>/dev/null || true
    fi
    rm -f "$pod_dest/.pull.tar"
  done
  echo "DONE: $DEST (abc_rc=$abc_rc)"
}

if [ -n "${ABC_CONFIGS:-}" ]; then
  echo "ABC_CONFIGS=${ABC_CONFIGS}"
  IFS=',' read -r -a RUN_CFGS <<< "${ABC_CONFIGS}"
else
  RUN_CFGS=(C0_baseline C1_inject_none C2_probing C3_greyhound C4_xputimer C5_flight_recorder)
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
      echo "ACCEPT_GATE: $CASE C1/C0 < $ACCEPT_MIN_RATIO → skip remaining"
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

# 2A 趋势线索（不读 ground-truth 窗；仅看 mem gap / stall 字段是否可分）
if [ "$CASE" = "P1-SW-A" ] && [ -f "$CASE_DIR/score_trend.py" ]; then
  python3 "$CASE_DIR/score_trend.py" --result-root "$LOCAL_RESULT_ROOT" --case "$CASE" \
    --write-md "$LOCAL_RESULT_ROOT/trend_${CASE}.md" || true
fi

exit "$abc_rc"
