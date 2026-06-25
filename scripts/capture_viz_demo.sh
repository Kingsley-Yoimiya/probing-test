#!/usr/bin/env bash
# 采集 Probing 可视化素材：CLI 输出 + 真实 Web UI 截图
set -eo pipefail

ROOT="/home/yjr/probing-test"
VENV="$ROOT/probing/.venv"
CLI="$ROOT/probing/target/release/probing-cli"
TS=$(date +%Y%m%d_%H%M%S)
OUT="$ROOT/docs/assets/latest"
LOG="$ROOT/logs/visualization_demo_$TS"
WEB_PORT="${WEB_PORT:-8765}"
GPU="${CUDA_VISIBLE_DEVICES:-1}"

mkdir -p "$OUT" "$LOG"
# 固定目录写入，避免软链接导致 GitHub 无法预览图片
find "$OUT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
echo "CAPTURE_ID=$TS" >"$OUT/meta.txt"
source "$VENV/bin/activate"
unset CONDA_PREFIX CONDA_DEFAULT_ENV PROBING_CLI_MODE
export CUDA_VISIBLE_DEVICES="$GPU"

# 确保 Web UI 资源可用
if [[ ! -f "$ROOT/probing/web/dist/index.html" ]]; then
  echo "Web UI 未构建，正在 Docker 内构建..."
  bash "$ROOT/scripts/build_frontend_docker.sh" | tee "$LOG/build_frontend.log"
fi
export PROBING_ASSETS_ROOT="$ROOT/probing/web/dist"

CHROME="${CHROME:-chromium-browser}"
shot() {
  local url=$1 out=$2 wait=${3:-12}
  sleep "$wait"
  "$CHROME" --headless --disable-gpu --no-sandbox \
    --window-size=1440,900 \
    --virtual-time-budget=20000 \
    --run-all-compositor-stages-before-draw \
    --hide-scrollbars \
    --screenshot="$out" \
    "$url" 2>"$LOG/chrome_${out##*/}.log" || true
}

