#!/usr/bin/env bash
# P2-SW-B Loud contrast on yysong-worker-2: HCCL algo/buff clamp + XPUTimer preload.
# Frozen dose (dose_recipes calibrated):
#   algo=ring,stress_mb=512,buffsize=8
# C0/C1 both open HCCL_STRESS_MB; only C1 clamps HCCL_ALGO+HCCL_BUFFSIZE.
# Main evidence = comm_ms (Probing gold C1/C0_comm=1.82; step≈1.13 not FAIL).
# Do NOT inherit hold-job MASTER_ADDR (often yysong-master-0.yysong).
set -euo pipefail

CODE="${CODE:-/data/yinjinrun.p-huawei/lab-workspace/xputimer}"
SO="${SO:-$CODE/libxpu_timer_ascend.so}"
TBP="${TBP:-/tmp/tbp_npu.py}"
TS="$(date +%Y%m%d_%H%M%S)"
RUN="${RUN:-contrast-p2-sw-b-${TS}}"
DUMP_ROOT="${DUMP_ROOT:-/data/yinjinrun.p-huawei/results/ascend-ais/baseline/xputimer/$RUN}"
NPROC="${NPROC:-16}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
INJECT_START="${INJECT_START:-100}"
INJECT_STOP="${INJECT_STOP:-300}"
DOSE_ALGO="${HCCL_ALGO_V:-ring}"
DOSE_STRESS_MB="${HCCL_STRESS_MB:-512}"
DOSE_BUFFSIZE="${HCCL_BUFFSIZE_V:-8}"
MASTER_PORT_C0="${MASTER_PORT_C0:-30300}"
MASTER_PORT_C1="${MASTER_PORT_C1:-30301}"
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
CASE_REF="${CASE_REF:-20260725_122911-yjr-as-c-p2-sw-b-loud}"
ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"

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
echo "$RUN" > /tmp/xpu_p2swb_run.txt
echo "$DUMP_ROOT" > /tmp/xpu_p2swb_dump.txt

cat >"$DUMP_ROOT/manifest.yaml" <<EOF
case_id: P2-SW-B
dose: loud
phase: contrast
run_id: $RUN
case_ref: $CASE_REF
world_size: $NPROC
pod: yysong-worker-2
pool: pool-xpu
mode: gpu_bound
inject_kind: hccl_algo
inject_args: "algo=${DOSE_ALGO},stress_mb=${DOSE_STRESS_MB},buffsize=${DOSE_BUFFSIZE}"
inject_window_measure: [${INJECT_START}, ${INJECT_STOP}]
host_bound_matmul: 768
seed: 42
iters: $ITERS
warmup: $WARMUP
tool: XPUTimer
label_prefix: yjr-as-b-xpu
script: platform/ascend/xputimer/contrast_p2swb.sh
accept_min_ratio: ${ACCEPT_MIN_RATIO}
dose_note: "主证 comm_ms（金标 C1/C0_comm=1.82）；step≈1.13 不 FAIL；dose_check 优先 comm"
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

  # Both arms: large AllReduce stress. Only C1: clamp HCCL_ALGO + buffsize.
  # Keep DOSE_* immutable under set -u; unset only the inject env keys.
  unset HCCL_ALGO HCCL_BUFFSIZE 2>/dev/null || true
  export HCCL_STRESS_MB="$DOSE_STRESS_MB"
  if [[ "$do_inject" == "1" ]]; then
    export HCCL_ALGO="level0:NA;level1:${DOSE_ALGO}"
    export HCCL_BUFFSIZE="$DOSE_BUFFSIZE"
  fi

  echo "========== $arm port=$port inject=$do_inject algo=${DOSE_ALGO} stress_mb=${DOSE_STRESS_MB} buffsize=${DOSE_BUFFSIZE} =========="
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
        echo "  measure step ${INJECT_START} (${e}s) — hccl_algo clamp active from process start"
        break
      fi
      if [[ -f "$out/node_0.fail" ]]; then echo "FAIL before inject"; tail -80 "$out/node_0.log"; return 1; fi
      sleep 2; e=$((e + 2))
    done
    if [[ $e -ge 2400 ]]; then echo "step ${INJECT_START} timeout"; return 1; fi
    {
      echo "INLINE_INJECT kind=hccl_algo"
      echo "SIDECAR_START kind=hccl_algo"
      echo "HCCL_ALGO=level0:NA;level1=${DOSE_ALGO}"
      echo "HCCL_STRESS_MB=${DOSE_STRESS_MB}"
      echo "HCCL_BUFFSIZE=${DOSE_BUFFSIZE}"
    } >"$out/injection.log"
  fi

  e=0
  while [[ $e -lt 2400 ]]; do
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
  --case-id P2-SW-B \
  --case-ref "$CASE_REF" \
  --dose-desc "hccl_algo algo=${DOSE_ALGO} stress_mb=${DOSE_STRESS_MB} buffsize=${DOSE_BUFFSIZE}; window [${INJECT_START},${INJECT_STOP}]" \
  --accept-min-ratio "$ACCEPT_MIN_RATIO" \
  --out "$DUMP_ROOT/CONTRAST_VERDICT.md" \
  --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json"
vrc=$?
set -e
test -f "$DUMP_ROOT/CONTRAST_VERDICT.md" || { echo "missing VERDICT rc=$vrc"; exit 1; }

# Primary dose_check = comm_ms (step weak rise must not solely fail dose)
COMM_PY="${COMM_PY:-$CODE/dose_check_comm_p2swb.py}"
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
