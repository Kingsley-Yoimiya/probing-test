#!/usr/bin/env bash
# P2-SW-C Loud contrast on yysong-worker-2: topo_5c (device_rev + EXTRA_AR) + XPUTimer preload.
# Frozen dose (dose_recipes calibrated):
#   device_rev=1,topo_extra_ar=512,topo_ar_elems=262144
# C1 only: reverse ASCEND_VISIBLE_DEVICES + TOPO_EXTRA_AR/TOPO_AR_ELEMS.
# Main evidence = comm_ms (Probing gold C1/C0_comm≈49.86; step≈5.06).
# Do NOT inherit hold-job MASTER_ADDR (often yysong-master-0.yysong).
set -euo pipefail

CODE="${CODE:-/data/yinjinrun.p-huawei/lab-workspace/xputimer}"
SO="${SO:-$CODE/libxpu_timer_ascend.so}"
TBP="${TBP:-/tmp/tbp_npu.py}"
TS="$(date +%Y%m%d_%H%M%S)"
RUN="${RUN:-contrast-p2-sw-c-${TS}}"
DUMP_ROOT="${DUMP_ROOT:-/data/yinjinrun.p-huawei/results/ascend-ais/baseline/xputimer/$RUN}"
NPROC="${NPROC:-16}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
INJECT_START="${INJECT_START:-100}"
INJECT_STOP="${INJECT_STOP:-300}"
DOSE_DEVICE_REV="${TOPO_DEVICE_REV:-1}"
DOSE_EXTRA_AR="${TOPO_EXTRA_AR:-512}"
DOSE_AR_ELEMS="${TOPO_AR_ELEMS:-262144}"
MASTER_PORT_C0="${MASTER_PORT_C0:-30400}"
MASTER_PORT_C1="${MASTER_PORT_C1:-30401}"
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
CASE_REF="${CASE_REF:-20260725_124102-yjr-as-c-p2-sw-c-loud}"
ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate llm_test
# Non-interactive launch skips .bashrc; Ascend libs must be explicit.
# set_env.sh references possibly-unset LD_LIBRARY_PATH/PYTHONPATH — drop nounset briefly.
set +u
if [[ -f /usr/local/Ascend/ascend-toolkit/set_env.sh ]]; then
  # shellcheck disable=SC1091
  source /usr/local/Ascend/ascend-toolkit/set_env.sh
fi
if [[ -f /usr/local/Ascend/nnal/atb/set_env.sh ]]; then
  # shellcheck disable=SC1091
  source /usr/local/Ascend/nnal/atb/set_env.sh
fi
set -u
export PYTHONUNBUFFERED=1
export PATH=/root/miniconda3/envs/llm_test/bin:${PATH}
export GLOO_SOCKET_IFNAME=${GLOO_SOCKET_IFNAME:-eth0}
export HCCL_CONNECT_TIMEOUT=${HCCL_CONNECT_TIMEOUT:-1800}
export HOST_BOUND_MATMUL=${HOST_BOUND_MATMUL:-768}
export CKPT_DIR="${CKPT_DIR:-/data/yinjinrun.p-huawei/probe-bundle/ckpt}"
export PROBING=0
unset PROBING_TORCH_PROFILING PROBING_GPU INLINE_INJECT 2>/dev/null || true

test -f "$SO" || { echo "missing $SO"; exit 2; }
test -f "$TBP" || { echo "missing $TBP"; exit 2; }

pkill -9 -f '[t]bp_npu.py' 2>/dev/null || true
pkill -9 -f '[t]orchrun' 2>/dev/null || true
pkill -9 -x stress-ng 2>/dev/null || true
pkill -9 -f '[s]tress-ng' 2>/dev/null || true
sleep 1

mkdir -p "$DUMP_ROOT" "$CKPT_DIR"

echo "MASTER_ADDR=$MASTER_ADDR NPROC=$NPROC RUN=$RUN"
echo "$RUN" > /tmp/xpu_p2swc_run.txt
echo "$DUMP_ROOT" > /tmp/xpu_p2swc_dump.txt

cat >"$DUMP_ROOT/manifest.yaml" <<EOF
case_id: P2-SW-C
dose: loud
phase: contrast
run_id: $RUN
case_ref: $CASE_REF
world_size: $NPROC
pod: yysong-worker-2
pool: pool-xpu
mode: gpu_bound
inject_kind: topo_5c
inject_args: "device_rev=${DOSE_DEVICE_REV},topo_extra_ar=${DOSE_EXTRA_AR},topo_ar_elems=${DOSE_AR_ELEMS}"
inject_window_measure: [${INJECT_START}, ${INJECT_STOP}]
host_bound_matmul: 768
seed: 42
iters: $ITERS
warmup: $WARMUP
tool: XPUTimer
label_prefix: yjr-as-b-xpu
script: platform/ascend/xputimer/contrast_p2swc.sh
accept_min_ratio: ${ACCEPT_MIN_RATIO}
dose_note: "主证 comm_ms（金标 C1/C0_comm≈49.86）；step≈5.06 旁证；dose_check 优先 comm"
EOF

