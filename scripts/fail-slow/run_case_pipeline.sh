#!/usr/bin/env bash
# run_case_pipeline.sh — Run complete 10-phase pipeline for one case
# Usage: run_case_pipeline.sh <case> <duty> <pod0> <pod1> ... <pod7>
# Requires: KUBECONFIG set, vcctl available
set -euo pipefail

CASE="$1"; DUTY="$2"; shift 2
PODS=("$@")
BD="/workspace/baseline-exp"
JOB="muxi-test-1"
SEED=42
ITERS=30
WARMUP=10

echo "=== PIPELINE: case=$CASE duty=$DUTY pods=${PODS[*]} ==="

# Function: run one phase
run_phase() {
  local phase_name="$1" nnodes="$2" inject_case="$3" detect_env="$4" port="$5"
  local out="$BD/output/pipeline_${CASE}/${phase_name}"
  local master="${PODS[0]}.${JOB}"
  
  echo "[${phase_name}] Starting: nnodes=$nnodes inject=$inject_case"
  
  # Clean
  for ((n=0; n<nnodes; n++)); do
    vcctl pod exec "${PODS[$n]}" -- bash -c "pkill -9 -f python3.12 2>/dev/null; rm -rf ${out}; true" 2>/dev/null
  done
  sleep 2
  
  # Upload launchers
  for ((n=0; n<nnodes; n++)); do
    local inject_env=""
    if [ "$inject_case" != "none" ]; then
      inject_env="export INJECT_CASE=${inject_case}; export INJECT_RANK=7; export INJECT_DUTY=${DUTY}; export INJECT_DELAY_STEPS=0;"
    fi
    cat << LAUNCHER_EOF | vcctl pod exec -i "${PODS[$n]}" -- bash -c 'cat > /tmp/run.sh && chmod +x /tmp/run.sh'
#!/usr/bin/env bash
set -euo pipefail
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
${inject_env}
${detect_env}
mkdir -p ${out}/ranks
torchrun --nnodes=${nnodes} --nproc_per_node=8 --node_rank=${n} \
  --master_addr=${master} --master_port=${port} \
  ${BD}/train_bench_v2.py --iters=${ITERS} --warmup=${WARMUP} --seed=${SEED} --out-dir=${out}/ranks \
  > ${out}/node_${n}.log 2>&1
touch ${out}/node_${n}.done
LAUNCHER_EOF
  done
  
  # Fire
  for ((n=0; n<nnodes; n++)); do
    vcctl pod exec "${PODS[$n]}" -- bash -c 'setsid bash /tmp/run.sh </dev/null >/dev/null 2>&1 & sleep 0.5; echo ok' 2>/dev/null
  done
  
  # Poll until done (max 5 min)
  local elapsed=0
  while [ $elapsed -lt 300 ]; do
    sleep 10
    elapsed=$((elapsed + 10))
    local done_count=0
    for ((n=0; n<nnodes; n++)); do
      if vcctl pod exec "${PODS[$n]}" -- bash -c "test -f ${out}/node_${n}.done" 2>/dev/null; then
        done_count=$((done_count + 1))
      fi
    done
    if [ $done_count -eq $nnodes ]; then
      echo "[${phase_name}] COMPLETE (${elapsed}s)"
      # Get summary from master
      vcctl pod exec "${PODS[0]}" -- bash -c "strings ${out}/node_0.log 2>/dev/null | grep DONE" 2>/dev/null
      return 0
    fi
  done
  echo "[${phase_name}] TIMEOUT after 300s"
  return 1
}

# === STAGE 1: 2-node (16 rank) ===
echo ""
echo "========== STAGE 1: 2-node × 8-gpu = 16 rank =========="
run_phase "s1_baseline"       2 "none"  ""                                          30101
run_phase "s1_inject_none"    2 "$CASE" ""                                          30102
run_phase "s1_inject_probing" 2 "$CASE" "export PROBING=2;"                         30103
run_phase "s1_inject_greyhound" 2 "$CASE" "export LD_PRELOAD=$BD/greyhound/libmcclprobe.so;" 30104
run_phase "s1_inject_xputimer"  2 "$CASE" "export LD_PRELOAD=$BD/xputimer/libxpu_timer_metax.so;" 30105

# === STAGE 2: 8-node (64 rank) ===
echo ""
echo "========== STAGE 2: 8-node × 8-gpu = 64 rank =========="
run_phase "s2_baseline"       8 "none"  ""                                          30201
run_phase "s2_inject_none"    8 "$CASE" ""                                          30202
run_phase "s2_inject_probing" 8 "$CASE" "export PROBING=2;"                         30203
run_phase "s2_inject_greyhound" 8 "$CASE" "export LD_PRELOAD=$BD/greyhound/libmcclprobe.so;" 30204
run_phase "s2_inject_xputimer"  8 "$CASE" "export LD_PRELOAD=$BD/xputimer/libxpu_timer_metax.so;" 30205

echo ""
echo "========== PIPELINE COMPLETE: $CASE =========="
