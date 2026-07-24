#!/usr/bin/env bash
# run_group.sh — 单组 8 节点 × 8 卡端到端训练实验编排
#
# 从跳板 ais-cf3e61a5 运行（无 AFS 共享盘版本，用每 pod 本地 /workspace）。
# 用法:
#   run_group.sh <case> <detector> <pod_csv> <master_port> <out_tag>
#
# 参数:
#   case:        baseline | 3a | 9a | 8a
#   detector:    none | probing | greyhound | xputimer
#   pod_csv:     逗号分隔的 8 个 pod 名（node_rank 0..7）
#   master_port: torchrun 用的端口（各组不同避免冲突）
#   out_tag:     输出标签（如 baseline_none）
#
# 环境变量:
#   KUBECONFIG   — vcctl 用的 kubeconfig
#   SEED         — 随机种子（默认 42）
#   ITERS        — measure iterations（默认 30）
#   WARMUP       — warmup iterations（默认 10）
set -euo pipefail

CASE="${1:?usage: run_group.sh <case> <detector> <pod_csv> <master_port> <out_tag>}"
DETECTOR="${2:?}"
POD_CSV="${3:?}"
MASTER_PORT="${4:?}"
OUT_TAG="${5:?}"

SEED="${SEED:-42}"
ITERS="${ITERS:-30}"
WARMUP="${WARMUP:-10}"
NPROC=8
VCCTL="${VCCTL:-/usr/local/bin/vcctl}"
JOB="muxi-test-1"
BUNDLE="/workspace/baseline-exp"
OUT_DIR="$BUNDLE/output/$OUT_TAG"

# Parse pod list
IFS=',' read -r -a PODS <<< "$POD_CSV"
NNODES=${#PODS[@]}
if [[ "$NNODES" -ne 8 ]]; then
  echo "ERROR: need exactly 8 pods, got $NNODES" >&2; exit 1
fi

MASTER_ADDR="${PODS[0]}.$JOB"

echo "=========================================="
echo "RUN: case=$CASE detector=$DETECTOR tag=$OUT_TAG"
echo "  pods=${POD_CSV}"
echo "  master=$MASTER_ADDR:$MASTER_PORT"
echo "=========================================="

# Helper: exec on a pod
pod_exec() {
  local pod="$1"; shift
  $VCCTL pod exec "$pod" -- bash -c "$*"
}

# Step 1: Preflight — kill residual + create output dir on all pods
echo "[preflight] cleaning + mkdir..."
for pod in "${PODS[@]}"; do
  pod_exec "$pod" "pkill -f 'train_bench.py' 2>/dev/null; pkill -f 'inject_' 2>/dev/null; pkill -f 'stress-ng' 2>/dev/null; mkdir -p '$OUT_DIR/ranks'; true" &
done
wait
sleep 2

# Step 2: Start injection on victim (node_rank=0 = PODS[0])
VICTIM="${PODS[0]}"
if [[ "$CASE" != "baseline" ]]; then
  echo "[inject] starting case=$CASE on victim=$VICTIM"
  case "$CASE" in
    3a) pod_exec "$VICTIM" "bash '$BUNDLE/inject_3a.sh' start 0" ;;
    9a) pod_exec "$VICTIM" "bash '$BUNDLE/inject_9a.sh' start" ;;
    8a) pod_exec "$VICTIM" "bash '$BUNDLE/inject_8a.sh' start" ;;
    *)  echo "ERROR: unknown case $CASE" >&2; exit 1 ;;
  esac
  sleep 3  # let injection stabilize
fi

# Step 3: Build environment for detector
DETECT_ENV=""
case "$DETECTOR" in
  none)
    DETECT_ENV=""
    ;;
  probing)
    DETECT_ENV='export PROBING=2;'
    ;;
  greyhound)
    DETECT_ENV="export LD_PRELOAD='$BUNDLE/greyhound/libmcclprobe.so';"
    ;;
  xputimer)
    DETECT_ENV="export LD_PRELOAD='$BUNDLE/xputimer/libxpu_timer_metax.so'; export XPU_TIMER_DUMP_DIR='$OUT_DIR/xputimer_\${RANK}';"
    ;;
esac

# Step 4: Fire training on all nodes in parallel
echo "[fire] launching $NNODES nodes × $NPROC gpus = $((NNODES * NPROC)) ranks"
for ((r=0; r<NNODES; r++)); do
  pod="${PODS[$r]}"

  # Generate and exec launcher inline
  $VCCTL pod exec "$pod" -- bash -c "
