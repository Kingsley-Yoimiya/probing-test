#!/usr/bin/env bash
# 单 case SOP：顺序跑 A(基线) / B(注入) / C(注入+Probing)，并立即回拉 pod 本地结果。
# P3-HW-C overlay：OUTLINE 7C 本地盘读延迟（dm-delay）；≠ campaign ecc；≠ EXT-B fio 争用
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PARENT="$(cd "$HERE/../.." && pwd)"
if [ "${ENSURE_SHM:-1}" = "1" ] && [ -f "$HERE/ensure_shm.sh" ]; then
  PODS="$PODS" KUBECONFIG="$KUBECONFIG" NS="${NS:-default}" SHM_SIZE="${SHM_SIZE:-32G}" \
    bash "$PARENT/ensure_shm.sh" || echo "WARN: ensure_shm failed (继续跑可能 SIGBUS)" >&2
fi
CASE_ID="${CASE_ID:?need CASE_ID}"
RUN_ID="${RUN_ID:?need RUN_ID (timestamped)}"
PODS="${PODS:?need PODS csv}"
KUBECONFIG="${KUBECONFIG:?need KUBECONFIG}"
NS="${NS:-default}"
NNODES="${NNODES:-2}"
NPROC="${NPROC:-8}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
ROUNDS="${ROUNDS:-1}"
SEED="${SEED:-42}"
MODEL="${MODEL:-gpt2}"
MODE="${MODE:-}"
LOCAL_CODE="${LOCAL_CODE:-/workspace/probe-bundle}"
LOCAL_OUT="${LOCAL_OUT:-/workspace/probe-bundle/out}"
LOCAL_RESULT_ROOT="${LOCAL_RESULT_ROOT:-/Users/yinjinrun/Codespace/myportal/results/muxi-mohe/$RUN_ID}"
ACCEPT_GATE="${ACCEPT_GATE:-0}"
ACCEPT_SCRIPT="${ACCEPT_SCRIPT:-$PARENT/accept_loud.py}"
SIDECAR_WARMUP="${SIDECAR_WARMUP:-8}"
export ITERS WARMUP SIDECAR_WARMUP
if [ "$ITERS" -lt 350 ] 2>/dev/null; then
  echo "WARN: ITERS=$ITERS < 350；cube/hbm 注入窗/预热不足，结果不可信" >&2
fi

case "$CASE_ID" in
  P3-HW-C|7c)
    # OUTLINE 7C：本地盘读延迟（dm-delay mid）；≠ run_campaign ecc；≠ EXT-B stress_io
    CASE="P3-HW-C"; INJECT_KIND="disk_lat"
    INJECT_ARGS="${INJECT_ARGS:-delay_ms=50}"
    MODE="${MODE:-host_bound}"
    ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}"
    DISK_DELAY_MS="${DISK_DELAY_MS:-50}"
    DISK_DELAY_IMG_MB="${DISK_DELAY_IMG_MB:-512}"
    IO_PAYLOAD="${IO_PAYLOAD:-/mnt/p3hwc_data/payload.bin}"
    IO_READ_KB="${IO_READ_KB:-1024}"
    DL_WORKERS="${DL_WORKERS:-0}"
    export DISK_DELAY_MS DISK_DELAY_IMG_MB IO_PAYLOAD IO_READ_KB DL_WORKERS
    ;;
  *) echo "unsupported CASE_ID=$CASE_ID (P3-HW-C primary)" >&2; exit 2 ;;
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
    CKPT_DIR="${CKPT_DIR:-/workspace/probe-bundle/ckpt}" \
    IO_PAYLOAD="${IO_PAYLOAD:-}" IO_READ_KB="${IO_READ_KB:-0}" \
    IO_STRESS_DIR="${IO_STRESS_DIR:-/workspace/probe-bundle/io_stress}" \
    DL_WORKERS="${DL_WORKERS:-0}" \
    DISK_DELAY_MS="${DISK_DELAY_MS:-50}" \
    DISK_DELAY_IMG_MB="${DISK_DELAY_IMG_MB:-512}" \
    SIDECAR_LOCAL_RANK="${SIDECAR_LOCAL_RANK:-7}" \
    bash "${PIPELINE_SH:-$HERE/pipeline_disk_lat_mid.sh}"
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
  echo "ABC_CONFIGS=${ABC_CONFIGS} (override; unset for full A/B/C)"
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
      echo "ACCEPT_GATE: $CASE C1/C0 < $ACCEPT_MIN_RATIO → skip C2 (injection_ineffective candidate)"
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
