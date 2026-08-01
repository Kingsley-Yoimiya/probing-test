#!/usr/bin/env bash
# P3-EXT-C contrast on yysong-worker-2: stress_vm sidecar + XPUTimer preload.
# dose=loud (default): vm_n=96,vm_bytes=6G；thr=1.3；金标≈1.59
# dose=quiet:          vm_n=32,vm_bytes=4G；thr=1.15；金标≈1.906（formal `102936`）
# dose=masked:         vm_n=32,vm_bytes=4G（=quiet lean；formal `122130`）；thr=1.05；金标≈1.744
# Window [100,300]; mode=host_bound; victim local_rank=7.
# Verdict: 分列自主 hang/slow flags vs 跨-run coll 中位比；勿误标 autonomous。
# Hold pod 默认 yysong-worker-2（勿用 master / grj）。
# Do NOT inherit hold-job MASTER_ADDR (often yysong-master-0.yysong).
set -euo pipefail

DOSE="${DOSE:-loud}"
HOLD_POD="${HOLD_POD:-yysong-worker-2}"
CODE="${CODE:-/data/yinjinrun.p-huawei/lab-workspace/xputimer}"
SO="${SO:-$CODE/libxpu_timer_ascend.so}"
TBP="${TBP:-/tmp/tbp_npu.py}"
STRESS="${STRESS:-/tmp/stress_bundle/stress-ng}"
TS="$(date +%Y%m%d_%H%M%S)"
if [[ "$DOSE" == "quiet" ]]; then
  RUN="${RUN:-contrast-p3-ext-c-quiet-${TS}}"
  VM_N="${VM_N:-32}"
  VM_BYTES="${VM_BYTES:-4G}"
  CASE_REF="${CASE_REF:-20260726_102936-yjr-as-c-p3-ext-c-quiet}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}"
  GOLD_STEP_RATIO="${GOLD_STEP_RATIO:-1.906}"
  MASTER_PORT_C0="${MASTER_PORT_C0:-30420}"
  MASTER_PORT_C1="${MASTER_PORT_C1:-30421}"
elif [[ "$DOSE" == "masked" ]]; then
  RUN="${RUN:-contrast-p3-ext-c-masked-${TS}}"
  VM_N="${VM_N:-32}"
  VM_BYTES="${VM_BYTES:-4G}"
  CASE_REF="${CASE_REF:-20260726_122130-yjr-as-c-p3-ext-c-masked}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.05}"
  GOLD_STEP_RATIO="${GOLD_STEP_RATIO:-1.744}"
  MASTER_PORT_C0="${MASTER_PORT_C0:-30422}"
  MASTER_PORT_C1="${MASTER_PORT_C1:-30423}"
else
  RUN="${RUN:-contrast-p3-ext-c-${TS}}"
  VM_N="${VM_N:-96}"
  VM_BYTES="${VM_BYTES:-6G}"
  CASE_REF="${CASE_REF:-20260725_021906-yjr-as-c-p3-ext-c-loud}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"
  GOLD_STEP_RATIO="${GOLD_STEP_RATIO:-1.59}"
  MASTER_PORT_C0="${MASTER_PORT_C0:-30250}"
  MASTER_PORT_C1="${MASTER_PORT_C1:-30251}"
fi
# Prefer AFS results when writable (hold pod may lack /data write); fallback /data
if [[ -z "${DUMP_ROOT:-}" ]]; then
  if [[ -d /afs-a3-weight-share/yinjinrun.p-huawei/results/ascend-ais ]]; then
    DUMP_ROOT="/afs-a3-weight-share/yinjinrun.p-huawei/results/ascend-ais/baseline/xputimer/$RUN"
  else
    DUMP_ROOT="/data/yinjinrun.p-huawei/results/ascend-ais/baseline/xputimer/$RUN"
  fi
fi
NPROC="${NPROC:-16}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
INJECT_START="${INJECT_START:-100}"
INJECT_STOP="${INJECT_STOP:-300}"
VICTIM_LOCAL="${VICTIM_LOCAL:-7}"
_local_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
    [[ -z "$ip" ]] && ip="$(ip -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  echo "${ip:-127.0.0.1}"
}
MASTER_ADDR="${FORCE_MASTER_ADDR:-$(_local_ip)}"
# 硬约束：单机 16 卡对照优先 loopback（与 GH quiet 一致）
MASTER_ADDR="${FORCE_MASTER_ADDR:-127.0.0.1}"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate llm_test
export PYTHONUNBUFFERED=1
export PATH=/root/miniconda3/envs/llm_test/bin:${PATH}
export GLOO_SOCKET_IFNAME=${GLOO_SOCKET_IFNAME:-eth0}
export HCCL_CONNECT_TIMEOUT=${HCCL_CONNECT_TIMEOUT:-1800}
export HOST_BOUND_MATMUL=${HOST_BOUND_MATMUL:-768}
export CKPT_DIR="${CKPT_DIR:-/data/yinjinrun.p-huawei/probe-bundle/ckpt}"
export PROBING=0
export LD_LIBRARY_PATH="/tmp/stress_bundle:/usr/local/Ascend/cann-8.5.0/aarch64-linux/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
unset PROBING_TORCH_PROFILING PROBING_GPU INLINE_INJECT 2>/dev/null || true

