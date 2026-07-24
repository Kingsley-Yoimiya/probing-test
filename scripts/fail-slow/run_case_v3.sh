#!/usr/bin/env bash
# run_case_v3.sh — 科学严谨的单 case pipeline（外部注入 + 3 轮重复）
#
# 用法: run_case_v3.sh <case_name> <inject_kind> <inject_args> <pod0> ... <pod7>
#   case_name:   3a | 9c | 9b | none (无注入对照)
#   inject_kind: cube | hbm | stress_vm | stress_io | none
#   inject_args: "duty=0.3,size=4096" (key=value pairs)
#
# 环境: KUBECONFIG 必须设置
export KUBECONFIG="${KUBECONFIG:-/tmp/config-vc-c550-h3c-test-weibozhen.yaml}"
set -uo pipefail

CASE_NAME="${1:?usage: run_case_v3.sh <case_name> <inject_kind> <inject_args> <pod0..pod7>}"
INJECT_KIND="${2:?}"
INJECT_ARGS="${3:?}"
shift 3
PODS=("$@")

BD="/workspace/baseline-exp"
JOB="muxi-test-1"
SEED=42
ITERS=100
WARMUP=10
NNODES=2   # 先跑 2 节点
NPROC=8
ROUNDS=3
VCCTL=/usr/local/bin/vcctl

# Parse inject args
DUTY=$(echo "$INJECT_ARGS" | grep -oP 'duty=\K[0-9.]+' || echo "0.3")
SIZE=$(echo "$INJECT_ARGS" | grep -oP 'size=\K[0-9]+' || echo "4096")

MASTER="${PODS[0]}.${JOB}"
BASE_PORT=30300
OUT_BASE="$BD/output/v3_${CASE_NAME}"

echo "╔═══════════════════════════════════════════╗"
echo "║ PIPELINE v3: case=$CASE_NAME             ║"
echo "║ inject=$INJECT_KIND duty=$DUTY           ║"
echo "║ pods=${PODS[0]}..${PODS[$((${#PODS[@]}-1))]}  ║"
echo "║ rounds=$ROUNDS configs=5 scale=2-node    ║"
echo "╚═══════════════════════════════════════════╝"

# ===== Helper functions =====
clean_pods() {
  for ((n=0; n<NNODES; n++)); do
    $VCCTL pod exec "${PODS[$n]}" -- bash -c 'pkill -9 -f python3.12 2>/dev/null; pkill -9 -f stress-ng 2>/dev/null; true' 2>/dev/null
  done
  sleep 3
}

fire_training() {
  local port=$1 out_dir=$2 detect_env=$3
  for ((n=0; n<NNODES; n++)); do
    cat << LAUNCHER | $VCCTL pod exec -i "${PODS[$n]}" -- bash -c 'cat > /tmp/run.sh && chmod +x /tmp/run.sh'
#!/usr/bin/env bash
export PATH="/opt/conda/bin:\${PATH}"
export PYTHONUNBUFFERED=1
export NCCL_SOCKET_IFNAME=eth0
export MCCL_SOCKET_IFNAME=eth0
export NCCL_IB_HCA=xscale_0,xscale_1,xscale_2,xscale_3
export MCCL_IB_HCA=xscale_0,xscale_1,xscale_2,xscale_3
export NCCL_IB_GID_INDEX=5
export MCCL_IB_GID_INDEX=5
export MCCL_IB_TC=128
export MCCL_ENABLE_VSWITCH=1
export NCCL_DEBUG=WARN
export MCCL_DEBUG=WARN
${detect_env}
mkdir -p ${out_dir}/ranks
torchrun --nnodes=${NNODES} --nproc_per_node=${NPROC} --node_rank=${n} \
  --master_addr=${MASTER} --master_port=${port} \
  ${BD}/train_bench_clean.py --iters=${ITERS} --warmup=${WARMUP} --seed=${SEED} \
  --out-dir=${out_dir}/ranks > ${out_dir}/node_${n}.log 2>&1
touch ${out_dir}/node_${n}.done
LAUNCHER
  done
  # Fire
  for ((n=0; n<NNODES; n++)); do
    $VCCTL pod exec "${PODS[$n]}" -- bash -c 'setsid bash /tmp/run.sh </dev/null >/dev/null 2>&1 & sleep 0.5; echo ok' 2>/dev/null
  done
}

wait_for_warmup() {
  local out_dir=$1
  local elapsed=0
  while [ $elapsed -lt 120 ]; do
    if $VCCTL pod exec "${PODS[0]}" -- bash -c "test -f ${out_dir}/ranks/warmup_done" 2>/dev/null; then
      echo "  warmup_done detected (${elapsed}s)"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "  warmup timeout (120s) — proceeding anyway"
  return 0
}

