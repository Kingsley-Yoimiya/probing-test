#!/usr/bin/env bash
# P1-EXT-B contrast on yysong-worker-2: INLINE HBM + XPUTimer preload.
# dose=loud (default): mb=512,copies=48；thr=1.6；金标≈2.02
# dose=quiet:          mb=256,copies=16；thr=1.15；金标≈1.161（Loud 冻结规则只复测）
# dose=masked:         mb=192,copies=10；thr=1.05；金标≈1.070（Loud 冻结规则只复测）
# Window [100,300]; mode=gpu_bound; victim local_rank=7.
# Verdict: 分列自主 hang/slow flags vs 跨-run coll 中位比；勿误标 autonomous。
# Do NOT inherit hold-job MASTER_ADDR (often yysong-master-0.yysong).
set -euo pipefail

DOSE="${DOSE:-loud}"
HOLD_POD="${HOLD_POD:-yysong-worker-2}"
CODE="${CODE:-/data/yinjinrun.p-huawei/lab-workspace/xputimer}"
SO="${SO:-$CODE/libxpu_timer_ascend.so}"
TBP="${TBP:-/tmp/tbp_npu.py}"
TS="$(date +%Y%m%d_%H%M%S)"
if [[ "$DOSE" == "quiet" ]]; then
  RUN="${RUN:-contrast-p1-ext-b-quiet-${TS}}"
  HBM_MB="${HBM_MB:-256}"
  HBM_COPIES="${HBM_COPIES:-16}"
  CASE_REF="${CASE_REF:-20260726_033758-yjr-as-c-p1-ext-b-quiet}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}"
  GOLD_STEP_RATIO="${GOLD_STEP_RATIO:-1.161}"
  MASTER_PORT_C0="${MASTER_PORT_C0:-30270}"
  MASTER_PORT_C1="${MASTER_PORT_C1:-30271}"
elif [[ "$DOSE" == "masked" ]]; then
  RUN="${RUN:-contrast-p1-ext-b-masked-${TS}}"
  HBM_MB="${HBM_MB:-192}"
  HBM_COPIES="${HBM_COPIES:-10}"
  CASE_REF="${CASE_REF:-20260726_040309-yjr-as-c-p1-ext-b-masked}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.05}"
  GOLD_STEP_RATIO="${GOLD_STEP_RATIO:-1.070}"
  MASTER_PORT_C0="${MASTER_PORT_C0:-30272}"
  MASTER_PORT_C1="${MASTER_PORT_C1:-30273}"
else
  RUN="${RUN:-contrast-p1-ext-b-${TS}}"
  HBM_MB="${HBM_MB:-512}"
  HBM_COPIES="${HBM_COPIES:-48}"
  CASE_REF="${CASE_REF:-20260725_014350-yjr-as-c-p1-ext-b-loud}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.6}"
  GOLD_STEP_RATIO="${GOLD_STEP_RATIO:-2.02}"
  MASTER_PORT_C0="${MASTER_PORT_C0:-30230}"
  MASTER_PORT_C1="${MASTER_PORT_C1:-30231}"
fi
# Prefer AFS results when writable; fallback /data
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

# Ascend libs (bashrc sources these on interactive -lc; nohup/non-login needs explicit)
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
sleep 1

mkdir -p "$DUMP_ROOT" "$CKPT_DIR"
echo "MASTER_ADDR=$MASTER_ADDR NPROC=$NPROC RUN=$RUN dose=${DOSE} pod=${HOLD_POD} hbm=${HBM_MB}MB×${HBM_COPIES}"
echo "$RUN" > /tmp/xpu_p1extb_run.txt
echo "$DUMP_ROOT" > /tmp/xpu_p1extb_dump.txt