if [[ ! -f "$TBP" ]]; then
  TBP="/data/yinjinrun.p-huawei/probe-bundle/train_bench_probe_npu.py"
fi
chmod +x "$STRESS" 2>/dev/null || true
if [[ ! -x "$STRESS" ]]; then
  for c in /usr/bin/stress-ng /bin/stress-ng "$(command -v stress-ng 2>/dev/null || true)"; do
    if [[ -n "$c" && -x "$c" ]]; then STRESS="$c"; break; fi
  done
fi
test -f "$SO" || { echo "missing $SO"; exit 2; }
test -f "$TBP" || { echo "missing $TBP"; exit 2; }
test -x "$STRESS" || { echo "missing stress-ng at $STRESS"; exit 2; }

live_stress_pids() {
  # Prefer non-zombie PIDs; pgrep alone may match defunct.
  ps -eo pid=,stat=,comm= 2>/dev/null | awk '$3 ~ /stress/ && $2 !~ /Z/ {print $1}'
}
count_zombie_stress() {
  ps -eo stat=,comm= 2>/dev/null | awk '$1 ~ /Z/ && $2 ~ /stress/ {c++} END {print c+0}'
}

# only kill OUR leftovers on this hold pod (live only; zombies stay until init reaps)
pkill -9 -f '[t]bp_npu.py' 2>/dev/null || true
pkill -9 -f '[t]orchrun' 2>/dev/null || true
pkill -9 -f '[t]rain_bench_probe_npu' 2>/dev/null || true
pkill -9 -x stress-ng 2>/dev/null || true
pkill -9 -f '[s]tress-ng' 2>/dev/null || true
kill -CHLD 1 2>/dev/null || true
sleep 1
echo "preflight zombie_stress=$(count_zombie_stress) live_stress=$(live_stress_pids | wc -l | tr -d ' ')"

mkdir -p "$DUMP_ROOT" "$CKPT_DIR"

echo "MASTER_ADDR=$MASTER_ADDR NPROC=$NPROC RUN=$RUN dose=${DOSE} pod=${HOLD_POD} vm_n=${VM_N} vm_bytes=${VM_BYTES}"
echo "$RUN" > /tmp/xpu_p3extc_run.txt
echo "$DUMP_ROOT" > /tmp/xpu_p3extc_dump.txt

cat >"$DUMP_ROOT/manifest.yaml" <<EOF
case_id: P3-EXT-C
dose: ${DOSE}
phase: contrast
run_id: $RUN
case_ref: $CASE_REF
world_size: $NPROC
pod: ${HOLD_POD}
pool: pool-xpu
mode: host_bound
inject_kind: stress_vm
inject_args: "vm_n=${VM_N},vm_bytes=${VM_BYTES}"
inject_window_measure: [${INJECT_START}, ${INJECT_STOP}]
victim_local_rank: ${VICTIM_LOCAL}
host_bound_matmul: 768
seed: 42
iters: $ITERS
warmup: $WARMUP
tool: XPUTimer
label_prefix: yjr-as-b-xpu
script: platform/ascend/xputimer/contrast_p3extc.sh
accept_min_ratio: ${ACCEPT_MIN_RATIO}
gold_step_ratio: ${GOLD_STEP_RATIO}
master_addr: ${MASTER_ADDR}
EOF

stop_vm() {
  local pids
  pids="$(live_stress_pids)"
  if [[ -n "$pids" ]]; then
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    sleep 1
    pids="$(live_stress_pids)"
    if [[ -n "$pids" ]]; then
      # shellcheck disable=SC2086
      kill -9 $pids 2>/dev/null || true
    fi
  fi
  pkill -TERM -x stress-ng 2>/dev/null || true
  pkill -9 -x stress-ng 2>/dev/null || true
  kill -CHLD 1 2>/dev/null || true
}

