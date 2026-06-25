#!/usr/bin/env bash
# 启动多卡 DDP demo，采集 Step × Rank straggler 热力图素材（默认 4 GPU）
set -eo pipefail

ROOT="/home/yjr/probing-test"
VENV="$ROOT/probing/.venv"
TS=$(date +%Y%m%d_%H%M%S)
OUT="${OUT:-$ROOT/docs/assets/latest}"
LOG="$ROOT/logs/heatmap_demo_$TS"
DDP_PORT="${DDP_PORT:-8767}"
DDP_GPUS="${DDP_GPUS:-1,2,3,0}"
NPROC="${NPROC:-4}"
DEMO_DURATION_SEC="${DEMO_DURATION_SEC:-150}"
CHROME="${CHROME:-chromium-browser}"

mkdir -p "$OUT" "$LOG"
if [[ ! -f "$OUT/meta.txt" ]]; then
  echo "CAPTURE_ID=$TS" >"$OUT/meta.txt"
fi
source "$VENV/bin/activate"
unset CONDA_PREFIX CONDA_DEFAULT_ENV PROBING_CLI_MODE
export NCCL_IB_DISABLE=1
export GLOO_SOCKET_IFNAME=lo
export MASTER_ADDR=127.0.0.1

if [[ ! -f "$ROOT/probing/web/dist/index.html" ]]; then
  bash "$ROOT/scripts/build_frontend_docker.sh" | tee "$LOG/build_frontend.log"
fi
export PROBING_ASSETS_ROOT="$ROOT/probing/web/dist"

echo "CAPTURE_HEATMAP_ID=$TS" >>"$OUT/meta.txt"
echo "ddp_port=$DDP_PORT gpus=$DDP_GPUS nproc=$NPROC duration=${DEMO_DURATION_SEC}s" >>"$OUT/meta.txt"

CUDA_VISIBLE_DEVICES="$DDP_GPUS" \
  PROBING=1 PROBING_PORT="$DDP_PORT" PROBING_SPAN_BACKENDS=memtable \
  PROBING_ASSETS_ROOT="$PROBING_ASSETS_ROOT" \
  DEMO_DURATION_SEC="$DEMO_DURATION_SEC" STRAGGLER_RANK=2 \
  torchrun --nproc_per_node="$NPROC" --master_port=29517 \
  "$ROOT/scripts/demo_ddp_train_viz.py" \
  >"$LOG/ddp_train.log" 2>&1 &
DDP_LAUNCHER=$!

cleanup() {
  kill "$DDP_LAUNCHER" 2>/dev/null || true
  wait "$DDP_LAUNCHER" 2>/dev/null || true
}
trap cleanup EXIT

find_ddp_worker_pid() {
  local want_rank=$1
  local p
  for p in $(pgrep -f "[p]ython3 -u $ROOT/scripts/demo_ddp_train_viz.py" 2>/dev/null); do
    if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "LOCAL_RANK=$want_rank"; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

echo "等待 ${NPROC} 卡 DDP 训练产生 train.step span (GPUs=$DDP_GPUS)..."
CLI="$ROOT/probing/target/release/probing-cli"
PIDS=()
for _ in $(seq 1 120); do
  PIDS=()
  ready=0
  for r in $(seq 0 $((NPROC - 1))); do
    pid=$(find_ddp_worker_pid "$r" || true)
    if [[ -z "$pid" ]]; then
      ready=0
      break
    fi
    if PROBING_CLI_MODE=1 "$CLI" -t "$pid" query --format json \
      "SELECT 1 FROM python.trace_event WHERE name='train.step' LIMIT 1" 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d else 1)" 2>/dev/null; then
      PIDS+=("$pid")
      ready=$((ready + 1))
    else
      ready=0
      break
    fi
  done
  if [[ "$ready" -eq "$NPROC" ]]; then
    break
  fi
  sleep 2
done

if [[ "${#PIDS[@]}" -ne "$NPROC" ]]; then
  echo "未找齐 ${NPROC} 个 DDP worker，查看 $LOG/ddp_train.log"
  tail -50 "$LOG/ddp_train.log"
  exit 1
fi

PID_CSV=$(IFS=,; echo "${PIDS[*]}")
echo "ddp_pids=$PID_CSV world_size=$NPROC" >>"$OUT/meta.txt"

HTML="$OUT/web_training_heatmap_render.html"
RENDER_JSON=$(python3 "$ROOT/scripts/render_step_heatmap.py" --cli "$CLI" --pids "$PID_CSV" "$HTML")
sleep 2
"$CHROME" --headless --disable-gpu --no-sandbox \
  --window-size=1440,900 \
  --virtual-time-budget=10000 \
  --run-all-compositor-stages-before-draw \
  --hide-scrollbars \
  --screenshot="$OUT/web_training_heatmap.png" \
  "file://$HTML" 2>"$LOG/chrome_heatmap.log" || true

echo "$RENDER_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(f\"step_matrix ranks={d.get('rank_count')} steps={d.get('step_count')} samples={d.get('samples')}\")
" | tee -a "$OUT/meta.txt"

echo "热力图素材: $OUT/web_training_heatmap.png (${NPROC} GPU, 日志 $LOG)"
