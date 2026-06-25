#!/usr/bin/env bash
# Megatron 多卡 Web UI 截图（默认 4×126M DP）
set -eo pipefail

ROOT="/home/yjr/probing-test"
VENV="$ROOT/probing/.venv"
CLI="$ROOT/probing/target/release/probing-cli"
OUT="${OUT:-$ROOT/docs/assets/latest}"
TS=$(date +%Y%m%d_%H%M%S)
LOG="$ROOT/logs/megatron_capture_$TS"
MEGA_PORT="${MEGA_PORT:-8788}"
PRESET="${MEGA_PRESET:-gpt126m_4dp}"
TRAIN_ITERS="${TRAIN_ITERS:-80}"
CHROME="${CHROME:-chromium-browser}"

mkdir -p "$OUT" "$LOG"
source "$VENV/bin/activate"
source "$ROOT/scripts/megatron_presets.sh"
unset CONDA_PREFIX CONDA_DEFAULT_ENV PROBING_CLI_MODE

# 避免与 DDP demo 端口 / 进程冲突
pkill -f "demo_ddp_train_viz.py" 2>/dev/null || true
sleep 2

GPU="$(gpu_for_preset "$PRESET")"
NPROC="$(nproc_for_preset "$PRESET")"
export CUDA_VISIBLE_DEVICES="$GPU"
export PYTHONPATH="$MEGATRON_ROOT"
export NCCL_IB_DISABLE=1 GLOO_SOCKET_IFNAME=lo NCCL_SOCKET_IFNAME=lo MASTER_ADDR=127.0.0.1
export PROBING_ASSETS_ROOT="$ROOT/probing/web/dist"

shot() {
  local url=$1 out=$2 wait=${3:-15}
  wait_http "$MEGA_PORT" 15 || { echo "WARN: HTTP $MEGA_PORT 不可用，跳过 $out"; return 0; }
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
  for p in $(pgrep -f "[p]ython.*pretrain_gpt" 2>/dev/null); do
    if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "LOCAL_RANK=0"; then
      echo "$p"
      return 0
    fi
  done
  pgrep -f "[p]ython.*pretrain_gpt" 2>/dev/null | head -1
}

# shellcheck disable=SC2046
nproc_args=( $(preset_args "$PRESET") )

echo "启动 Megatron preset=$PRESET GPU=$GPU nproc=$NPROC port=$MEGA_PORT iters=$TRAIN_ITERS..."
echo "MEGATRON_PRESET=$PRESET MEGATRON_GPUS=$GPU MEGATRON_NPROC=$NPROC" >>"$OUT/meta.txt"

PROBING=1 PROBING_PORT="$MEGA_PORT" PROBING_SPAN_BACKENDS=memtable,logger PROBING_ASSETS_ROOT="$PROBING_ASSETS_ROOT" \
  torchrun --nproc_per_node="$NPROC" --master_port=29523 \
  "$ROOT/scripts/pretrain_gpt_probing.py" \
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
    if wait_http "$MEGA_PORT" 30 && grep -qE "iteration[[:space:]]+[0-9]+/" "$LOG/train.log" 2>/dev/null; then
      echo "megatron_probe_pid=$MEGA_PROBE_PID port=$MEGA_PORT preset=$PRESET" | tee "$LOG/ready.txt"
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
shot "$BASE/training" "$OUT/web_megatron_training.png" 15
shot "$BASE/" "$OUT/web_megatron_dashboard.png" 12

# 4 卡 collective 样例 CLI
cli_capture() {
  local name=$1 pid=$2 sql=$3
  PROBING_CLI_MODE=1 "$CLI" -t "$pid" query "$sql" >"$OUT/cli_${name}.txt" 2>&1 || true
  local html_file="$OUT/cli_${name}.html"
  PROBING_CLI_MODE=1 python3 - "$OUT/cli_${name}.txt" "$html_file" <<'PY'
import html, sys
from pathlib import Path
txt, html_path = sys.argv[1], sys.argv[2]
body = html.escape(Path(txt).read_text(errors="replace"))
doc = f"""<!doctype html><html><head><meta charset=utf-8>
<style>body{{background:#0d1117;color:#c9d1d9;font:13px/1.45 ui-monospace,Menlo,Consolas,monospace;margin:16px;white-space:pre-wrap;}}</style></head>
<body>{body}</body></html>"""
Path(html_path).write_text(doc)
PY
  "$CHROME" --headless --disable-gpu --no-sandbox --window-size=1200,800 \
    --screenshot="$OUT/cli_${name}.png" "file://$html_file" 2>/dev/null || true
}

if PROBING_CLI_MODE=1 "$CLI" -t "$MEGA_PROBE_PID" query "SELECT 1 FROM python.comm_collective LIMIT 1" >/dev/null 2>&1; then
  cli_capture megatron_collective "$MEGA_PROBE_PID" \
    "SELECT rank, op, duration_ms, bytes FROM python.comm_collective ORDER BY timestamp DESC LIMIT 12"
fi

echo "MEGATRON_CAPTURE_ID=$TS" >>"$OUT/meta.txt"
echo "完成: Megatron ${NPROC}GPU preset=$PRESET (日志 $LOG)"
