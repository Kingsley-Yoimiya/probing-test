#!/usr/bin/env bash
# P1-SW-C / P1-EXT-C 隔离 launcher（64 卡战役）
# 不改公共 run_case_abc.sh；走 overlay pipeline_p1c.sh + pod-local train/sidecar。
#
# 用法:
#   CASE_ID=P1-SW-C PODS=... KUBECONFIG=... RUN_ID=... \
#     NNODES=8 NPROC=8 bash run_p1c.sh
#   CASE_ID=P1-EXT-C ... bash run_p1c.sh
#
# 可选:
#   ABC_CONFIGS=C0_baseline,C1_inject_none          # pilot
#   ABC_CONFIGS=C0_baseline,C1_inject_none,C2_probing,C3_greyhound,C4_xputimer,C5_flight_recorder
#   ACCEPT_GATE=1 ACCEPT_MIN_RATIO=1.3 ITERS=500
set -euo pipefail

OVERLAY="$(cd "$(dirname "$0")" && pwd)"
HERE="$(cd "$OVERLAY/../.." && pwd)"   # scripts/fail-slow

CASE_ID="${CASE_ID:?need CASE_ID=P1-SW-C|P1-EXT-C}"
RUN_ID="${RUN_ID:?need RUN_ID}"
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
LOCAL_CODE="${LOCAL_CODE:-/workspace/probe-bundle}"
LOCAL_OUT="${LOCAL_OUT:-/workspace/probe-bundle/out}"
LOCAL_RESULT_ROOT="${LOCAL_RESULT_ROOT:-/Users/yinjinrun/Codespace/myportal/results/muxi-h3c/$RUN_ID}"
ACCEPT_GATE="${ACCEPT_GATE:-0}"
ACCEPT_SCRIPT="${ACCEPT_SCRIPT:-$HERE/accept_loud.py}"
SIDECAR_WARMUP="${SIDECAR_WARMUP:-8}"
ENSURE_SHM="${ENSURE_SHM:-1}"

export ITERS WARMUP SIDECAR_WARMUP KUBECONFIG

case "$CASE_ID" in
  P1-SW-C|2c)
    CASE="P1-SW-C"
    INJECT_KIND="2c"
    INJECT_ARGS="${INJECT_ARGS:-}"
    ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"
    ;;
  P1-EXT-C|3c)
    CASE="P1-EXT-C"
    INJECT_KIND="3c"
    INJECT_ARGS="${INJECT_ARGS:-}"
    ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"
    ;;
  *)
    echo "unsupported CASE_ID=$CASE_ID (want P1-SW-C|P1-EXT-C)" >&2
    exit 2
    ;;
esac

if [ "$ENSURE_SHM" = "1" ] && [ -f "$HERE/ensure_shm.sh" ]; then
  PODS="$PODS" KUBECONFIG="$KUBECONFIG" NS="$NS" SHM_SIZE="${SHM_SIZE:-32G}" \
    bash "$HERE/ensure_shm.sh" || echo "WARN: ensure_shm failed" >&2
fi

mkdir -p "$LOCAL_RESULT_ROOT/logs" "$LOCAL_RESULT_ROOT"
echo "$PODS" > "$LOCAL_RESULT_ROOT/pods.csv"
cat > "$LOCAL_RESULT_ROOT/manifest_overlay.yaml" <<EOF
case_id: $CASE
inject_kind: $INJECT_KIND
run_id: $RUN_ID
nnodes: $NNODES
nproc: $NPROC
world: $((NNODES * NPROC))
seed: $SEED
iters: $ITERS
warmup: $WARMUP
mode: $MODE
pods: $PODS
overlay: agent_overlays/p1c-20260724
note: "OUTLINE 2C via INLINE compile; 3C via sidecar timeslice; isolated overlay"
EOF

