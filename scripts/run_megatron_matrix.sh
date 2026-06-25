#!/usr/bin/env bash
# 真实 Megatron-LM pretrain_gpt.py × 10 种 Probing 采集方式
set -eo pipefail

ROOT="/home/yjr/probing-test"
source "$ROOT/scripts/megatron_presets.sh"

TS=$(date +%Y%m%d_%H%M%S)
LOG_ROOT="$ROOT/logs/megatron_matrix_$TS"
mkdir -p "$LOG_ROOT"

source "$VENV/bin/activate"
unset CONDA_PREFIX CONDA_DEFAULT_ENV
export PYTHONPATH="$MEGATRON_ROOT"
export CUDA_DEVICE_MAX_CONNECTIONS=1
export NCCL_IB_DISABLE=1
export NCCL_SOCKET_IFNAME=lo
export GLOO_SOCKET_IFNAME=lo
export MASTER_ADDR=127.0.0.1

SQL_PHASE="
SELECT name, phase, record_type FROM python.trace_event
WHERE record_type='span_start' ORDER BY time DESC LIMIT 15"

SQL_TORCH="
SELECT module, stage, duration, allocated, local_step
FROM python.torch_trace ORDER BY time_offset DESC LIMIT 12"

SQL_GPU="
SELECT device_id, name, round(used_bytes/1048576.0,1) AS used_mb,
       round(mem_used_pct*100,1) AS pct
FROM gpu.utilization ORDER BY ts DESC LIMIT 5"

SQL_COLLECTIVE="SELECT * FROM python.comm_collective LIMIT 10"

summary() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_ROOT/summary.log" >&2; }

wait_probe() {
  local pid=$1 max=${2:-60}
  for _ in $(seq 1 "$max"); do
    kill -0 "$pid" 2>/dev/null || return 1
    $CLI -t "$pid" query "SELECT 1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

find_rank0_pid() {
  local p
  for p in $(pgrep -f "[p]ython.*pretrain_gpt.py" 2>/dev/null); do
    if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "LOCAL_RANK=0"; then
      echo "$p"
      return 0
    fi
  done
  pgrep -f "[p]ython.*pretrain_gpt.py" 2>/dev/null | head -1
}

run_megatron_bg() {
  local logdir=$1 preset=$2 port=$3
  shift 3
  local -a extra_env=()
  local -a extra_args=()
  for a in "$@"; do
    case "$a" in
      *=*) extra_env+=("$a") ;;
      *) extra_args+=("$a") ;;
    esac
  done

  local nproc gpus
  nproc=$(nproc_for_preset "$preset")
  gpus=$(gpu_for_preset "$preset")
  export CUDA_VISIBLE_DEVICES=$gpus

  mkdir -p "$logdir"
  # shellcheck disable=SC2207
  local common=( "${MEGATRON_COMMON[@]}" )
  # shellcheck disable=SC2046
  local preset_a=( $(preset_args "$preset") )

  summary "启动 Megatron preset=$preset nproc=$nproc GPU=$gpus port=$port"
  env PROBING=1 "${extra_env[@]}" \
  torchrun --nproc_per_node="$nproc" --master_port="$port" --master_addr=127.0.0.1 \
    "$MEGATRON_ROOT/pretrain_gpt.py" \
    "${common[@]}" "${preset_a[@]}" "${extra_args[@]}" \
    >"$logdir/train.log" 2>"$logdir/train.err" &
  echo $!
}

collect_from_train() {
  local logdir=$1 method=$2
  local pid
  pid=$(find_rank0_pid || true)
  if [ -z "$pid" ]; then
    summary "WARN: 未找到运行中 pretrain_gpt pid"
    return 1
  fi
  summary "  probing pid=$pid method=$method"
  case "$method" in
    sql_phase) $CLI -t "$pid" query "$SQL_PHASE" >"$logdir/phase.sql" 2>&1 ;;
    sql_torch) $CLI -t "$pid" query "$SQL_TORCH" >"$logdir/torch.sql" 2>&1 ;;
    memory)    $CLI -t "$pid" memory >"$logdir/memory.txt" 2>&1
               $CLI -t "$pid" query "$SQL_GPU" >"$logdir/gpu.sql" 2>&1 ;;
    eval)      $CLI -t "$pid" eval "
