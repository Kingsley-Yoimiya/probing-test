#!/usr/bin/env bash
# 单独重采 Megatron Web UI 截图（优先 /spans，避免训练结束后再连不上）
set -eo pipefail

ROOT="/home/yjr/probing-test"
VENV="$ROOT/probing/.venv"
CLI="$ROOT/probing/target/release/probing-cli"
OUT="${OUT:-$ROOT/docs/assets/latest}"
TS=$(date +%Y%m%d_%H%M%S)
LOG="$ROOT/logs/megatron_capture_$TS"
MEGA_PORT="${MEGA_PORT:-8788}"
GPU="${CUDA_VISIBLE_DEVICES:-1}"
TRAIN_ITERS="${TRAIN_ITERS:-60}"
CHROME="${CHROME:-chromium-browser}"

mkdir -p "$OUT" "$LOG"
source "$VENV/bin/activate"
source "$ROOT/scripts/megatron_presets.sh"
unset CONDA_PREFIX CONDA_DEFAULT_ENV PROBING_CLI_MODE
export CUDA_VISIBLE_DEVICES="$GPU"
export PYTHONPATH="$MEGATRON_ROOT"
export NCCL_IB_DISABLE=1 GLOO_SOCKET_IFNAME=lo MASTER_ADDR=127.0.0.1
export PROBING_ASSETS_ROOT="$ROOT/probing/web/dist"

shot() {
  local url=$1 out=$2 wait=${3:-15}
  sleep "$wait"
  "$CHROME" --headless --disable-gpu --no-sandbox \
    --window-size=1440,900 --virtual-time-budget=25000 \
    --run-all-compositor-stages-before-draw --hide-scrollbars \
    --screenshot="$out" "$url" 2>"$LOG/chrome_${out##*/}.log" || true
}

wait_http() {
  local port=$1 max=${2:-90}
  for _ in $(seq 1 "$max"); do
    curl -sf "http://127.0.0.1:$port/" | grep -q 'web-dxh\|<div id="main">' && return 0
    sleep 1
  done
  return 1
}

find_megatron_pid() {
  local p
  for p in $(pgrep -f "[p]ython.*pretrain_gpt.py" 2>/dev/null); do
    if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "LOCAL_RANK=0"; then
      echo "$p"
      return 0
    fi
  done
  pgrep -f "[p]ython.*pretrain_gpt.py" 2>/dev/null | head -1
}

# shellcheck disable=SC2046
nproc_args=( $(preset_args gpt345m) )

echo "启动 Megatron gpt345m (GPU=$GPU port=$MEGA_PORT iters=$TRAIN_ITERS)..."
PROBING=1 PROBING_PORT="$MEGA_PORT" PROBING_ASSETS_ROOT="$PROBING_ASSETS_ROOT" \
  torchrun --nproc_per_node=1 --master_port=29522 \
  "$MEGATRON_ROOT/pretrain_gpt.py" \
  "${MEGATRON_COMMON[@]}" "${nproc_args[@]}" \
  --train-iters "$TRAIN_ITERS" --exit-interval "$TRAIN_ITERS" \
  >"$LOG/train.log" 2>&1 &
MEGA_LAUNCHER=$!

cleanup() {
  kill "$MEGA_LAUNCHER" 2>/dev/null || true
  wait "$MEGA_LAUNCHER" 2>/dev/null || true
}
trap cleanup EXIT

MEGA_PROBE_PID=""
for _ in $(seq 1 180); do
  MEGA_PROBE_PID=$(find_megatron_pid || true)
  if [[ -n "$MEGA_PROBE_PID" ]] && PROBING_CLI_MODE=1 "$CLI" -t "$MEGA_PROBE_PID" query "SELECT 1" >/dev/null 2>&1; then
    if wait_http "$MEGA_PORT" 30; then
      echo "megatron_probe_pid=$MEGA_PROBE_PID port=$MEGA_PORT" | tee "$LOG/ready.txt"
      break
    fi
  fi
  sleep 2
done

if [[ -z "$MEGA_PROBE_PID" ]]; then
  echo "Megatron probing 未就绪，见 $LOG/train.log"
  tail -40 "$LOG/train.log"
  exit 1
fi

BASE="http://127.0.0.1:$MEGA_PORT"
echo "采集 Megatron Web 截图（/spans 优先）..."
shot "$BASE/spans" "$OUT/web_megatron_spans.png" 18
shot "$BASE/" "$OUT/web_megatron_dashboard.png" 12
shot "$BASE/training" "$OUT/web_megatron_training.png" 15

echo "MEGATRON_CAPTURE_ID=$TS" >>"$OUT/meta.txt"
echo "完成: $OUT/web_megatron_spans.png (日志 $LOG)"
