#!/usr/bin/env bash
# 单 case SOP：顺序跑 A(基线) / B(注入) / C(注入+Probing)，并立即回拉 pod 本地结果。
#
# 必填：CASE_ID=P1-EXT-A（或 3a/3b） RUN_ID=<timestamp> PODS=<pod0,pod1> KUBECONFIG=<mohe kubeconfig>
# 默认 2 节点 × 8 卡、GPT-2 124M、500 measure steps + 50 warmup。
#
# 可选：
#   ABC_CONFIGS=C0_baseline,C1_inject_none     # 只跑部分 config（smoke）
#   ACCEPT_GATE=1                             # C1 验收不过则跳过 C2
#   ACCEPT_SCRIPT=accept_loud.py
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# 门禁：/dev/shm 默认 64Mi 会 SIGBUS；privileged pod 上 remount 到 32G
if [ "${ENSURE_SHM:-1}" = "1" ] && [ -f "$HERE/ensure_shm.sh" ]; then
  PODS="$PODS" KUBECONFIG="$KUBECONFIG" NS="${NS:-default}" SHM_SIZE="${SHM_SIZE:-32G}" \
    bash "$HERE/ensure_shm.sh" || echo "WARN: ensure_shm failed (继续跑可能 SIGBUS)" >&2
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
ACCEPT_SCRIPT="${ACCEPT_SCRIPT:-$HERE/accept_loud.py}"
SIDECAR_WARMUP="${SIDECAR_WARMUP:-8}"
# 导出，避免 pipeline 子进程读到父 shell 里更短的残留 ITERS
export ITERS WARMUP SIDECAR_WARMUP
if [ "$ITERS" -lt 350 ] 2>/dev/null; then
  echo "WARN: ITERS=$ITERS < 350；cube/hbm 注入窗/预热不足，结果不可信" >&2
fi

case "$CASE_ID" in
  P1-EXT-A|3a)
    CASE="P1-EXT-A"; INJECT_KIND="cube"
    INJECT_ARGS="${INJECT_ARGS:-duty=0.9,size=8192}"
    MODE="${MODE:-gpu_bound}"
    ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.8}"
    ;;
  P1-EXT-B|3b)
    CASE="P1-EXT-B"; INJECT_KIND="hbm"
    INJECT_ARGS="${INJECT_ARGS:-duty=0.9,size=8192}"
    MODE="${MODE:-gpu_bound}"
    ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.6}"
    ;;
  P3-EXT-A|9a)
    CASE="P3-EXT-A"; INJECT_KIND="stress_cpu"
    INJECT_ARGS="${INJECT_ARGS:-}"
    MODE="${MODE:-host_bound}"
    ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"
    ;;
  P3-EXT-B|9b)
    CASE="P3-EXT-B"; INJECT_KIND="stress_io"
    INJECT_ARGS="${INJECT_ARGS:-}"
    MODE="${MODE:-host_bound}"
    ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"
    # Loud IO 咬合：加密 ckpt + 同盘 payload 读（fio 否则咬不到 step_ms）
    CKPT_EVERY="${CKPT_EVERY:-20}"
    FLUSH_EVERY="${FLUSH_EVERY:-1}"
    IO_PAYLOAD="${IO_PAYLOAD:-/workspace/probe-bundle/io_stress/payload.bin}"
    IO_READ_KB="${IO_READ_KB:-1024}"
    IO_STRESS_DIR="${IO_STRESS_DIR:-/workspace/probe-bundle/io_stress}"
    export CKPT_EVERY FLUSH_EVERY IO_PAYLOAD IO_READ_KB IO_STRESS_DIR
    ;;
  P3-SW-A|8a)
    CASE="P3-SW-A"; INJECT_KIND="8a"
    INJECT_ARGS="${INJECT_ARGS:-}"
    MODE="${MODE:-host_bound}"
    ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"
    ;;
  *) echo "unsupported CASE_ID=$CASE_ID (P1-EXT-A/B, P3-EXT-A/B, P3-SW-A)" >&2; exit 2 ;;
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
    IO_PAYLOAD="${IO_PAYLOAD:-}" IO_READ_KB="${IO_READ_KB:-0}" \
    IO_STRESS_DIR="${IO_STRESS_DIR:-/workspace/probe-bundle/io_stress}" \
    bash "$HERE/run_case_pipeline_v4.sh"
}

pull_results() {
  echo "ENV-BLOCKED: Greyhound (NCCL/Redis/Docker dependency); XPUTimer (NCCL<=2.21.5/Bazel dependency)"
  IFS=',' read -r -a POD_ARRAY <<< "$PODS"
  for pod in "${POD_ARRAY[@]}"; do
    kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec "$pod" -- bash -c \
      "mkdir -p '$LOCAL_OUT/$CASE'; printf '%s\n' 'Greyhound: ENV-BLOCKED' 'XPUTimer: ENV-BLOCKED' > '$LOCAL_OUT/$CASE/env_blocked_tools.txt'"
  done
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

# 默认 A/B/C；smoke 可设 ABC_CONFIGS=C0_baseline,C1_inject_none
# 注意：父 shell 若 export 过 ABC_CONFIGS 会污染全量跑——需要全量时请 unset ABC_CONFIGS
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
    *) gid=0 ;;
  esac
  # C2：可选闸门——C1 未达标则跳过，避免无效注入浪费 Probing 轮
  if [ "$cfg" = "C2_probing" ] && [ "$ACCEPT_GATE" = "1" ] && [ "$ran_c1" = "1" ]; then
    # 先临时回拉 C0/C1 供验收（最终还会再拉全量）
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
# 终态验收表（有 C0/C1 即可；有 C2 一并写上）
python3 "$ACCEPT_SCRIPT" \
  --result-root "$LOCAL_RESULT_ROOT" \
  --case "$CASE" \
  --min-ratio "$ACCEPT_MIN_RATIO" \
  --write-md "$LOCAL_RESULT_ROOT/acceptance_${CASE}.md" \
  || true
exit "$abc_rc"
