#!/usr/bin/env bash
# P3-EXT-C Loud contrast on yysong-worker-2: stress_vm + XPUTimer preload.
# Frozen dose (dose_recipes calibrated):
#   vm_n=96,vm_bytes=6G
# Window [100,300]; mode=host_bound.
# Do NOT inherit hold-job MASTER_ADDR (often yysong-master-0.yysong).
set -euo pipefail

CODE="${CODE:-/data/yinjinrun.p-huawei/lab-workspace/xputimer}"
SO="${SO:-$CODE/libxpu_timer_ascend.so}"
TBP="${TBP:-/tmp/tbp_npu.py}"
STRESS="${STRESS:-/tmp/stress_bundle/stress-ng}"
TS="$(date +%Y%m%d_%H%M%S)"
RUN="${RUN:-contrast-p3-ext-c-${TS}}"
DUMP_ROOT="${DUMP_ROOT:-/data/yinjinrun.p-huawei/results/ascend-ais/baseline/xputimer/$RUN}"
NPROC="${NPROC:-16}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
INJECT_START="${INJECT_START:-100}"
INJECT_STOP="${INJECT_STOP:-300}"
VM_N="${VM_N:-96}"
VM_BYTES="${VM_BYTES:-6G}"
VICTIM_LOCAL="${VICTIM_LOCAL:-7}"
MASTER_PORT_C0="${MASTER_PORT_C0:-30250}"
MASTER_PORT_C1="${MASTER_PORT_C1:-30251}"
_local_ip() {
  # Prefer eth0 / route src; avoid inheriting hold-job MASTER_ADDR (master-0).
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
    [[ -z "$ip" ]] && ip="$(ip -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  # Single-node torchrun accepts loopback; never use yysong-master-0 DNS.
  echo "${ip:-127.0.0.1}"
}
MASTER_ADDR="${FORCE_MASTER_ADDR:-$(_local_ip)}"
CASE_REF="${CASE_REF:-20260725_021906-yjr-as-c-p3-ext-c-loud}"
ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate llm_test
export PYTHONUNBUFFERED=1
export PATH=/root/miniconda3/envs/llm_test/bin:${PATH}
export GLOO_SOCKET_IFNAME=${GLOO_SOCKET_IFNAME:-eth0}
export HCCL_CONNECT_TIMEOUT=${HCCL_CONNECT_TIMEOUT:-1800}
export HOST_BOUND_MATMUL=${HOST_BOUND_MATMUL:-768}
export CKPT_DIR="${CKPT_DIR:-/data/yinjinrun.p-huawei/probe-bundle/ckpt}"
export PROBING=0
export LD_LIBRARY_PATH="/tmp/stress_bundle${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
unset PROBING_TORCH_PROFILING PROBING_GPU INLINE_INJECT 2>/dev/null || true

test -f "$SO" || { echo "missing $SO"; exit 2; }
test -f "$TBP" || { echo "missing $TBP"; exit 2; }
test -x "$STRESS" || chmod +x "$STRESS" 2>/dev/null || true
test -x "$STRESS" || { echo "missing stress-ng at $STRESS"; exit 2; }

pkill -9 -f '[t]bp_npu.py' 2>/dev/null || true
pkill -9 -f '[t]orchrun' 2>/dev/null || true
pkill -9 -x stress-ng 2>/dev/null || true
pkill -9 -f '[s]tress-ng' 2>/dev/null || true
sleep 1

mkdir -p "$DUMP_ROOT" "$CKPT_DIR"

echo "MASTER_ADDR=$MASTER_ADDR NPROC=$NPROC RUN=$RUN"
echo "$RUN" > /tmp/xpu_p3extc_run.txt
echo "$DUMP_ROOT" > /tmp/xpu_p3extc_dump.txt

cat >"$DUMP_ROOT/manifest.yaml" <<EOF
case_id: P3-EXT-C
dose: loud
phase: contrast
run_id: $RUN
case_ref: $CASE_REF
world_size: $NPROC
pod: yysong-worker-2
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
EOF