start_sidecar() {
  local victim="${PODS[0]}"
  if [ "$INJECT_KIND" = "cube" ] || [ "$INJECT_KIND" = "hbm" ]; then
    $VCCTL pod exec "$victim" -- bash -c "
      CUDA_VISIBLE_DEVICES=7 nohup /opt/conda/bin/python3.12 ${BD}/sidecar_inject.py \
        --kind ${INJECT_KIND} --duty ${DUTY} --seconds 300 --size ${SIZE} \
        > /tmp/sidecar.log 2>&1 &
      echo SIDECAR_PID=\$!
    " 2>/dev/null
  elif [ "$INJECT_KIND" = "stress_vm" ]; then
    $VCCTL pod exec "$victim" -- bash -c "
      nohup stress-ng --vm 4 --vm-bytes 2G --timeout 300s > /tmp/sidecar.log 2>&1 &
      echo SIDECAR_PID=\$!
    " 2>/dev/null
  elif [ "$INJECT_KIND" = "stress_io" ]; then
    $VCCTL pod exec "$victim" -- bash -c "
      nohup stress-ng --io 8 --timeout 300s > /tmp/sidecar.log 2>&1 &
      echo SIDECAR_PID=\$!
    " 2>/dev/null
  fi
}

stop_sidecar() {
  $VCCTL pod exec "${PODS[0]}" -- bash -c 'pkill -f sidecar_inject; pkill -f stress-ng; true' 2>/dev/null
}

wait_for_done() {
  local out_dir=$1
  local elapsed=0
  while [ $elapsed -lt 300 ]; do
    local done_count=0
    for ((n=0; n<NNODES; n++)); do
      if $VCCTL pod exec "${PODS[$n]}" -- bash -c "test -f ${out_dir}/node_${n}.done" 2>/dev/null; then
        done_count=$((done_count + 1))
      fi
    done
    if [ $done_count -eq $NNODES ]; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "  TIMEOUT (300s)"
  return 1
}

get_avg() {
  local out_dir=$1
  $VCCTL pod exec "${PODS[0]}" -- bash -c "
    /opt/conda/bin/python3.12 -c \"
import json, glob
files = sorted(glob.glob('${out_dir}/ranks/rank_*.jsonl'))
if files:
    all_ms = []
    for f in files:
        steps = [json.loads(l) for l in open(f)]
        all_ms.extend(s['step_ms'] for s in steps)
    print(f'{sum(all_ms)/len(all_ms):.1f}')
else:
    print('NO_DATA')
\"" 2>/dev/null
}

# ===== Configurations =====
declare -a CONFIGS=("C0_baseline" "C1_inject_none" "C2_inject_probing" "C3_inject_greyhound" "C4_inject_xputimer")
declare -A DETECT_ENVS=(
  ["C0_baseline"]=""
  ["C1_inject_none"]=""
  ["C2_inject_probing"]="export PROBING=2;"
  ["C3_inject_greyhound"]="export LD_PRELOAD=${BD}/greyhound/libmcclprobe.so;"
  ["C4_inject_xputimer"]="export LD_PRELOAD=${BD}/xputimer/libxpu_timer_metax.so;"
)
declare -A HAS_INJECT=(
  ["C0_baseline"]="no"
  ["C1_inject_none"]="yes"
  ["C2_inject_probing"]="yes"
  ["C3_inject_greyhound"]="yes"
  ["C4_inject_xputimer"]="yes"
)

# ===== Main Loop =====
port=$BASE_PORT
for round in $(seq 1 $ROUNDS); do
  echo ""
  echo "══════ Round $round / $ROUNDS ══════"
  for config in "${CONFIGS[@]}"; do
    port=$((port + 1))
    out="${OUT_BASE}/round_${round}/${config}"
    echo ""
    echo "  ── [$config] round=$round port=$port ──"

    # 1. Clean
    clean_pods

    # 2. Fire training
    fire_training "$port" "$out" "${DETECT_ENVS[$config]}"
    echo "  fired"

    # 3. Wait for warmup
    wait_for_warmup "$out"

    # 4. Start sidecar (if inject phase)
    if [ "${HAS_INJECT[$config]}" = "yes" ] && [ "$INJECT_KIND" != "none" ]; then
      sleep 5  # extra buffer after warmup
      start_sidecar
      echo "  sidecar started"
    fi

    # 5. Wait for training done
    if wait_for_done "$out"; then
      avg=$(get_avg "$out")
      echo "  COMPLETE avg_step_ms=$avg"
    else
      echo "  FAILED/TIMEOUT"
    fi

    # 6. Stop sidecar
    stop_sidecar
  done
done

echo ""
echo "╔═══════════════════════════════════╗"
echo "║ PIPELINE v3 COMPLETE: $CASE_NAME ║"
echo "╚═══════════════════════════════════╝"
