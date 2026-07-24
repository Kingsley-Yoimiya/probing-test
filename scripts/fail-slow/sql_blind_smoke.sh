#!/usr/bin/env bash
# A2：stress 同时起带 PROBING 的短进程，证明 cpu.tasks 仍无 stress 字样。
set -euo pipefail
OUT="${OUT:?need OUT}"
CODE_DIR="${CODE_DIR:-/workspace/probe-bundle}"
export PATH="${CODE_DIR}/pydeps/bin:/opt/conda/bin:${PATH:-}"
export PYTHONPATH="${CODE_DIR}/pydeps${PYTHONPATH:+:$PYTHONPATH}"
mkdir -p "$OUT"

# 最小挂 probing 的 sleep 进程（不跑训练）
export PROBING=1
export PROBING_TORCH_PROFILING=0
python3 - <<'PY' &
import os, time, sys
sys.path.insert(0, "/workspace/probe-bundle/pydeps")
try:
    from probing.site_hook import run_site_hook
    run_site_hook()
    print("site_hook=ok", flush=True)
except Exception as e:
    print(f"site_hook=fail {e}", flush=True)
time.sleep(45)
PY
PPID_PY=$!
sleep 2

# stress 并行
stress-ng --cpu "${CPU_N:-16}" --timeout 20s >"$OUT/stress_a2.log" 2>&1 &
SPID=$!
sleep 5

ATTACH=no
PID=""
for cand in $(pgrep -f 'python3 -' || true); do
  [ -d "/proc/$cand" ] || continue
  if probing -t "$cand" query "SHOW TABLES" >"$OUT/ping.txt" 2>&1; then
    if ! grep -qiE "Connection refused|failed to connect" "$OUT/ping.txt"; then
      PID=$cand
      ATTACH=ok
      break
    fi
  fi
done
# 也试 sleep 子进程的真实 pid
if [ "$ATTACH" != "ok" ]; then
  for cand in $(pgrep -P "$PPID_PY" 2>/dev/null; echo "$PPID_PY"); do
    if probing -t "$cand" query "SHOW TABLES" >"$OUT/ping.txt" 2>&1; then
      if ! grep -qiE "Connection refused|failed to connect" "$OUT/ping.txt"; then
        PID=$cand
        ATTACH=ok
        break
      fi
    fi
  done
fi

echo "attach=$ATTACH pid=${PID:-none}" | tee "$OUT/attach.txt"
if [ "$ATTACH" = "ok" ]; then
  probing -t "$PID" query "SELECT * FROM cpu.tasks LIMIT 80" >"$OUT/cpu_tasks.txt" 2>&1 || true
  if grep -qiE 'stress' "$OUT/cpu_tasks.txt"; then
    echo "SQL_SEES_STRESS=yes" | tee "$OUT/verdict.env"
  else
    echo "SQL_SEES_STRESS=no" | tee "$OUT/verdict.env"
  fi
else
  echo "SQL_SEES_STRESS=attach_fail" | tee "$OUT/verdict.env"
fi

# 旁证：host 上 stress 确实在跑（不算 D4 证据）
pgrep -af stress-ng | head -5 >"$OUT/host_pgrep_stress.txt" || true

wait "$SPID" || true
kill "$PPID_PY" 2>/dev/null || true
wait "$PPID_PY" 2>/dev/null || true

{
  echo "# A2 SQL blind smoke"
  echo "- attach: $ATTACH pid=${PID:-none}"
  echo "- host stress pgrep: $(wc -l <"$OUT/host_pgrep_stress.txt" | tr -d ' ') lines"
  echo "- $(cat "$OUT/verdict.env")"
  if [ -f "$OUT/cpu_tasks.txt" ]; then
    echo
    echo '```'
    head -40 "$OUT/cpu_tasks.txt"
    echo '```'
  fi
} | tee "$OUT/SUMMARY.md"
