#!/usr/bin/env bash
# inject_8a.sh — Case 8A: Python GC 骤停注入
# 周期性大量分配内存，触发 Python GC stop-the-world
# 用法: inject_8a.sh start|stop
set -euo pipefail
ACTION="${1:-start}"
PIDFILE="/tmp/inject_8a_pid"

case "$ACTION" in
  start)
    cat > /tmp/inject_8a_gc_stall.py << 'PYEOF'
"""周期性制造 GC 压力：反复分配大量 Python 对象再释放，迫使 GC 介入。"""
import gc, time, sys
print("INJECT_8A_START", flush=True)
PERIOD = 2.0       # 每 2 秒一次 GC storm
ALLOC_MB = 500     # 每次分配 500MB 的小对象

while True:
    # 分配大量小对象（每个 10KB bytearray 在 list 里）
    garbage = [bytearray(10240) for _ in range(ALLOC_MB * 100)]
    # 强制释放 + GC
    del garbage
    gc.collect()
    time.sleep(PERIOD)
PYEOF
    nohup /opt/conda/bin/python3.12 /tmp/inject_8a_gc_stall.py \
      > /tmp/inject_8a.log 2>&1 &
    echo $! > "$PIDFILE"
    echo "INJECT_8A_STARTED pid=$(cat $PIDFILE)"
    ;;
  stop)
    if [[ -f "$PIDFILE" ]]; then
      kill "$(cat $PIDFILE)" 2>/dev/null || true
      rm -f "$PIDFILE"
      echo "INJECT_8A_STOPPED"
    fi
    ;;
esac