_reverse_ascend_visible() {
  local avd="${ASCEND_VISIBLE_DEVICES:-0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}"
  if command -v tac >/dev/null 2>&1; then
    echo "$avd" | tr ',' '\n' | tac | paste -sd, -
  else
    # fallback without tac
    echo "$avd" | tr ',' '\n' | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) printf "%s%s", a[i], (i>1?",":"")}'
  fi
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

  # Clear topo inject env between arms (keep DOSE_* immutable under set -u).
  unset TOPO_EXTRA_AR TOPO_AR_ELEMS 2>/dev/null || true
  # Restore a clean visible list for C0; C1 may reverse.
  export ASCEND_VISIBLE_DEVICES="${BASE_ASCEND_VISIBLE:-0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}"

  if [[ "$do_inject" == "1" ]]; then
    export TOPO_EXTRA_AR="$DOSE_EXTRA_AR"
    export TOPO_AR_ELEMS="$DOSE_AR_ELEMS"
    if [[ "$DOSE_DEVICE_REV" == "1" ]]; then
      export ASCEND_VISIBLE_DEVICES="$(_reverse_ascend_visible)"
    fi
  fi

  echo "========== $arm port=$port inject=$do_inject device_rev=${DOSE_DEVICE_REV} extra_ar=${DOSE_EXTRA_AR} ar_elems=${DOSE_AR_ELEMS} ASCEND_VISIBLE=${ASCEND_VISIBLE_DEVICES} =========="
  rm -f "$out/node_0.done" "$out/node_0.fail"
  (
    LD_PRELOAD="$SO" \
    /root/miniconda3/envs/llm_test/bin/torchrun --nnodes=1 --nproc_per_node="$NPROC" --node_rank=0 \
      --master_addr="$MASTER_ADDR" --master_port="$port" \
      "$TBP" --iters="$ITERS" --warmup="$WARMUP" --seed=42 --mode=gpu_bound \
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
        echo "  measure step ${INJECT_START} (${e}s) — topo_5c active from process start"
        break
      fi
      if [[ -f "$out/node_0.fail" ]]; then echo "FAIL before inject"; tail -80 "$out/node_0.log"; return 1; fi
      sleep 2; e=$((e + 2))
    done
    if [[ $e -ge 2400 ]]; then echo "step ${INJECT_START} timeout"; return 1; fi
    {
      echo "SIDECAR_WARMUP kind=topo_5c"
      echo "SIDECAR_START kind=topo_5c"
      echo "TOPO_EXTRA_AR=${DOSE_EXTRA_AR}"
      echo "TOPO_AR_ELEMS=${DOSE_AR_ELEMS}"
      echo "DEVICE_REV=${DOSE_DEVICE_REV}"
      echo "ASCEND_VISIBLE_DEVICES=${ASCEND_VISIBLE_DEVICES}"
    } >"$out/injection.log"
  fi

  e=0
  while [[ $e -lt 3600 ]]; do
    if [[ -f "$out/node_0.done" ]]; then
      echo "  done (${e}s)"
      wait "$train_pid" || true
      return 0
    fi
    if [[ -f "$out/node_0.fail" ]]; then
      echo "  FAIL"; tail -100 "$out/node_0.log" || true
      wait "$train_pid" || true
      return 1
    fi
    sleep 5; e=$((e + 5))
    if (( e % 30 == 0 )); then
      echo "  waiting… t=${e}s prom=$(ls "$xdump"/*.prom 2>/dev/null | wc -l) ranks=$(ls "$out/ranks"/rank_*.jsonl 2>/dev/null | wc -l)"
    fi
  done
  echo "TIMEOUT"; tail -80 "$out/node_0.log" || true
  kill "$train_pid" 2>/dev/null || true
  return 1
}

# Snapshot baseline visible devices before any arm mutates them.
BASE_ASCEND_VISIBLE="${ASCEND_VISIBLE_DEVICES:-0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}"
export BASE_ASCEND_VISIBLE

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
  --case-id P2-SW-C \
  --case-ref "$CASE_REF" \
  --dose-desc "topo_5c device_rev=${DOSE_DEVICE_REV} topo_extra_ar=${DOSE_EXTRA_AR} topo_ar_elems=${DOSE_AR_ELEMS}; window [${INJECT_START},${INJECT_STOP}]" \
  --accept-min-ratio "$ACCEPT_MIN_RATIO" \
  --out "$DUMP_ROOT/CONTRAST_VERDICT.md" \
  --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json"
vrc=$?
set -e
test -f "$DUMP_ROOT/CONTRAST_VERDICT.md" || { echo "missing VERDICT rc=$vrc"; exit 1; }

# Primary dose_check = comm_ms (step is secondary; gold step≈5.06 may also PASS)
COMM_PY="${COMM_PY:-$CODE/dose_check_comm_p2swc.py}"
if [[ -f "$COMM_PY" ]]; then
  python3 "$COMM_PY" \
    --ranks-c0 "$DUMP_ROOT/C0_baseline/ranks" \
    --ranks-c1 "$DUMP_ROOT/C1_inject_none/ranks" \
    --window-start "$INJECT_START" \
    --window-stop "$INJECT_STOP" \
    --accept-min-ratio "$ACCEPT_MIN_RATIO" \
    --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json" \
    --verdict "$DUMP_ROOT/CONTRAST_VERDICT.md" || true
fi

echo "CONTRAST_DONE RUN=$RUN DUMP=$DUMP_ROOT verdict_rc=$vrc"
