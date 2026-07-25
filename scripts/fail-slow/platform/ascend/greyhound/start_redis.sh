#!/usr/bin/env bash
# 在自有前缀启动 Greyhound 专用 Redis（默认 :16379，勿占 Case 6379）。
# 用法（pod 内）:
#   bash start_redis.sh [/data/yinjinrun.p-huawei/opt/redis]
set -euo pipefail

ROOT="${1:-/data/yinjinrun.p-huawei/opt/redis}"
BIN="${ROOT}/bin/redis-server"
CLI="${ROOT}/bin/redis-cli"
PORT="${REDIS_PORT:-16379}"
HOST="${REDIS_HOST:-127.0.0.1}"
RUN_DIR="${FS_GH_REDIS_DIR:-/data/yinjinrun.p-huawei/results/ascend-ais/baseline/greyhound/redis}"
PID_FILE="$RUN_DIR/redis-${PORT}.pid"
LOG_FILE="$RUN_DIR/redis-${PORT}.log"

mkdir -p "$RUN_DIR"
if [[ ! -x "$BIN" ]]; then
  echo "FATAL: missing $BIN (build Redis first)" >&2
  exit 2
fi

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "REDIS_ALREADY pid=$(cat "$PID_FILE") port=$PORT"
  "$CLI" -h "$HOST" -p "$PORT" ping
  exit 0
fi

# 已有监听则复用
if "$CLI" -h "$HOST" -p "$PORT" ping 2>/dev/null | grep -q PONG; then
  echo "REDIS_ALREADY_LISTEN port=$PORT"
  exit 0
fi

nohup "$BIN" \
  --save "" --appendonly no \
  --bind "$HOST" --port "$PORT" \
  --daemonize no \
  --pidfile "$PID_FILE" \
  --logfile "$LOG_FILE" \
  --dir "$RUN_DIR" \
  >"$RUN_DIR/redis-${PORT}.outer.log" 2>&1 &
echo $! >"$PID_FILE"
sleep 0.5
"$CLI" -h "$HOST" -p "$PORT" ping
echo "REDIS_OK host=$HOST port=$PORT pid=$(cat "$PID_FILE") log=$LOG_FILE"
