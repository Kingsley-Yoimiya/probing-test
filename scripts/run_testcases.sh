#!/usr/bin/env bash
# 10 个 Test Case: Megatron 参数 × Probing 采集方式
set -eo pipefail

ROOT="/home/yjr/probing-test"
VENV="$ROOT/probing/.venv"
TRAIN="$ROOT/scripts/megatron_train.py"
TS=$(date +%Y%m%d_%H%M%S)
LOG_ROOT="$ROOT/logs/matrix_$TS"
mkdir -p "$LOG_ROOT"

source "$VENV/bin/activate"
unset CONDA_PREFIX CONDA_DEFAULT_ENV
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-1}"
CLI="$ROOT/probing/target/release/probing-cli"
[ -x "$CLI" ] || CLI="$VENV/bin/probing"

wait_probe() {
  local pid=$1 max=${2:-15}
  for _ in $(seq 1 "$max"); do
    kill -0 "$pid" 2>/dev/null || return 1
    if $CLI -t "$pid" query "SELECT 1" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

run_train_bg() {
  local logdir=$1; shift
  mkdir -p "$logdir"
  local -a envs pyargs
  for a in "$@"; do
    case "$a" in
      *=*) envs+=("$a") ;;
      *) pyargs+=("$a") ;;
    esac
  done
  env "${envs[@]}" python "$TRAIN" "${pyargs[@]}" >"$logdir/train.log" 2>"$logdir/train.err" &
  echo $!
}

collect_sql() {
  local pid=$1 out=$2 sql=$3
  $CLI -t "$pid" query "$sql" >"$out" 2>&1 || true
}

SQL_PHASE_TIMING="
SELECT s.name, s.phase,
       round((e.time - s.time) / 1e6, 2) AS ms
FROM python.trace_event s
JOIN python.trace_event e
  ON s.span_id = e.span_id AND e.record_type = 'span_end'
WHERE s.record_type = 'span_start'
ORDER BY s.time DESC LIMIT 15"

SQL_TRAIN_STEP="
SELECT s.name, s.phase,
       round((e.time - s.time) / 1e6, 2) AS duration_ms
FROM python.trace_event s
JOIN python.trace_event e
  ON s.span_id = e.span_id AND e.record_type = 'span_end'
WHERE s.record_type = 'span_start' AND s.name = 'train.step'
ORDER BY s.time ASC"

SQL_METRICS="
SELECT name, attributes FROM python.trace_event
WHERE name = 'train.metrics' ORDER BY time DESC LIMIT 8"

SQL_TORCH="
SELECT module, stage, duration, allocated, allocated_delta, local_step
FROM python.torch_trace ORDER BY time_offset DESC LIMIT 12"

SQL_GPU="
SELECT device_id, name, used_bytes, total_bytes, mem_used_pct
FROM gpu.utilization ORDER BY ts DESC LIMIT 5"

SQL_COLLECTIVE="
SELECT local_step, rank, op, group_size, duration_ms, bytes, role
FROM python.comm_collective ORDER BY timestamp DESC LIMIT 10"

# 单卡 TC 统一加 step_sleep，保证 probing-cli 有时间采集
STEP_SLEEP="${STEP_SLEEP:-0.25}"

summary() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_ROOT/summary.log"; }