cat >"$DUMP_ROOT/manifest.yaml" <<EOF
case_id: P1-EXT-B
dose: ${DOSE}
phase: contrast
run_id: $RUN
case_ref: $CASE_REF
world_size: $NPROC
pod: ${HOLD_POD}
pool: pool-xpu
mode: gpu_bound
inject_kind: inline_hbm
inject_args: "inline_hbm_mb=${HBM_MB},inline_hbm_copies=${HBM_COPIES}"
inject_window_measure: [${INJECT_START}, ${INJECT_STOP}]
victim_local_rank: ${VICTIM_LOCAL}
host_bound_matmul: 768
seed: 42
iters: $ITERS
warmup: $WARMUP
tool: XPUTimer
label_prefix: yjr-as-b-xpu
script: platform/ascend/xputimer/contrast_p1extb.sh
accept_min_ratio: ${ACCEPT_MIN_RATIO}
gold_step_ratio: ${GOLD_STEP_RATIO}
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

  unset INLINE_INJECT INLINE_VICTIM_LOCAL_RANK INLINE_INJECT_START INLINE_INJECT_STOP \
        INLINE_HBM_MB INLINE_HBM_COPIES INLINE_CUBE_SIZE INLINE_CUBE_MM \
        INLINE_HBM_COPIES_MAX INLINE_HBM_RAMP 2>/dev/null || true
  if [[ "$do_inject" == "1" ]]; then
    export INLINE_INJECT=hbm
    export INLINE_VICTIM_LOCAL_RANK="$VICTIM_LOCAL"
    export INLINE_INJECT_START="$INJECT_START"
    export INLINE_INJECT_STOP="$INJECT_STOP"
    export INLINE_HBM_MB="$HBM_MB"
    export INLINE_HBM_COPIES="$HBM_COPIES"
  fi

  echo "========== $arm port=$port inject=$do_inject hbm=${HBM_MB}MB×${HBM_COPIES} =========="
  rm -f "$out/node_0.done" "$out/node_0.fail"
  (
    set +e
    LD_PRELOAD="$SO" \
    /root/miniconda3/envs/llm_test/bin/torchrun --nnodes=1 --nproc_per_node="$NPROC" --node_rank=0 \
      --master_addr="$MASTER_ADDR" --master_port="$port" \
      "$TBP" --iters="$ITERS" --warmup="$WARMUP" --seed=42 --mode=gpu_bound \
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
        echo "  measure step ${INJECT_START} (${e}s) — inline hbm active"
        break
      fi
      if [[ -f "$out/node_0.fail" ]]; then echo "FAIL before inject"; tail -80 "$out/node_0.log"; return 1; fi
      sleep 2; e=$((e + 2))
    done
    if [[ $e -ge 2400 ]]; then echo "step ${INJECT_START} timeout"; return 1; fi
    grep -E "INLINE_HBM|SIDECAR" "$out/node_0.log" 2>/dev/null | head -20 >"$out/injection.log" || true
    echo "SIDECAR_START kind=inline_hbm mb=${HBM_MB} copies=${HBM_COPIES} victim=${VICTIM_LOCAL}" >>"$out/injection.log"
    PHYS=$(echo "${ASCEND_VISIBLE_DEVICES:-0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}" | cut -d, -f$((VICTIM_LOCAL+1)))
    npu-smi info -t usages -i "${PHYS:-0}" 2>/dev/null | head -40 >"$out/npu_smi_util_inject.txt" \
      || npu-smi info 2>/dev/null | head -80 >"$out/npu_smi_util_inject.txt" || true
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
set +e
python3 "$VERDICT_PY" \
  --c0 "$DUMP_ROOT/C0_baseline/xputimer" \
  --c1 "$DUMP_ROOT/C1_inject_none/xputimer" \
  --ranks-c0 "$DUMP_ROOT/C0_baseline/ranks" \
  --ranks-c1 "$DUMP_ROOT/C1_inject_none/ranks" \
  --case-id P1-EXT-B \
  --case-ref "$CASE_REF" \
  --dose "$DOSE" \
  --dose-desc "INLINE hbm mb=${HBM_MB} copies=${HBM_COPIES} victim=${VICTIM_LOCAL}; window [${INJECT_START},${INJECT_STOP}]; gold≈${GOLD_STEP_RATIO}" \
  --accept-min-ratio "$ACCEPT_MIN_RATIO" \
  --out "$DUMP_ROOT/CONTRAST_VERDICT.md" \
  --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json"
vrc=$?
set -e
test -f "$DUMP_ROOT/CONTRAST_VERDICT.md" || { echo "missing VERDICT rc=$vrc"; exit 1; }
echo "CONTRAST_DONE RUN=$RUN DUMP=$DUMP_ROOT verdict_rc=$vrc"
