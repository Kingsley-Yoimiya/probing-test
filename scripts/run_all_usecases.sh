#!/usr/bin/env bash
# 运行 10 个 probing use case，日志写入 LOG_DIR
set -uo pipefail

ROOT="/home/yjr/probing-test"
PROBING_DIR="$ROOT/probing"
VENV="$PROBING_DIR/.venv"
SCRIPTS="$ROOT/scripts"
TS=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$ROOT/logs/run_$TS"
mkdir -p "$LOG_DIR"

source "$VENV/bin/activate"
unset CONDA_PREFIX CONDA_DEFAULT_ENV
export PYTHONPATH="$PROBING_DIR${PYTHONPATH:+:$PYTHONPATH}"
# 优先使用空闲 GPU 1；DDP 用 1,3
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-1}"

cd "$PROBING_DIR"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_DIR/summary.log"; }
run_uc() {
  local id="$1" name="$2"
  shift 2
  log "=== UC$id: $name ==="
  local out="$LOG_DIR/uc${id}_${name}.log"
  local err="$LOG_DIR/uc${id}_${name}.err"
  local start=$(date +%s)
  if "$@" >"$out" 2>"$err"; then
    local end=$(date +%s)
    log "UC$id PASS ($((end-start))s) -> $out"
    echo "PASS" > "$LOG_DIR/uc${id}_status.txt"
  else
    local end=$(date +%s)
    log "UC$id FAIL ($((end-start))s) -> see $out $err"
    echo "FAIL" > "$LOG_DIR/uc${id}_status.txt"
  fi
}

log "Log directory: $LOG_DIR"
log "probing version: $(probing --version 2>/dev/null || echo unknown)"
log "torch cuda devices (visible): $(python -c 'import torch; print(torch.cuda.device_count())')"

# UC1: 进程树 hook
run_uc 1 process_tree env PROBING=1 python examples/test_probing.py --depth 2

# UC2: tracing + attach_training_phases
run_uc 2 tracing env PROBING=1 python examples/tracing.py

# UC3: ExternalTable 自定义指标
run_uc 3 external_table env PROBING=1 python examples/external_table.py

# UC4-6: 动态注入 / backtrace / eval（同一后台进程）
log "=== UC4-6: dynamic inject / backtrace / eval ==="
python "$SCRIPTS/long_running_train.py" >"$LOG_DIR/uc4_bg.log" 2>&1 &
BG_PID=$!
sleep 3
if kill -0 "$BG_PID" 2>/dev/null; then
  log "Background train PID=$BG_PID"
  probing -t "$BG_PID" inject >"$LOG_DIR/uc4_inject.log" 2>&1 && echo PASS > "$LOG_DIR/uc4_status.txt" || echo FAIL > "$LOG_DIR/uc4_status.txt"
  sleep 2
  probing -t "$BG_PID" backtrace >"$LOG_DIR/uc5_backtrace.log" 2>&1 && echo PASS > "$LOG_DIR/uc5_status.txt" || echo FAIL > "$LOG_DIR/uc5_status.txt"
  probing -t "$BG_PID" eval "import torch; print('cuda', torch.cuda.is_available(), 'loss_ok', True)" >"$LOG_DIR/uc6_eval.log" 2>&1 && echo PASS > "$LOG_DIR/uc6_status.txt" || echo FAIL > "$LOG_DIR/uc6_status.txt"
  kill "$BG_PID" 2>/dev/null || true
  wait "$BG_PID" 2>/dev/null || true
else
  log "UC4-6 SKIP: background process failed to start"
  echo SKIP > "$LOG_DIR/uc4_status.txt"
  echo SKIP > "$LOG_DIR/uc5_status.txt"
  echo SKIP > "$LOG_DIR/uc6_status.txt"
fi