sync_overlay_to_pods() {
  if [ "${SKIP_SYNC:-0}" = "1" ]; then echo "SKIP_SYNC=1"; return 0; fi
  echo "sync overlay train/sidecar → pods (isolated)"
  IFS=',' read -r -a POD_ARRAY <<< "$PODS"
  for pod in "${POD_ARRAY[@]}"; do
    ok=0
    for try in 1 2 3 4 5; do
      kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec "$pod" -- \
        bash -c "test -f $LOCAL_CODE/train_bench_probe.py.bak_p1c || cp -f $LOCAL_CODE/train_bench_probe.py $LOCAL_CODE/train_bench_probe.py.bak_p1c; test -f $LOCAL_CODE/sidecar_inject_v2.py.bak_p1c || cp -f $LOCAL_CODE/sidecar_inject_v2.py $LOCAL_CODE/sidecar_inject_v2.py.bak_p1c" \
        2>/dev/null || true
      if kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec -i "$pod" -- \
          bash -c "cat > $LOCAL_CODE/train_bench_probe.py" < "$OVERLAY/train_bench_p1c.py" \
        && kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec -i "$pod" -- \
          bash -c "cat > $LOCAL_CODE/sidecar_inject_v2.py" < "$OVERLAY/sidecar_inject_p1c.py"; then
        echo "  synced $pod"
        ok=1
        break
      fi
      echo "  retry $try $pod"; sleep 2
    done
    [ "$ok" = "1" ] || { echo "FATAL: sync failed $pod"; exit 3; }
  done
}

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
    INLINE_2C_EVERY="${INLINE_2C_EVERY:-1}" INLINE_2C_N="${INLINE_2C_N:-1536}" \
    SIDECAR_3C_NPROC="${SIDECAR_3C_NPROC:-6}" SIDECAR_3C_MAT="${SIDECAR_3C_MAT:-4096}" \
    SIDECAR_3C_READY_S="${SIDECAR_3C_READY_S:-120}" \
    INJECT_START_MEASURE_STEP="${INJECT_START_MEASURE_STEP:-100}" \
    INJECT_STOP_MEASURE_STEP="${INJECT_STOP_MEASURE_STEP:-300}" \
    EARLY_GPU_SIDECAR="${EARLY_GPU_SIDECAR:-0}" \
    PRE_TRAIN_SIDECAR="${PRE_TRAIN_SIDECAR:-0}" \
    PRE_TRAIN_SETTLE_S="${PRE_TRAIN_SETTLE_S:-10}" \
    SIDECAR_SECONDS="${SIDECAR_SECONDS:-1800}" \
    bash "$OVERLAY/pipeline_p1c.sh"
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
      bash -c "tar -C '$LOCAL_OUT/$CASE' -cf - . 2>/dev/null || true" > "$pod_dest/.pull.tar" || true
    if [ -s "$pod_dest/.pull.tar" ]; then
      tar -C "$pod_dest" -xf "$pod_dest/.pull.tar" 2>/dev/null || true
    fi
    rm -f "$pod_dest/.pull.tar"
  done
  echo "DONE pull: $DEST"
}

sync_overlay_to_pods

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
    if [ "$CASE" = "P1-SW-C" ]; then
      if ! python3 "$OVERLAY/accept_p1swc_spike.py" \
          --result-root "$LOCAL_RESULT_ROOT" \
          --case "$CASE" \
          --write-md "$LOCAL_RESULT_ROOT/acceptance_${CASE}_spike.md"; then
        echo "ACCEPT_GATE(spike): $CASE not bitten → skip remaining"
        echo "$CASE" >> "$LOCAL_RESULT_ROOT/injection_ineffective.txt"
        abc_rc=1
        break
      fi
    elif ! python3 "$ACCEPT_SCRIPT" \
        --result-root "$LOCAL_RESULT_ROOT" \
        --case "$CASE" \
        --min-ratio "$ACCEPT_MIN_RATIO" \
        --configs C0_baseline,C1_inject_none \
        --write-md "$LOCAL_RESULT_ROOT/acceptance_${CASE}.md"; then
      echo "ACCEPT_GATE: $CASE C1/C0 < $ACCEPT_MIN_RATIO → skip remaining configs"
      echo "$CASE" >> "$LOCAL_RESULT_ROOT/injection_ineffective.txt"
      abc_rc=1
      break
    fi
  fi
  logf="$LOCAL_RESULT_ROOT/logs/${cfg}.log"
  set +e
  run_config "$cfg" "$gid" >"$logf" 2>&1
  cfg_rc=$?
  set -e
  # 若 jsonl 步数够，把 teardown FAIL 降级为可用（C0 曾出现）
  if [ "$cfg_rc" -ne 0 ]; then
    echo "WARN: $cfg pipeline rc=$cfg_rc (check jsonl completeness)" | tee -a "$logf"
    abc_rc=1
  fi
  tail -n 40 "$logf" || true
  [ "$cfg" = "C1_inject_none" ] && ran_c1=1
  pull_results || true
done

python3 "$ACCEPT_SCRIPT" \
  --result-root "$LOCAL_RESULT_ROOT" \
  --case "$CASE" \
  --min-ratio "$ACCEPT_MIN_RATIO" \
  --configs "$(IFS=,; echo "${RUN_CFGS[*]}")" \
  --write-md "$LOCAL_RESULT_ROOT/acceptance_${CASE}.md" \
  || true

exit "$abc_rc"
