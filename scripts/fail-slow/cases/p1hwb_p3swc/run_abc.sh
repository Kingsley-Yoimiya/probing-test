#!/usr/bin/env bash
# 隔离入口：P1-HW-B（1B）/ P3-SW-C（8C）→ 调共享 pipeline，不改 run_case_abc.sh。
#
# 用法:
#   source cases/p1hwb_p3swc/env.sh
#   CASE_ID=P1-HW-B RUN_ID=... PODS=... bash cases/p1hwb_p3swc/run_abc.sh
#
# 可选:
#   ABC_CONFIGS=C0_baseline,C1_inject_none
#   ACCEPT_GATE=1
#   USE_INLINE_HBM_RAMP=1   # 外挂 1b 咬空时：渐进 inline（见 train_bench_probe_1b_ramp.py）
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$CASE_DIR/env.sh"
HERE="$(cd "$CASE_DIR/../.." && pwd)"

CASE_ID="${CASE_ID:?need CASE_ID=P1-HW-B|P3-SW-C}"
RUN_ID="${RUN_ID:?need RUN_ID}"
PODS="${PODS:-${PODS_1B8C:?need PODS or PODS_1B8C}}"
KUBECONFIG="${KUBECONFIG:?}"
NS="${NS:-default}"
NNODES="${NNODES:-8}"
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
export ITERS WARMUP SIDECAR_WARMUP

if [ "${ENSURE_SHM:-1}" = "1" ] && [ -f "$HERE/ensure_shm.sh" ]; then
  PODS="$PODS" KUBECONFIG="$KUBECONFIG" NS="$NS" SHM_SIZE="${SHM_SIZE:-32G}" \
    bash "$HERE/ensure_shm.sh" || echo "WARN: ensure_shm failed" >&2
fi

case "$CASE_ID" in
  P1-HW-B|1b|1B)
    CASE="P1-HW-B"; INJECT_KIND="1b"
    INJECT_ARGS="${INJECT_ARGS:-}"
    MODE="${MODE:-gpu_bound}"
    ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"
    ;;
  P3-SW-C|8c|8C)
    CASE="P3-SW-C"; INJECT_KIND="8c"
    INJECT_ARGS="${INJECT_ARGS:-}"
    MODE="${MODE:-host_bound}"
    ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"
    # 隔离 Loud 监控泄漏：覆盖 pod 上 sidecar_inject_v2.py（不改共享仓文件）
    echo "P3-SW-C: sync sidecar_inject_v2_8c_loud.py → sidecar_inject_v2.py"
    IFS=',' read -r -a _pods <<< "$PODS"
    for _p in "${_pods[@]}"; do
      kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec -i "$_p" -- \
        bash -c "cat > $LOCAL_CODE/sidecar_inject_v2.py" < "$CASE_DIR/sidecar_inject_v2_8c_loud.py" || true
      # 确保训练脚本是共享原版（非 1b ramp）
      kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec -i "$_p" -- \
        bash -c "cat > $LOCAL_CODE/train_bench_probe.py" < "$HERE/train_bench_probe.py" || true
    done
    ;;
  *) echo "unsupported CASE_ID=$CASE_ID (only P1-HW-B / P3-SW-C in this isolated runner)" >&2; exit 2 ;;
esac

# MetaX：外挂 1b sidecar 与 pipeline 的 SIDECAR_START/injection.log 约定不齐，且 EXT-B 曾咬空。
# 默认走隔离渐进 inline（OUTLINE 1B 剂量旋钮）；USE_SIDECAR_1B=1 才强制外挂。
if [ "$INJECT_KIND" = "1b" ] && [ "${USE_SIDECAR_1B:-0}" != "1" ]; then
  echo "P1-HW-B: USE_INLINE_HBM_RAMP (isolated train_bench_probe_1b_ramp.py)"
  IFS=',' read -r -a _pods <<< "$PODS"
  for _p in "${_pods[@]}"; do
    kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec -i "$_p" -- \
      bash -c "cat > $LOCAL_CODE/train_bench_probe.py" < "$CASE_DIR/train_bench_probe_1b_ramp.py" || true
  done
  export USE_INLINE_HBM=1
  export INLINE_HBM_RAMP=1
  export INLINE_HBM_MB="${INLINE_HBM_MB:-512}"
  export INLINE_HBM_COPIES="${INLINE_HBM_COPIES:-6}"
  export INLINE_HBM_COPIES_MAX="${INLINE_HBM_COPIES_MAX:-48}"
  # pipeline 仅对 inject_kind=hbm 开 inline 分支
  INJECT_KIND="hbm"
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
    bash "$CASE_DIR/run_case_pipeline_v4_retry.sh"
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
  # 本战役默认含对手线；缺 .so 时 C3/C4 会失败并记 PENDING（见 baseline_notes.md）
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
exit "$abc_rc"
