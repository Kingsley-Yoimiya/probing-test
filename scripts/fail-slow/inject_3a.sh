#!/usr/bin/env bash
# inject_3a.sh — Case 3A: GPU 算力抢占注入
# 在 victim 节点启动持续 GEMM 工作负载占用 50% 算力
# 用法: inject_3a.sh start|stop [device]
set -euo pipefail
ACTION="${1:-start}"
DEVICE="${2:-0}"
PIDFILE="/tmp/inject_3a_pid"

case "$ACTION" in
  start)
    cat > /tmp/inject_3a_sidecar.py << 'PYEOF'
import os, time, torch
device = int(os.environ.get("INJECT_DEVICE", "0"))
torch.cuda.set_device(device)
N = 4096
A = torch.randn(N, N, device=f"cuda:{device}", dtype=torch.float16)
B = torch.randn(N, N, device=f"cuda:{device}", dtype=torch.float16)
duty = float(os.environ.get("INJECT_DUTY", "0.5"))
period = 0.1  # 100ms cycle
print(f"INJECT_3A_START device={device} duty={duty}", flush=True)
while True:
    t0 = time.perf_counter()
    # Busy phase: continuous GEMM
    while time.perf_counter() - t0 < period * duty:
        torch.mm(A, B)
    # Idle phase
    remaining = period - (time.perf_counter() - t0)
    if remaining > 0:
        time.sleep(remaining)
PYEOF
    INJECT_DEVICE="$DEVICE" INJECT_DUTY="${INJECT_DUTY:-0.5}" \
      nohup /opt/conda/bin/python3.12 /tmp/inject_3a_sidecar.py \
      > /tmp/inject_3a.log 2>&1 &
    echo $! > "$PIDFILE"
    echo "INJECT_3A_STARTED pid=$(cat $PIDFILE) device=$DEVICE"
    ;;
  stop)
    if [[ -f "$PIDFILE" ]]; then
      kill "$(cat $PIDFILE)" 2>/dev/null || true
      rm -f "$PIDFILE"
      echo "INJECT_3A_STOPPED"
    fi
    ;;
esac