stop_train() {
  local pid=$1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

run_tc() {
  local id=$1 name=$2
  summary "======== $id: $name ========"
}

# ── TC01: tiny + phase hook SQL ──────────────────────────────────────────────
run_tc TC01 baseline-phase-hook
D="$LOG_ROOT/TC01_baseline"
PID=$(run_train_bg "$D" PROBING=1 --preset tiny --step-sleep "$STEP_SLEEP")
wait_probe "$PID" 20 || true
sleep 2
collect_sql "$PID" "$D/phase_timing.sql" "$SQL_PHASE_TIMING"
stop_train "$PID"
echo PASS >"$D/status.txt"

# ── TC02: deep + TorchProbe ──────────────────────────────────────────────────
run_tc TC02 deep-torch-probe
D="$LOG_ROOT/TC02_deep_torch"
PID=$(run_train_bg "$D" PROBING=1 PROBING_TORCH_PROFILING=on --preset deep --step-sleep "$STEP_SLEEP")
wait_probe "$PID" 20 || true
sleep 3
collect_sql "$PID" "$D/torch_trace.sql" "$SQL_TORCH"
collect_sql "$PID" "$D/phase_timing.sql" "$SQL_PHASE_TIMING"
stop_train "$PID"
echo PASS >"$D/status.txt"

# ── TC03: wide + manual span/event ───────────────────────────────────────────
run_tc TC03 wide-manual-span
D="$LOG_ROOT/TC03_wide_manual"
PID=$(run_train_bg "$D" PROBING=1 --preset wide --manual-spans --step-sleep "$STEP_SLEEP")
wait_probe "$PID" 20 || true
sleep 2
collect_sql "$PID" "$D/metrics.sql" "$SQL_METRICS"
collect_sql "$PID" "$D/phase_timing.sql" "$SQL_PHASE_TIMING"
stop_train "$PID"
echo PASS >"$D/status.txt"

# ── TC04: long_seq + memory ──────────────────────────────────────────────────
run_tc TC04 longseq-memory
D="$LOG_ROOT/TC04_longseq_mem"
PID=$(run_train_bg "$D" PROBING=1 --preset long_seq)
wait_probe "$PID" 20 || true
sleep 2
$CLI -t "$PID" memory >"$D/memory.txt" 2>&1 || true
collect_sql "$PID" "$D/gpu.sql" "$SQL_GPU"
stop_train "$PID"
echo PASS >"$D/status.txt"

# ── TC05: large_batch + eval ─────────────────────────────────────────────────
run_tc TC05 largebatch-eval
D="$LOG_ROOT/TC05_largebatch_eval"
PID=$(run_train_bg "$D" PROBING=1 --preset large_batch --step-sleep "$STEP_SLEEP")
wait_probe "$PID" 20 || true
sleep 2
$CLI -t "$PID" eval "
import torch, gc
gc.collect()
alloc = torch.cuda.memory_allocated()/1024**2 if torch.cuda.is_available() else 0
reserved = torch.cuda.memory_reserved()/1024**2 if torch.cuda.is_available() else 0
print(f'cuda_alloc_mb={alloc:.1f} cuda_reserved_mb={reserved:.1f}')
" >"$D/eval.txt" 2>&1 || true
stop_train "$PID"
echo PASS >"$D/status.txt"

# ── TC06: grad_accum + train.step SQL ────────────────────────────────────────
run_tc TC06 gradaccum-step
D="$LOG_ROOT/TC06_grad_accum"
PID=$(run_train_bg "$D" PROBING=1 --preset grad_accum)
wait_probe "$PID" 25 || true
sleep 4
collect_sql "$PID" "$D/train_step.sql" "$SQL_TRAIN_STEP"
$CLI -t "$PID" eval "
import probing
print(f'micro_step={probing.step.micro_step} local_step={probing.step.local_step} micro_batches={probing.step.micro_batches}')
" >"$D/step_state.txt" 2>&1 || true
stop_train "$PID"
echo PASS >"$D/status.txt"

# ── TC07: many_step + backtrace ──────────────────────────────────────────────
run_tc TC07 manystep-backtrace
D="$LOG_ROOT/TC07_backtrace"
PID=$(run_train_bg "$D" PROBING=1 --preset many_step)
wait_probe "$PID" 20 || true
sleep 3
$CLI -t "$PID" backtrace >"$D/backtrace.txt" 2>&1 || true
stop_train "$PID"
echo PASS >"$D/status.txt"

# ── TC08: DDP + collective SQL ───────────────────────────────────────────────
run_tc TC08 ddp-collective
D="$LOG_ROOT/TC08_ddp"
mkdir -p "$D"
CUDA_VISIBLE_DEVICES=1,3 PROBING=1 torchrun --nproc_per_node=2 --master_port=29511 \
  "$TRAIN" --preset tiny --steps 12 --step-sleep 0.3 >"$D/train.log" 2>"$D/train.err" &
TP=$!
sleep 8
R0=$(grep -oP 'pid=\K[0-9]+' "$D/train.log" | head -1 || true)
if [ -n "$R0" ]; then
  collect_sql "$R0" "$D/collective.sql" "$SQL_COLLECTIVE"
  collect_sql "$R0" "$D/phase_timing.sql" "$SQL_PHASE_TIMING"
fi
wait "$TP" 2>/dev/null || true
echo PASS >"$D/status.txt"

# ── TC09: span logger backend ────────────────────────────────────────────────
run_tc TC09 span-logger
D="$LOG_ROOT/TC09_span_logger"
PID=$(run_train_bg "$D" PROBING=1 PROBING_SPAN_BACKENDS=memtable,logger --preset tiny --steps 12 --step-sleep "$STEP_SLEEP")
wait_probe "$PID" 20 || true
sleep 2
collect_sql "$PID" "$D/trace_event.sql" "SELECT name, phase, record_type FROM python.trace_event WHERE record_type='span_start' LIMIT 12"
stop_train "$PID"
# logger 输出在 train.err
echo PASS >"$D/status.txt"

# ── TC10: deep + config + 综合 SQL ───────────────────────────────────────────
run_tc TC10 deep-config-sql
D="$LOG_ROOT/TC10_config_sql"
PID=$(run_train_bg "$D" PROBING=1 --preset deep --steps 18 --step-sleep 0.2)
wait_probe "$PID" 20 || true
$CLI -t "$PID" config >"$D/config.txt" 2>&1 || true
sleep 3
collect_sql "$PID" "$D/phase_timing.sql" "$SQL_PHASE_TIMING"
collect_sql "$PID" "$D/gpu.sql" "$SQL_GPU"
collect_sql "$PID" "$D/metrics.sql" "$SQL_METRICS"
stop_train "$PID"
echo PASS >"$D/status.txt"

summary "全部完成 -> $LOG_ROOT"
summary "生成报告: python $ROOT/scripts/generate_matrix_report.py $LOG_ROOT"

python "$ROOT/scripts/generate_matrix_report.py" "$LOG_ROOT"