cat > /tmp/launcher_${OUT_TAG}_node${r}.sh << 'LAUNCHEREOF'
#!/usr/bin/env bash
set -euo pipefail
export PATH=\"/opt/conda/bin:\${PATH}\"
export PYTHONUNBUFFERED=1
export NCCL_SOCKET_IFNAME=eth0
export MCCL_SOCKET_IFNAME=eth0
export NCCL_IB_HCA=xscale_0,xscale_1,xscale_2,xscale_3
export MCCL_IB_HCA=xscale_0,xscale_1,xscale_2,xscale_3
export NCCL_IB_GID_INDEX=5
export MCCL_IB_GID_INDEX=5
export MCCL_IB_TC=128
export MCCL_ENABLE_VSWITCH=1
export MCCL_PCIE_BUFFER_MODE=0
export FORCE_ACTIVE_WAIT=2
export NCCL_DEBUG=WARN
export MCCL_DEBUG=WARN
$DETECT_ENV

torchrun \\
  --nnodes=$NNODES \\
  --nproc_per_node=$NPROC \\
  --node_rank=$r \\
  --master_addr=$MASTER_ADDR \\
  --master_port=$MASTER_PORT \\
  $BUNDLE/train_bench.py \\
    --iters=$ITERS --warmup=$WARMUP --seed=$SEED \\
    --out-dir='$OUT_DIR/ranks' \\
  > '$OUT_DIR/node_${r}.log' 2>&1

EXIT_CODE=\$?
if [[ \$EXIT_CODE -eq 0 ]]; then
  touch '$OUT_DIR/node_${r}.done'
else
  echo \"EXIT_CODE=\$EXIT_CODE\" > '$OUT_DIR/node_${r}.fail'
fi
LAUNCHEREOF
chmod +x /tmp/launcher_${OUT_TAG}_node${r}.sh
setsid nohup bash /tmp/launcher_${OUT_TAG}_node${r}.sh > /dev/null 2>&1 &
" &
done
wait
echo "[fire] all $NNODES launchers dispatched"

# Step 5: Poll until done/fail (check from master pod since output is local)
echo "[poll] waiting for completion..."
MAX_WAIT=300
POLL_INTERVAL=5
elapsed=0
while true; do
  done_count=0
  fail_count=0
  for ((r=0; r<NNODES; r++)); do
    pod="${PODS[$r]}"
    if pod_exec "$pod" "test -f '$OUT_DIR/node_${r}.done'" 2>/dev/null; then
      done_count=$((done_count + 1))
    elif pod_exec "$pod" "test -f '$OUT_DIR/node_${r}.fail'" 2>/dev/null; then
      fail_count=$((fail_count + 1))
    fi
  done
  total=$((done_count + fail_count))
  echo "  [${elapsed}s] done=$done_count fail=$fail_count pending=$((NNODES - total))"
  if [[ $total -eq $NNODES ]]; then break; fi
  if [[ $elapsed -ge $MAX_WAIT ]]; then
    echo "TIMEOUT after ${MAX_WAIT}s" >&2; break
  fi
  sleep $POLL_INTERVAL
  elapsed=$((elapsed + POLL_INTERVAL))
done

# Step 6: Stop injection
if [[ "$CASE" != "baseline" ]]; then
  echo "[inject] stopping injection on victim=$VICTIM"
  case "$CASE" in
    3a) pod_exec "$VICTIM" "bash '$BUNDLE/inject_3a.sh' stop" 2>/dev/null || true ;;
    9a) pod_exec "$VICTIM" "bash '$BUNDLE/inject_9a.sh' stop" 2>/dev/null || true ;;
    8a) pod_exec "$VICTIM" "bash '$BUNDLE/inject_8a.sh' stop" 2>/dev/null || true ;;
  esac
fi

# Step 7: Write meta on master pod
pod_exec "${PODS[0]}" "cat > '$OUT_DIR/meta.json' << METAEOF
{
  \"case\": \"$CASE\",
  \"detector\": \"$DETECTOR\",
  \"pods\": \"$POD_CSV\",
  \"master_port\": $MASTER_PORT,
  \"seed\": $SEED,
  \"iters\": $ITERS,
  \"warmup\": $WARMUP,
  \"world_size\": $((NNODES * NPROC)),
  \"done_count\": $done_count,
  \"fail_count\": $fail_count,
  \"victim\": \"${PODS[0]}\",
  \"tag\": \"$OUT_TAG\"
}
METAEOF"

echo "[COMPLETE] $OUT_TAG: done=$done_count fail=$fail_count"
