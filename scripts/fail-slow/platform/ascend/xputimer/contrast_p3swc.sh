#!/usr/bin/env bash
# P3-SW-C Loud contrast on yysong-worker-2: sidecar 8c (stress-ng+leak) + XPUTimer preload.
# Frozen dose (dose_recipes calibrated):
#   cpu_n=nproc,cpu_load=90,mb=1,leak_every=1.0,max_chunks=64
# Window [100,300]; mode=host_bound.
# Gold: C1/C0 step_ms≈2.49 (host_bound 8c).
# Do NOT inherit hold-job MASTER_ADDR (often yysong-master-0.yysong).
set -euo pipefail

CODE="${CODE:-/data/yinjinrun.p-huawei/lab-workspace/xputimer}"
SO="${SO:-$CODE/libxpu_timer_ascend.so}"
TBP="${TBP:-/tmp/tbp_npu.py}"
SIDECAR_PY="${SIDECAR_PY:-/tmp/sidecar_inject_8c.py}"
# Prefer system stress-ng; fall back to stress_bundle (P3-EXT-*).
if command -v stress-ng >/dev/null 2>&1; then
  STRESS_BIN="$(command -v stress-ng)"
elif [[ -x /tmp/stress_bundle/stress-ng ]]; then
  STRESS_BIN=/tmp/stress_bundle/stress-ng
  export PATH="/tmp/stress_bundle:${PATH}"
  export LD_LIBRARY_PATH="/tmp/stress_bundle${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
else
  STRESS_BIN=""
fi
TS="$(date +%Y%m%d_%H%M%S)"
RUN="${RUN:-contrast-p3-sw-c-${TS}}"
DUMP_ROOT="${DUMP_ROOT:-/data/yinjinrun.p-huawei/results/ascend-ais/baseline/xputimer/$RUN}"
NPROC="${NPROC:-16}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
INJECT_START="${INJECT_START:-100}"
INJECT_STOP="${INJECT_STOP:-300}"
# empty SIDECAR_8C_CPU_N → sidecar defaults to nproc
SIDECAR_8C_CPU_N="${SIDECAR_8C_CPU_N:-}"
SIDECAR_8C_CPU_LOAD="${SIDECAR_8C_CPU_LOAD:-90}"
SIDECAR_8C_MB="${SIDECAR_8C_MB:-1}"
SIDECAR_8C_LEAK_EVERY="${SIDECAR_8C_LEAK_EVERY:-1.0}"
SIDECAR_8C_MAX_CHUNKS="${SIDECAR_8C_MAX_CHUNKS:-64}"
VICTIM_LOCAL="${VICTIM_LOCAL:-7}"
MASTER_PORT_C0="${MASTER_PORT_C0:-30280}"
MASTER_PORT_C1="${MASTER_PORT_C1:-30281}"
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
CASE_REF="${CASE_REF:-20260725_135238-yjr-as-c-p3-sw-c-loud}"
ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"