# UC7: SQL 查询（tracing 进程）
log "=== UC7: SQL query ==="
PROBING=1 python examples/tracing.py >"$LOG_DIR/uc7_train.log" 2>&1 &
TR_PID=$!
sleep 4
if kill -0 "$TR_PID" 2>/dev/null; then
  probing -t "$TR_PID" query "SELECT name, phase, record_type FROM python.trace_event LIMIT 10" >"$LOG_DIR/uc7_sql.log" 2>&1 && echo PASS > "$LOG_DIR/uc7_status.txt" || echo FAIL > "$LOG_DIR/uc7_status.txt"
  probing -t "$TR_PID" query "SHOW TABLES" >"$LOG_DIR/uc7_tables.log" 2>&1 || true
  kill "$TR_PID" 2>/dev/null; wait "$TR_PID" 2>/dev/null || true
else
  echo FAIL > "$LOG_DIR/uc7_status.txt"
fi

# UC8: memory 分析
log "=== UC8: memory ==="
PROBING=1 python "$SCRIPTS/mini_megatron_lm.py" >"$LOG_DIR/uc8_train.log" 2>&1 &
MEM_PID=$!
sleep 5
if kill -0 "$MEM_PID" 2>/dev/null; then
  probing -t "$MEM_PID" memory >"$LOG_DIR/uc8_memory.log" 2>&1 && echo PASS > "$LOG_DIR/uc8_status.txt" || echo FAIL > "$LOG_DIR/uc8_status.txt"
  probing -t "$MEM_PID" query "SELECT local_step, allocated FROM python.torch_trace ORDER BY ts DESC LIMIT 5" >"$LOG_DIR/uc8_sql.log" 2>&1 || true
  kill "$MEM_PID" 2>/dev/null; wait "$MEM_PID" 2>/dev/null || true
else
  echo FAIL > "$LOG_DIR/uc8_status.txt"
fi

# UC9: DDP torchrun 2 GPU
log "=== UC9: DDP torchrun ==="
CUDA_VISIBLE_DEVICES=1,3 PROBING=1 torchrun --nproc_per_node=2 --master_port=29501 "$SCRIPTS/mini_ddp_train.py" >"$LOG_DIR/uc9_ddp.log" 2>&1
if [ $? -eq 0 ]; then echo PASS > "$LOG_DIR/uc9_status.txt"; else echo FAIL > "$LOG_DIR/uc9_status.txt"; fi

# UC10: Mini Megatron-style GPT
run_uc 10 megatron_lm env PROBING=1 python "$SCRIPTS/mini_megatron_lm.py"

# UC10 附加 SQL
if [ -f "$LOG_DIR/uc10_megatron_lm.log" ]; then
  TRAIN_PID=$(grep -oP 'pid=\K[0-9]+' "$LOG_DIR/uc10_megatron_lm.log" | head -1 || true)
fi
# 重新跑一遍短流程取 SQL（训练已结束则查 list）
PROBING=1 python "$SCRIPTS/mini_megatron_lm.py" >"$LOG_DIR/uc10_sql_train.log" 2>&1 &
M_PID=$!
sleep 6
probing -t "$M_PID" query "SELECT name, phase FROM python.trace_event WHERE record_type='span_start' LIMIT 15" >"$LOG_DIR/uc10_sql.log" 2>&1 || true
probing -t "$M_PID" query "SELECT step, loss FROM python.trace_event WHERE name='train.metrics' LIMIT 5" >"$LOG_DIR/uc10_metrics.log" 2>&1 || true
kill "$M_PID" 2>/dev/null; wait "$M_PID" 2>/dev/null || true

# UC bonus: bench_profiler 开销
run_uc 11 bench_overhead env PROBING=1 python examples/bench_profiler.py

# 汇总
log "=== FINAL STATUS ==="
for f in "$LOG_DIR"/uc*_status.txt; do
  [ -f "$f" ] && log "$(basename "$f"): $(cat "$f")"
done
log "Done. Reports in $LOG_DIR"