start_vm() {
  local out="$1"
  mkdir -p "$out"
  : >"$out/injection.log"
  {
    echo "SIDECAR_START stress_vm_n=${VM_N}_bytes=${VM_BYTES} dose=${DOSE}"
    if test -r /proc/pressure/memory; then
      echo '---PSI_MEMORY---'
      cat /proc/pressure/memory
      echo '---PSI_CPU---'
      cat /proc/pressure/cpu
    else
      echo 'PSI_UNAVAIL no_/proc/pressure'
    fi
  } >>"$out/injection.log"
  nohup env LD_LIBRARY_PATH=/tmp/stress_bundle:${LD_LIBRARY_PATH:-} "$STRESS" \
    --vm "$VM_N" --vm-bytes "$VM_BYTES" --vm-keep --page-in --timeout 900s \
    >>"$out/injection.log" 2>&1 &
  echo "SC=$!" | tee -a "$out/injection.log"
  {
    echo '---AFTER_INJECT---'
    date -Iseconds 2>/dev/null || date
    free -h | head -3
    if test -r /proc/pressure/memory; then
      cat /proc/pressure/memory
      cat /proc/pressure/cpu
    else
      echo PSI_UNAVAIL
    fi
  } >>"$out/injection.log" 2>&1 || true
}

run_arm() {
  local arm="$1" port="$2" do_inject="$3"
  local out="$DUMP_ROOT/$arm"
  local xdump="$out/xputimer"
  mkdir -p "$out/ranks" "$xdump"
  export XPU_TIMER_DUMP_DIR="$xdump"
  export XPU_TIMER_DUMP_INTERVAL_S=2
  export XPU_TIMER_SLOW_REPORT_US=0
  export XPU_TIMER_HANG_TIMEOUT_MS=60000
  export XPU_TIMER_INJECT_STALL_MS=0

  stop_vm
  echo "========== $arm port=$port inject=$do_inject vm_n=${VM_N} vm_bytes=${VM_BYTES} dose=${DOSE} =========="
  rm -f "$out/node_0.done" "$out/node_0.fail" "$out/ranks"/step_*.marker "$out/ranks"/warmup_done
  rm -f "$out/ranks"/rank_*.jsonl
  (
    LD_PRELOAD="$SO" \
    /root/miniconda3/envs/llm_test/bin/torchrun --nnodes=1 --nproc_per_node="$NPROC" --node_rank=0 \
      --master_addr="$MASTER_ADDR" --master_port="$port" \
      "$TBP" --iters="$ITERS" --warmup="$WARMUP" --seed=42 --mode=host_bound \
      --model=gpt2 --seq=1024 --batch=8 --flush-every=5 --ckpt-every=100 \
      --run-id="$RUN" --group="$arm" --config="$arm" --round=1 \
      --out-dir="$out/ranks" >"$out/node_0.log" 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then touch "$out/node_0.done"; else echo $rc >"$out/node_0.fail"; fi
  ) &
  local train_pid=$!

  local e=0
  while [[ $e -lt 360 ]]; do
    if [[ -f "$out/ranks/warmup_done" || -f "$out/ranks/step_1.marker" || -f "$out/ranks/step_${INJECT_START}.marker" ]] \
       || grep -q "step" "$out/node_0.log" 2>/dev/null; then
      echo "  warmup ok (${e}s)"; break
    fi
    if [[ -f "$out/node_0.fail" ]]; then echo "FAIL warmup"; tail -80 "$out/node_0.log"; return 1; fi
    if [[ -f "$out/node_0.done" ]]; then echo "  train finished during warmup wait"; break; fi
    sleep 1; e=$((e + 1))
  done
  if [[ ! -f "$out/ranks/warmup_done" && ! -f "$out/ranks/step_1.marker" && ! -f "$out/ranks/step_${INJECT_START}.marker" && ! -f "$out/node_0.done" ]]; then
    if ! grep -q "step" "$out/node_0.log" 2>/dev/null; then
      echo "FAIL warmup timeout"; tail -80 "$out/node_0.log"; return 1
    fi
  fi

  if [[ "$do_inject" == "1" ]]; then
    e=0
    while [[ $e -lt 2400 ]]; do
      if [[ -f "$out/ranks/step_${INJECT_STOP}.marker" ]]; then
        echo "FAIL inject window already past step ${INJECT_STOP} before start"; return 1
      fi
      if [[ -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
        echo "  measure step ${INJECT_START} (${e}s) → start stress_vm"
        break
      fi
      if [[ -f "$out/node_0.fail" ]]; then echo "FAIL before inject"; tail -80 "$out/node_0.log"; return 1; fi
      if [[ -f "$out/node_0.done" ]]; then echo "FAIL train ended before inject start"; return 1; fi
      sleep 1; e=$((e + 1))
    done
    if [[ ! -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
      echo "FAIL never reached inject start"; return 1
    fi
    if [[ -f "$out/ranks/step_${INJECT_STOP}.marker" ]]; then
      echo "FAIL inject start too late (stop marker exists)"; return 1
    fi

    start_vm "$out"
    e=0
    while [[ $e -lt 30 ]]; do
      if grep -q 'SIDECAR_START' "$out/injection.log" 2>/dev/null; then
        echo "  stress_vm START ok (${e}s)"; break
      fi
      sleep 1; e=$((e + 1))
    done

    e=0
    while [[ $e -lt 2400 ]]; do
      if [[ -f "$out/ranks/step_${INJECT_STOP}.marker" ]]; then
        echo "  measure step ${INJECT_STOP} → stop vm (${e}s)"
        stop_vm
        echo "SIDECAR_STOP ts=$(date +%s) held_s=${e}" >>"$out/injection.log"
        break
      fi
      if [[ -f "$out/node_0.done" || -f "$out/node_0.fail" ]]; then
        echo "WARN train ended before inject stop"; break
      fi
      if [[ $e -ge 2 ]] && [[ -z "$(live_stress_pids)" ]]; then
        echo "FAIL stress-ng died early (live=0; zombies ignored)"; cat "$out/injection.log"; return 1
      fi
      sleep 1; e=$((e + 1))
    done
  fi

  e=0
  while [[ $e -lt 2400 ]]; do
    if [[ -f "$out/node_0.done" ]]; then
      echo "  done (${e}s) prom=$(ls "$xdump"/*.prom 2>/dev/null | wc -l)"
      stop_vm
      wait "$train_pid" || true
      return 0
    fi
    if [[ -f "$out/node_0.fail" ]]; then
      echo "  FAIL"; tail -100 "$out/node_0.log" || true
      stop_vm
      wait "$train_pid" || true
      return 1
    fi
    sleep 5; e=$((e + 5))
    if (( e % 30 == 0 )); then
      echo "  waiting… t=${e}s prom=$(ls "$xdump"/*.prom 2>/dev/null | wc -l) ranks=$(ls "$out/ranks"/rank_*.jsonl 2>/dev/null | wc -l)"
    fi
  done
  echo "TIMEOUT"; tail -80 "$out/node_0.log" || true
  stop_vm
  kill "$train_pid" 2>/dev/null || true
  return 1
}

run_arm C0_baseline "$MASTER_PORT_C0" 0
run_arm C1_inject_none "$MASTER_PORT_C1" 1

VERDICT_PY="${VERDICT_PY:-$CODE/s4_verdict.py}"
# Prefer co-located verdict next to this script if CODE copy is stale
if [[ -f "$(dirname "$0")/s4_verdict.py" ]]; then
  VERDICT_PY="$(dirname "$0")/s4_verdict.py"
fi
DOSE_DESC="stress_vm vm_n=${VM_N},vm_bytes=${VM_BYTES} victim=${VICTIM_LOCAL}; window [${INJECT_START},${INJECT_STOP}]; gold≈${GOLD_STEP_RATIO}"
# exit 2 = no bite (still DONE); only fail if verdict writer itself crashes
set +e
python3 "$VERDICT_PY" \
  --c0 "$DUMP_ROOT/C0_baseline/xputimer" \
  --c1 "$DUMP_ROOT/C1_inject_none/xputimer" \
  --ranks-c0 "$DUMP_ROOT/C0_baseline/ranks" \
  --ranks-c1 "$DUMP_ROOT/C1_inject_none/ranks" \
  --case-id P3-EXT-C \
  --case-ref "$CASE_REF" \
  --dose "$DOSE" \
  --dose-desc "$DOSE_DESC" \
  --accept-min-ratio "$ACCEPT_MIN_RATIO" \
  --out "$DUMP_ROOT/CONTRAST_VERDICT.md" \
  --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json"
vrc=$?
set -e
test -f "$DUMP_ROOT/CONTRAST_VERDICT.md" || { echo "missing VERDICT rc=$vrc"; exit 1; }
if [[ -f "$DUMP_ROOT/C1_inject_none/injection.log" ]]; then
  cp -f "$DUMP_ROOT/C1_inject_none/injection.log" "$DUMP_ROOT/injection.log" || true
fi
stop_vm
echo "CONTRAST_DONE RUN=$RUN DUMP=$DUMP_ROOT verdict_rc=$vrc"