# Ascend libs (bashrc sources these on interactive -lc; nohup/non-login needs explicit)
# set_env.sh references unset vars — temporarily relax nounset
set +u
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64/driver:${LD_LIBRARY_PATH:-}
# shellcheck disable=SC1091
source /usr/local/Ascend/ascend-toolkit/set_env.sh
# shellcheck disable=SC1091
[[ -f /usr/local/Ascend/nnal/atb/set_env.sh ]] && source /usr/local/Ascend/nnal/atb/set_env.sh
set -u
source /root/miniconda3/etc/profile.d/conda.sh
conda activate llm_test
export PYTHONUNBUFFERED=1
export PATH=/root/miniconda3/envs/llm_test/bin:${PATH}
# re-apply stress_bundle PATH after conda (if used)
if [[ -n "${STRESS_BIN:-}" && "$STRESS_BIN" == /tmp/stress_bundle/* ]]; then
  export PATH="/tmp/stress_bundle:${PATH}"
  export LD_LIBRARY_PATH="/tmp/stress_bundle${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
export GLOO_SOCKET_IFNAME=${GLOO_SOCKET_IFNAME:-eth0}
export HCCL_CONNECT_TIMEOUT=${HCCL_CONNECT_TIMEOUT:-1800}
export HOST_BOUND_MATMUL=${HOST_BOUND_MATMUL:-768}
export CKPT_DIR="${CKPT_DIR:-/data/yinjinrun.p-huawei/probe-bundle/ckpt}"
export PROBING=0
unset PROBING_TORCH_PROFILING PROBING_GPU INLINE_INJECT 2>/dev/null || true

test -f "$SO" || { echo "missing $SO"; exit 2; }
test -f "$TBP" || { echo "missing $TBP"; exit 2; }
test -f "$SIDECAR_PY" || { echo "missing $SIDECAR_PY"; exit 2; }
if [[ -z "${STRESS_BIN:-}" ]] || ! command -v stress-ng >/dev/null 2>&1; then
  echo "WARN: stress-ng not on PATH (sidecar may fall back to busy workers)"; 
fi

pkill -9 -f '[t]bp_npu.py' 2>/dev/null || true
pkill -9 -f '[t]orchrun' 2>/dev/null || true
pkill -9 -f '[s]idecar_inject_8c' 2>/dev/null || true
pkill -9 -x stress-ng 2>/dev/null || true
pkill -9 -f '[s]tress-ng' 2>/dev/null || true
sleep 1

mkdir -p "$DUMP_ROOT" "$CKPT_DIR"

CPU_N_DISP="${SIDECAR_8C_CPU_N:-nproc}"
echo "MASTER_ADDR=$MASTER_ADDR NPROC=$NPROC RUN=$RUN"
echo "dose: cpu_n=${CPU_N_DISP} cpu_load=${SIDECAR_8C_CPU_LOAD} mb=${SIDECAR_8C_MB} leak_every=${SIDECAR_8C_LEAK_EVERY} max_chunks=${SIDECAR_8C_MAX_CHUNKS}"
echo "$RUN" > /tmp/xpu_p3swc_run.txt
echo "$DUMP_ROOT" > /tmp/xpu_p3swc_dump.txt

cat >"$DUMP_ROOT/manifest.yaml" <<EOF
case_id: P3-SW-C
dose: loud
phase: contrast
run_id: $RUN
case_ref: $CASE_REF
world_size: $NPROC
pod: yysong-worker-2
pool: pool-xpu
mode: host_bound
inject_kind: sidecar_8c
inject_args: "cpu_n=${CPU_N_DISP},cpu_load=${SIDECAR_8C_CPU_LOAD},mb=${SIDECAR_8C_MB},leak_every=${SIDECAR_8C_LEAK_EVERY},max_chunks=${SIDECAR_8C_MAX_CHUNKS}"
inject_window_measure: [${INJECT_START}, ${INJECT_STOP}]
victim_local_rank: ${VICTIM_LOCAL}
host_bound_matmul: 768
seed: 42
iters: $ITERS
warmup: $WARMUP
tool: XPUTimer
label_prefix: yjr-as-b-xpu
script: platform/ascend/xputimer/contrast_p3swc.sh
accept_min_ratio: ${ACCEPT_MIN_RATIO}
gold_step_ratio: 2.49
EOF

stop_8c() {
  pkill -TERM -f '[s]idecar_inject_8c' 2>/dev/null || true
  pkill -TERM -x stress-ng 2>/dev/null || true
  pkill -TERM -f '[s]tress-ng' 2>/dev/null || true
  sleep 1
  pkill -9 -f '[s]idecar_inject_8c' 2>/dev/null || true
  pkill -9 -x stress-ng 2>/dev/null || true
  pkill -9 -f '[s]tress-ng' 2>/dev/null || true
}

start_8c() {
  local out="$1"
  mkdir -p "$out"
  : >"$out/injection.log"
  # clear then set dose env (empty CPU_N → nproc inside sidecar)
  unset SIDECAR_8C_CPU_N 2>/dev/null || true
  export SIDECAR_8C_CPU_LOAD="$SIDECAR_8C_CPU_LOAD"
  export SIDECAR_8C_MB="$SIDECAR_8C_MB"
  export SIDECAR_8C_LEAK_EVERY="$SIDECAR_8C_LEAK_EVERY"
  export SIDECAR_8C_MAX_CHUNKS="$SIDECAR_8C_MAX_CHUNKS"
  # under set -u must use ${VAR:-} after unset
  if [[ -n "${SIDECAR_8C_CPU_N:-}" ]]; then
    export SIDECAR_8C_CPU_N
  fi
  nohup /root/miniconda3/envs/llm_test/bin/python -u "$SIDECAR_PY" --case 8c --seconds 1800 \
    >"$out/injection.log" 2>&1 &
  echo "SC=$!" | tee -a "$out/injection.log"
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

  # clear any inline inject; 8c is host sidecar only
  unset INLINE_INJECT INLINE_VICTIM_LOCAL_RANK INLINE_INJECT_START INLINE_INJECT_STOP \
        INLINE_GC_EVERY INLINE_GC_STALL_S INLINE_HBM_MB INLINE_HBM_COPIES \
        INLINE_CUBE_SIZE INLINE_CUBE_MM INLINE_8B_MB INLINE_8B_STALL_S 2>/dev/null || true
  stop_8c

  echo "========== $arm port=$port inject=$do_inject 8c cpu_n=${CPU_N_DISP} load=${SIDECAR_8C_CPU_LOAD} =========="
  rm -f "$out/node_0.done" "$out/node_0.fail"
  # set +e inside subshell: parent has set -e; non-zero torchrun must still write .fail
  (
    set +e
    LD_PRELOAD="$SO" \
    /root/miniconda3/envs/llm_test/bin/torchrun --nnodes=1 --nproc_per_node="$NPROC" --node_rank=0 \
      --master_addr="$MASTER_ADDR" --master_port="$port" \
      "$TBP" --iters="$ITERS" --warmup="$WARMUP" --seed=42 --mode=host_bound \
      --model=gpt2 --seq=1024 --batch=8 --flush-every=5 --ckpt-every=100 \
      --run-id="$RUN" --group="$arm" --config="$arm" --round=1 \
      --out-dir="$out/ranks" >"$out/node_0.log" 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then touch "$out/node_0.done"; else echo $rc >"$out/node_0.fail"; fi
    exit 0
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
        echo "  measure step ${INJECT_START} (${e}s) — start sidecar 8c"
        break
      fi
      if [[ -f "$out/node_0.fail" ]]; then echo "FAIL before inject"; tail -80 "$out/node_0.log"; return 1; fi
      sleep 2; e=$((e + 2))
    done
    if [[ $e -ge 2400 ]]; then echo "step ${INJECT_START} timeout"; return 1; fi

    start_8c "$out"
    e=0
    while [[ $e -lt 60 ]]; do
      if grep -q 'SIDECAR_START' "$out/injection.log" 2>/dev/null; then
        echo "  8c sidecar START ok (${e}s)"
        break
      fi
      if ! pgrep -f '[s]idecar_inject_8c' >/dev/null 2>&1; then
        echo "  8c sidecar died without START"; tail -60 "$out/injection.log" || true
        return 1
      fi
      sleep 2; e=$((e + 2))
    done
    if [[ $e -ge 60 ]]; then
      echo "  8c sidecar START timeout"; tail -80 "$out/injection.log" || true
      return 1
    fi

    e=0
    while [[ $e -lt 2400 ]]; do
      if [[ -f "$out/ranks/step_${INJECT_STOP}.marker" ]]; then
        echo "  measure step ${INJECT_STOP} → stop 8c"
        stop_8c
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
      stop_8c
      wait "$train_pid" || true
      return 0
    fi
    if [[ -f "$out/node_0.fail" ]]; then
      echo "  FAIL"; tail -100 "$out/node_0.log" || true
      stop_8c
      wait "$train_pid" || true
      return 1
    fi
    sleep 5; e=$((e + 5))
    if (( e % 30 == 0 )); then
      echo "  waiting… t=${e}s prom=$(ls "$xdump"/*.prom 2>/dev/null | wc -l) ranks=$(ls "$out/ranks"/rank_*.jsonl 2>/dev/null | wc -l)"
    fi
  done
  echo "TIMEOUT"; tail -80 "$out/node_0.log" || true
  stop_8c
  kill "$train_pid" 2>/dev/null || true
  return 1
}

run_arm C0_baseline "$MASTER_PORT_C0" 0
run_arm C1_inject_none "$MASTER_PORT_C1" 1

VERDICT_PY="${VERDICT_PY:-$CODE/s4_verdict.py}"
# exit 2 = no bite (still DONE); only fail if verdict writer itself crashes
set +e
python3 "$VERDICT_PY" \
  --c0 "$DUMP_ROOT/C0_baseline/xputimer" \
  --c1 "$DUMP_ROOT/C1_inject_none/xputimer" \
  --ranks-c0 "$DUMP_ROOT/C0_baseline/ranks" \
  --ranks-c1 "$DUMP_ROOT/C1_inject_none/ranks" \
  --case-id P3-SW-C \
  --case-ref "$CASE_REF" \
  --dose-desc "sidecar 8c cpu_n=${CPU_N_DISP} cpu_load=${SIDECAR_8C_CPU_LOAD} mb=${SIDECAR_8C_MB} leak_every=${SIDECAR_8C_LEAK_EVERY} max_chunks=${SIDECAR_8C_MAX_CHUNKS}; window [${INJECT_START},${INJECT_STOP}]" \
  --accept-min-ratio "$ACCEPT_MIN_RATIO" \
  --out "$DUMP_ROOT/CONTRAST_VERDICT.md" \
  --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json"
vrc=$?
set -e
test -f "$DUMP_ROOT/CONTRAST_VERDICT.md" || { echo "missing VERDICT rc=$vrc"; exit 1; }
echo "CONTRAST_DONE RUN=$RUN DUMP=$DUMP_ROOT verdict_rc=$vrc"
