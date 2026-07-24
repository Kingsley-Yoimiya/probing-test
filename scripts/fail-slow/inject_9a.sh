#!/usr/bin/env bash
# inject_9a.sh — Case 9A: CPU 核心全占抢夺
# stress-ng 打满所有 CPU，影响 DataLoader / GIL 竞争 / Python 线程
# 用法: inject_9a.sh start|stop
set -euo pipefail
ACTION="${1:-start}"
PIDFILE="/tmp/inject_9a_pid"

case "$ACTION" in
  start)
    NCPU=$(nproc)
    nohup stress-ng --cpu "$NCPU" --cpu-method matrixprod --timeout 600s \
      > /tmp/inject_9a.log 2>&1 &
    echo $! > "$PIDFILE"
    echo "INJECT_9A_STARTED pid=$(cat $PIDFILE) cpus=$NCPU"
    ;;
  stop)
    if [[ -f "$PIDFILE" ]]; then
      kill "$(cat $PIDFILE)" 2>/dev/null || true
      # stress-ng spawns children
      pkill -f "stress-ng" 2>/dev/null || true
      rm -f "$PIDFILE"
      echo "INJECT_9A_STOPPED"
    fi
    ;;
esac
