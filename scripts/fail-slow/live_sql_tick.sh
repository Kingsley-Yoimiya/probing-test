#!/usr/bin/env bash
# 注入窗内单次实时 SQL tick。禁止裸 pgrep -n：必须试探到 probing socket 可连的 worker。
#
# 用法（在 pod 内，或经 kubectl exec）：
#   LIVE_OUT=/path/to/live_sql bash live_sql_tick.sh
# 可选：VICTIM_LOCAL_RANK=7 CODE_DIR=/workspace/probe-bundle
set -uo pipefail

CODE_DIR="${CODE_DIR:-/workspace/probe-bundle}"
VICTIM_LOCAL_RANK="${VICTIM_LOCAL_RANK:-7}"
LIVE_OUT="${LIVE_OUT:-./live_sql}"
export PATH="${CODE_DIR}/pydeps/bin:/opt/conda/bin:${PATH:-}"
export PYTHONPATH="${CODE_DIR}/pydeps${PYTHONPATH:+:$PYTHONPATH}"

mkdir -p "$LIVE_OUT"
TS=$(date +%H%M%S)
TICK="$LIVE_OUT/tick_${TS}.txt"
{
  echo "=== live_sql_tick @ $(date -Iseconds) victim_lr=$VICTIM_LOCAL_RANK ==="

  candidate_pids() {
    local prefer="$1"
    ps -eo pid,args | awk -v lr="$prefer" '
      /train_bench_probe|\/tmp\/tbp\.py/ && $0 !~ /awk/ && $0 !~ /bash/ && $0 !~ /torchrun/ {
        score = 1
        if ($0 ~ ("local[_-]rank[= ]*" lr) || $0 ~ ("LOCAL_RANK=" lr)) score = 0
        print score, $1
      }' | sort -n | awk '{print $2}'
  }

  PID=""
  ATTACH="no"
  for cand in $(candidate_pids "$VICTIM_LOCAL_RANK"); do
    if probing -t "$cand" query "SHOW TABLES" >"$LIVE_OUT/_ping_${TS}.txt" 2>&1; then
      if ! grep -qiE "Connection refused|no such process|failed to connect" "$LIVE_OUT/_ping_${TS}.txt"; then
        PID="$cand"
        ATTACH="ok"
        break
      fi
    fi
  done

  echo "attach=$ATTACH pid=${PID:-none}"
  if [ "$ATTACH" != "ok" ]; then
    echo "error=no_probing_attach (tried victim-first tbp workers; do NOT use bare pgrep -n)"
    echo "pgrep_hint:"
    pgrep -af '/tmp/tbp.py' | head -8 || true
    exit 0
  fi

  echo "---- SHOW TABLES ----"
  cat "$LIVE_OUT/_ping_${TS}.txt"
  echo "---- cpu.utilization (process, 20) ----"
  probing -t "$PID" query \
    "SELECT ts, scope, cpu_total_pct, comm FROM cpu.utilization WHERE scope = 'process' ORDER BY ts DESC LIMIT 20" 2>&1 || true
  echo "---- cpu.tasks (40) ----"
  probing -t "$PID" query "SELECT * FROM cpu.tasks LIMIT 40" 2>&1 || true
  echo "---- host pgrep stress (旁证，非 SQL) ----"
  pgrep -af 'stress-ng|stress_cpu' | head -5 || echo "(no stress pgrep)"
} | tee "$TICK"

echo "live_sql_tick → $TICK attach=$ATTACH"