stop_vm() {
  pkill -TERM -x stress-ng 2>/dev/null || true
  pkill -TERM -f '[s]tress-ng' 2>/dev/null || true
  sleep 1
  pkill -9 -x stress-ng 2>/dev/null || true
  pkill -9 -f '[s]tress-ng' 2>/dev/null || true
}

start_vm() {
  local out="$1"
  mkdir -p "$out"
  : >"$out/injection.log"
  {
    echo "SIDECAR_START stress_vm_n=${VM_N}_bytes=${VM_BYTES}"
    if test -r /proc/pressure/memory; then
      echo '---PSI_MEMORY---'
      cat /proc/pressure/memory
      echo '---PSI_CPU---'
      cat /proc/pressure/cpu
    else
      echo 'PSI_UNAVAIL no_/proc/pressure'
    fi
  } >>"$out/injection.log"
  nohup "$STRESS" --vm "$VM_N" --vm-bytes "$VM_BYTES" --vm-keep --page-in --timeout 900s \
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
  echo "========== $arm port=$port inject=$do_inject vm_n=${VM_N} vm_bytes=${VM_BYTES} =========="
  rm -f "$out/node_0.done" "$out/node_0.fail"
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
    if [[ -f "$out/ranks/warmup_done" ]] || [[ -f "$out/ranks/step_1.marker" ]] \
       || grep -q "step" "$out/node_0.log" 2>/dev/null; then
      echo "  warmup ok (${e}s)"; break
    fi
    if [[ -f "$out/node_0.fail" ]]; then echo "FAIL warmup"; tail -80 "$out/node_0.log"; return 1; fi
    sleep 2; e=$((e + 2))
  done
  if [[ $e -ge 360 ]]; then echo "warmup timeout"; tail -80 "$out/node_0.log"; return 1; fi

  if [[ "$do_inject" == "1" ]]; then
    e=0
    while [[ $e -lt 2400 ]]; do
      if [[ -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
        echo "  measure step ${INJECT_START} (${e}s) — start stress_vm"
        break
      fi
      if [[ -f "$out/node_0.fail" ]]; then echo "FAIL before inject"; tail -80 "$out/node_0.log"; return 1; fi
      sleep 2; e=$((e + 2))
    done
    if [[ $e -ge 2400 ]]; then echo "step ${INJECT_START} timeout"; return 1; fi

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
        echo "  measure step ${INJECT_STOP} → stop vm"
        stop_vm
        echo SIDECAR_STOP >>"$out/injection.log"
        break
      fi
      if [[ -f "$out/node_0.done" || -f "$out/node_0.fail" ]]; then break; fi
      sleep 2; e=$((e + 2))
    done
  fi

  e=0
  while [[ $e -lt 2400 ]]; do
    if [[ -f "$out/node_0.done" ]]; then
      echo "  done (${e}s)"
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
set +e
python3 "$VERDICT_PY" \
  --c0 "$DUMP_ROOT/C0_baseline/xputimer" \
  --c1 "$DUMP_ROOT/C1_inject_none/xputimer" \
  --ranks-c0 "$DUMP_ROOT/C0_baseline/ranks" \
  --ranks-c1 "$DUMP_ROOT/C1_inject_none/ranks" \
  --case-id P3-EXT-C \
  --case-ref "$CASE_REF" \
  --dose-desc "stress_vm vm_n=${VM_N},vm_bytes=${VM_BYTES}; window [${INJECT_START},${INJECT_STOP}]" \
  --accept-min-ratio "$ACCEPT_MIN_RATIO" \
  --out "$DUMP_ROOT/CONTRAST_VERDICT.md" \
  --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json"
vrc=$?
set -e
test -f "$DUMP_ROOT/CONTRAST_VERDICT.md" || { echo "missing VERDICT rc=$vrc"; exit 1; }
echo "CONTRAST_DONE RUN=$RUN DUMP=$DUMP_ROOT verdict_rc=$vrc"