import torch
a=torch.cuda.memory_allocated()/1024**2
r=torch.cuda.memory_reserved()/1024**2
print(f'alloc_mb={a:.1f} reserved_mb={r:.1f} max_mb={torch.cuda.max_memory_allocated()/1024**2:.1f}')
" >"$logdir/eval.txt" 2>&1 ;;
    backtrace) $CLI -t "$pid" backtrace >"$logdir/backtrace.txt" 2>&1 ;;
    collective) $CLI -t "$pid" query "$SQL_COLLECTIVE" >"$logdir/collective.sql" 2>&1
                $CLI -t "$pid" query "$SQL_PHASE" >"$logdir/phase.sql" 2>&1 ;;
    config)    $CLI -t "$pid" config >"$logdir/config.txt" 2>&1
               $CLI -t "$pid" query "$SQL_PHASE" >"$logdir/phase.sql" 2>&1
               $CLI -t "$pid" query "$SQL_GPU" >"$logdir/gpu.sql" 2>&1 ;;
    span_log)  $CLI -t "$pid" query "SELECT name,phase,record_type FROM python.trace_event WHERE record_type='span_start' LIMIT 12" >"$logdir/spans.sql" 2>&1 ;;
  esac
}

wait_train_and_probe() {
  local logdir=$1 method=$2 launcher_pid=$3
  local pid="" i
  for i in $(seq 1 60); do
    sleep 2
    if ! kill -0 "$launcher_pid" 2>/dev/null; then break; fi
    pid=$(find_rank0_pid || true)
    [ -z "$pid" ] && continue
    if $CLI -t "$pid" query "SELECT 1" >/dev/null 2>&1; then
      collect_from_train "$logdir" "$method" || true
      break
    fi
  done
  while kill -0 "$launcher_pid" 2>/dev/null; do sleep 2; done
  wait "$launcher_pid" 2>/dev/null || true
  sleep 3
}

run_tc() {
  local id=$1 preset=$2 method=$3 port=$4
  shift 4
  summary "======== $id preset=$preset probe=$method ========"
  summary "  ${PRESET_DESC[$preset]}"
  local d="$LOG_ROOT/${id}_${preset}"
  local launcher_pid
  launcher_pid=$(run_megatron_bg "$d" "$preset" "$port" "$@")
  wait_train_and_probe "$d" "$method" "$launcher_pid"
  if grep -qE "lm loss|exiting program at iteration" "$d/train.log" 2>/dev/null; then
    echo PASS >"$d/status.txt"
    grep "lm loss" "$d/train.log" | tail -3 >"$d/loss_tail.txt" || true
  else
    echo FAIL >"$d/status.txt"
  fi
}

# ── 10 Test Cases: 真实 Megatron 参数 × Probing 采集 ─────────────────────
run_tc TC01 gpt345m sql_phase 29601
run_tc TC02 gpt345m sql_torch 29602 PROBING_TORCH_PROFILING=on,mode=ordered
run_tc TC03 gpt126m memory 29603
run_tc TC04 gpt345m_long eval 29604
run_tc TC05 gpt345m_gbs sql_phase 29605
run_tc TC06 gpt345m_tp2 collective 29606
run_tc TC07 gpt126m_pp2 backtrace 29607
run_tc TC08 gpt126m_2dp collective 29608
run_tc TC09 gpt345m span_log 29609 PROBING_SPAN_BACKENDS=memtable,logger
run_tc TC10 gpt345m config 29610

summary "完成 -> $LOG_ROOT"
python "$ROOT/scripts/generate_megatron_report.py" "$LOG_ROOT"
