#!/usr/bin/env bash
# S4 contrast on yysong-worker-2: P3-EXT-A Loud dose + XPUTimer preload.
# Same inject as Case LOUD_OK: stress-ng --cpu $(nproc) --cpu-load 90, window [100,300].
set -euo pipefail

CODE="${CODE:-/data/yinjinrun.p-huawei/lab-workspace/xputimer}"
SO="${SO:-$CODE/libxpu_timer_ascend.so}"
TBP="${TBP:-/tmp/tbp_npu.py}"
STRESS="${STRESS:-/tmp/stress_bundle/stress-ng}"
RUN="${RUN:-yjr-as-b-xpu-s4-$(date +%Y%m%d_%H%M%S)}"
DUMP_ROOT="${DUMP_ROOT:-/data/yinjinrun.p-huawei/results/ascend-ais/baseline/xputimer/$RUN}"
NPROC="${NPROC:-16}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
INJECT_START="${INJECT_START:-100}"
INJECT_STOP="${INJECT_STOP:-300}"
CPU_LOAD="${CPU_LOAD:-90}"
MASTER_PORT_C0="${MASTER_PORT_C0:-30210}"
MASTER_PORT_C1="${MASTER_PORT_C1:-30211}"
MASTER_ADDR="${MASTER_ADDR:-10.119.7.62}"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate llm_test
export PYTHONUNBUFFERED=1
export PATH=/root/miniconda3/envs/llm_test/bin:${PATH}
export GLOO_SOCKET_IFNAME=${GLOO_SOCKET_IFNAME:-eth0}
export HCCL_CONNECT_TIMEOUT=${HCCL_CONNECT_TIMEOUT:-1800}
export HOST_BOUND_MATMUL=${HOST_BOUND_MATMUL:-768}
export CKPT_DIR=/data/yinjinrun.p-huawei/probe-bundle/ckpt
export PROBING=0
export LD_LIBRARY_PATH="/tmp/stress_bundle${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
unset PROBING_TORCH_PROFILING PROBING_GPU 2>/dev/null || true

chmod +x "$STRESS" 2>/dev/null || true
test -x "$STRESS" || { echo "missing stress-ng at $STRESS"; exit 2; }
test -f "$SO" || { echo "missing $SO"; exit 2; }
test -f "$TBP" || { echo "missing $TBP"; exit 2; }

pkill -9 -x stress-ng 2>/dev/null || true
pkill -9 -f '[t]bp_npu.py' 2>/dev/null || true
pkill -9 -f '[t]orchrun' 2>/dev/null || true
sleep 1

mkdir -p "$DUMP_ROOT"
echo "MASTER_ADDR=$MASTER_ADDR NPROC=$NPROC"
echo "$RUN" > /tmp/xpu_s4_run.txt
echo "$DUMP_ROOT" > /tmp/xpu_s4_dump.txt

cat >"$DUMP_ROOT/manifest.yaml" <<EOF
case_id: P3-EXT-A
dose: loud
phase: s4_contrast
run_id: $RUN
case_ref: 20260724_231918-yjr-as-c-p3exta-loud
world_size: $NPROC
pod: yysong-worker-2
pool: pool-xpu
mode: host_bound
inject_kind: stress_cpu
inject_args: "cpu_load=${CPU_LOAD}"
inject_window_measure: [${INJECT_START}, ${INJECT_STOP}]
victim_local_rank: 7
host_bound_matmul: 768
iters: $ITERS
warmup: $WARMUP
tool: XPUTimer
label_prefix: yjr-as-b-xpu
EOF

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

  echo "========== $arm port=$port inject=$do_inject =========="
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

  # warmup: wait first marker or log activity
  local e=0
  while [[ $e -lt 180 ]]; do
    if [[ -f "$out/ranks/step_1.marker" ]] || grep -q "step" "$out/node_0.log" 2>/dev/null; then
      echo "  warmup ok (${e}s)"; break
    fi
    if [[ -f "$out/node_0.fail" ]]; then echo "FAIL warmup"; tail -80 "$out/node_0.log"; return 1; fi
    sleep 2; e=$((e + 2))
  done

  if [[ "$do_inject" == "1" ]]; then
    e=0
    while [[ $e -lt 600 ]]; do
      if [[ -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
        echo "  measure step ${INJECT_START} (${e}s)"
        break
      fi
      if [[ -f "$out/node_0.fail" ]]; then echo "FAIL before inject"; return 1; fi
      sleep 2; e=$((e + 2))
    done
    nohup "$STRESS" --cpu "$(nproc)" --cpu-load "$CPU_LOAD" --timeout 900s \
      >"$out/injection.log" 2>&1 &
    echo "SC=$!" | tee -a "$out/injection.log"
    echo "SIDECAR_START stress_cpu cpu_n=nproc cpu_load=${CPU_LOAD}" >>"$out/injection.log"
    e=0
    while [[ $e -lt 900 ]]; do
      if [[ -f "$out/ranks/step_${INJECT_STOP}.marker" ]]; then
        echo "  measure step ${INJECT_STOP} → stop stress"
        pkill -TERM -x stress-ng 2>/dev/null || true
        sleep 1
        pkill -9 -x stress-ng 2>/dev/null || true
        echo SIDECAR_STOP >>"$out/injection.log"
        break
      fi
      if [[ -f "$out/node_0.done" || -f "$out/node_0.fail" ]]; then break; fi
      sleep 2; e=$((e + 2))
    done
  fi

  e=0
  while [[ $e -lt 1200 ]]; do
    if [[ -f "$out/node_0.done" ]]; then
      echo "  done (${e}s)"
      pkill -9 -x stress-ng 2>/dev/null || true
      wait "$train_pid" || true
      return 0
    fi
    if [[ -f "$out/node_0.fail" ]]; then
      echo "  FAIL"; tail -100 "$out/node_0.log" || true
      pkill -9 -x stress-ng 2>/dev/null || true
      wait "$train_pid" || true
      return 1
    fi
    sleep 5; e=$((e + 5))
    if (( e % 30 == 0 )); then
      echo "  waiting… t=${e}s prom=$(ls "$xdump"/*.prom 2>/dev/null | wc -l)"
    fi
  done
  echo "TIMEOUT"; tail -80 "$out/node_0.log" || true
  pkill -9 -x stress-ng 2>/dev/null || true
  kill "$train_pid" 2>/dev/null || true
  return 1
}

run_arm C0_baseline "$MASTER_PORT_C0" 0
run_arm C1_inject_none "$MASTER_PORT_C1" 1

python3 "$CODE/s4_verdict.py" \
  --c0 "$DUMP_ROOT/C0_baseline/xputimer" \
  --c1 "$DUMP_ROOT/C1_inject_none/xputimer" \
  --out "$DUMP_ROOT/S4_VERDICT.md"
echo "S4_DONE RUN=$RUN DUMP=$DUMP_ROOT"