cli_capture() {
  local name=$1
  shift
  PROBING_CLI_MODE=1 "$@" >"$OUT/cli_${name}.txt" 2>&1 || true
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

wait_probe() {
  local pid=$1
  for _ in $(seq 1 60); do
    kill -0 "$pid" 2>/dev/null || return 1
    PROBING_CLI_MODE=1 "$CLI" -t "$pid" query "SELECT 1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

wait_http() {
  local port=$1 max=${2:-60}
  for _ in $(seq 1 "$max"); do
    if curl -sf "http://127.0.0.1:$port/" | grep -q 'web-dxh\|<div id="main">'; then
      return 0
    fi
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

echo "[1/4] 启动 demo 训练 + Megatron（并行，GPU=$GPU）"
source "$ROOT/scripts/megatron_presets.sh"
export PYTHONPATH="$MEGATRON_ROOT"
export NCCL_IB_DISABLE=1
export GLOO_SOCKET_IFNAME=lo
export MASTER_ADDR=127.0.0.1
MEGA_PORT=$((WEB_PORT + 1))
MEGA_LOG="$LOG/megatron_gpt345m"
mkdir -p "$MEGA_LOG"

PROBING=1 PROBING_PORT="$WEB_PORT" PROBING_SPAN_BACKENDS=memtable,logger \
  PROBING_ASSETS_ROOT="$PROBING_ASSETS_ROOT" \
  DEMO_DURATION_SEC=600 python "$ROOT/scripts/demo_train_viz.py" \
  >"$LOG/demo_train.log" 2>&1 &
DEMO_PID=$!
echo "demo_pid=$DEMO_PID web_ui=$PROBING_ASSETS_ROOT" >>"$OUT/meta.txt"

# shellcheck disable=SC2046
nproc_args=( $(preset_args gpt345m) )
PROBING=1 PROBING_PORT="$MEGA_PORT" PROBING_ASSETS_ROOT="$PROBING_ASSETS_ROOT" \
  torchrun --nproc_per_node=1 --master_port=29501 \
  "$ROOT/scripts/pretrain_gpt_probing.py" \
  "${MEGATRON_COMMON[@]}" "${nproc_args[@]}" \
  --train-iters 80 --exit-interval 80 \
  >"$MEGA_LOG/train.log" 2>&1 &
MEGA_LAUNCHER=$!

if ! wait_probe "$DEMO_PID"; then
  echo "demo probe 未就绪，查看 $LOG/demo_train.log"
  tail -30 "$LOG/demo_train.log"
  exit 1
fi
if ! wait_http "$WEB_PORT"; then
  echo "Demo Web UI 未就绪 (port $WEB_PORT)"
  exit 1
fi

MEGA_PROBE_PID=""
for _ in $(seq 1 180); do
  MEGA_PROBE_PID=$(find_megatron_pid || true)
  if [[ -n "$MEGA_PROBE_PID" ]] && PROBING_CLI_MODE=1 "$CLI" -t "$MEGA_PROBE_PID" query "SELECT 1" >/dev/null 2>&1; then
    if wait_http "$MEGA_PORT" 30; then
      echo "megatron_probe_pid=$MEGA_PROBE_PID mega_port=$MEGA_PORT" >>"$OUT/meta.txt"
      break
    fi
  fi
  sleep 2
done

# Megatron 训练很快，就绪后立即截图（避免 demo Web 截图期间 Megatron 已退出）
if [[ -n "$MEGA_PROBE_PID" ]]; then
  MEGA_BASE="http://127.0.0.1:$MEGA_PORT"
  echo "[1b/4] Megatron 训练进行中，优先采集 Web 截图（/spans 最先，避免进程先退出）"
  shot "$MEGA_BASE/spans" "$OUT/web_megatron_spans.png" 18
  shot "$MEGA_BASE/" "$OUT/web_megatron_dashboard.png" 12
  shot "$MEGA_BASE/training" "$OUT/web_megatron_training.png" 15
fi

echo "[2/4] 采集 CLI 输出"
cli_capture list "$CLI" list -v
cli_capture tables "$CLI" -t "$DEMO_PID" tables
cli_capture query_trace "$CLI" -t "$DEMO_PID" query "
SELECT s.name, s.phase,
       round((e.time - s.time) / 1e6, 2) AS ms
FROM python.trace_event s
JOIN python.trace_event e
  ON s.span_id = e.span_id AND e.record_type = 'span_end'
WHERE s.record_type = 'span_start'
ORDER BY s.time DESC LIMIT 15"
cli_capture memory "$CLI" -t "$DEMO_PID" memory
cli_capture backtrace "$CLI" -t "$DEMO_PID" backtrace
cli_capture config bash -c "curl -sf http://127.0.0.1:$WEB_PORT/config/server.address || echo 'N/A'"

if PROBING_CLI_MODE=1 "$CLI" -t "$DEMO_PID" skill --help >/dev/null 2>&1; then
  cli_capture skill_help "$CLI" -t "$DEMO_PID" skill --help
  cli_capture skill_list "$CLI" -t "$DEMO_PID" skill list 2>/dev/null || true
fi

echo "[3/4] 采集真实 Web UI 截图"
BASE="http://127.0.0.1:$WEB_PORT"
shot "$BASE/" "$OUT/web_dashboard.png" 15
shot "$BASE/spans" "$OUT/web_spans.png" 18
shot "$BASE/training" "$OUT/web_training.png" 18
shot "$BASE/profiling/pprof" "$OUT/web_profiling_pprof.png" 15
shot "$BASE/profiling/trace" "$OUT/web_profiling_trace.png" 15
shot "$BASE/analytics" "$OUT/web_analytics.png" 15
shot "$BASE/python" "$OUT/web_python.png" 15
shot "$BASE/agent" "$OUT/web_agent.png" 15

echo "[3b/4] 采集 2-GPU Step straggler 热力图"
DDP_GPUS="${DDP_GPUS:-2,3}" DDP_PORT="${DDP_PORT:-8767}" DEMO_DURATION_SEC="${HEATMAP_DEMO_SEC:-90}" \
  bash "$ROOT/scripts/capture_training_heatmap.sh" || echo "警告: 热力图采集失败，见 logs/heatmap_demo_*"

if [[ -f "$LOG/demo_train.log" ]]; then
  grep -E "→ |phase=|batch=" "$LOG/demo_train.log" | tail -35 >"$OUT/cli_span_logger.txt" || true
  if [[ -s "$OUT/cli_span_logger.txt" ]]; then
    html_file="$OUT/cli_span_logger.html"
    python3 - "$OUT/cli_span_logger.txt" "$html_file" <<'PY'
import html, sys
from pathlib import Path
txt, html_path = sys.argv[1], sys.argv[2]
body = html.escape(Path(txt).read_text(errors="replace"))
Path(html_path).write_text(f"<!doctype html><style>body{{font:13px monospace;background:#111;color:#0f0;padding:16px;white-space:pre-wrap}}</style><body>{body}</body></html>")
PY
    "$CHROME" --headless --disable-gpu --no-sandbox --window-size=1200,600 \
      --screenshot="$OUT/cli_span_logger.png" "file://$html_file" 2>/dev/null || true
  fi
fi

echo "[4/4] 收尾"
if [[ -n "$MEGA_PROBE_PID" ]]; then
  cli_capture megatron_query "$CLI" -t "$MEGA_PROBE_PID" query "
SELECT local_step, duration_ms, loss FROM train.step ORDER BY local_step DESC LIMIT 10" || true
fi

kill "$DEMO_PID" 2>/dev/null || true
wait "$DEMO_PID" 2>/dev/null || true
[[ -n "$MEGA_LAUNCHER" ]] && wait "$MEGA_LAUNCHER" 2>/dev/null || true

echo "ASSETS_DIR=$OUT" >>"$OUT/meta.txt"
echo "采集完成: $OUT (CAPTURE_ID=$TS, 日志 $LOG)"
