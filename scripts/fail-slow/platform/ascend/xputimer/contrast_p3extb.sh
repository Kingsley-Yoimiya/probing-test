#!/usr/bin/env bash
# P3-EXT-B Loud contrast on yysong-worker-2: stress_io/fio + XPUTimer preload.
# Frozen dose (dose_recipes calibrated):
#   fio_nj=16,iodepth=64,bs=4k,size=4G,ckpt_every=20,io_read_kb=1024
# Window [100,300]; mode=host_bound. ckpt+payload 与 IO stress 同盘。
# Do NOT inherit hold-job MASTER_ADDR (often yysong-master-0.yysong).
set -euo pipefail

CODE="${CODE:-/data/yinjinrun.p-huawei/lab-workspace/xputimer}"
SO="${SO:-$CODE/libxpu_timer_ascend.so}"
TBP="${TBP:-/tmp/tbp_npu.py}"
STRESS="${STRESS:-/tmp/stress_bundle/stress-ng}"
TS="$(date +%Y%m%d_%H%M%S)"
RUN="${RUN:-contrast-p3-ext-b-${TS}}"
DUMP_ROOT="${DUMP_ROOT:-/data/yinjinrun.p-huawei/results/ascend-ais/baseline/xputimer/$RUN}"
NPROC="${NPROC:-16}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
INJECT_START="${INJECT_START:-100}"
INJECT_STOP="${INJECT_STOP:-300}"
FIO_NJ="${FIO_NJ:-16}"
FIO_IODEPTH="${FIO_IODEPTH:-64}"
FIO_BS="${FIO_BS:-4k}"
FIO_SIZE="${FIO_SIZE:-4G}"
CKPT_EVERY="${CKPT_EVERY:-20}"
FLUSH_EVERY="${FLUSH_EVERY:-1}"
IO_READ_KB="${IO_READ_KB:-1024}"
HDD_N="${HDD_N:-32}"
HDD_BYTES="${HDD_BYTES:-2G}"
IOMIX_N="${IOMIX_N:-16}"
IO_STRESS_DIR="${IO_STRESS_DIR:-/data/yinjinrun.p-huawei/probe-bundle/io_stress}"
IO_PAYLOAD="${IO_PAYLOAD:-${IO_STRESS_DIR}/payload.bin}"
CKPT_DIR="${CKPT_DIR:-${IO_STRESS_DIR}/ckpt}"
VICTIM_LOCAL="${VICTIM_LOCAL:-7}"
MASTER_PORT_C0="${MASTER_PORT_C0:-30240}"
MASTER_PORT_C1="${MASTER_PORT_C1:-30241}"
_local_ip() {
  if command -v hostname >/dev/null 2>&1; then
    hostname -I 2>/dev/null | awk '{print $1}'
  elif command -v ip >/dev/null 2>&1; then
    ip -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
  else
    echo 127.0.0.1
  fi
}
MASTER_ADDR="${FORCE_MASTER_ADDR:-$(_local_ip)}"
CASE_REF="${CASE_REF:-20260725_020212-yjr-as-c-p3-ext-b-loud}"
ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate llm_test
export PYTHONUNBUFFERED=1
export PATH=/root/miniconda3/envs/llm_test/bin:${PATH}
export GLOO_SOCKET_IFNAME=${GLOO_SOCKET_IFNAME:-eth0}
export HCCL_CONNECT_TIMEOUT=${HCCL_CONNECT_TIMEOUT:-1800}
export HOST_BOUND_MATMUL=${HOST_BOUND_MATMUL:-768}
export CKPT_DIR
export PROBING=0
export LD_LIBRARY_PATH="/tmp/stress_bundle${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
unset PROBING_TORCH_PROFILING PROBING_GPU INLINE_INJECT 2>/dev/null || true

test -f "$SO" || { echo "missing $SO"; exit 2; }
test -f "$TBP" || { echo "missing $TBP"; exit 2; }
chmod +x "$STRESS" 2>/dev/null || true

pkill -9 -f '[t]bp_npu.py' 2>/dev/null || true
pkill -9 -f '[t]orchrun' 2>/dev/null || true
pkill -9 -x stress-ng 2>/dev/null || true
pkill -9 -f '[s]tress-ng' 2>/dev/null || true
pkill -9 -f 'fio.*io_stress' 2>/dev/null || true
sleep 1

mkdir -p "$DUMP_ROOT" "$IO_STRESS_DIR" "$CKPT_DIR"
if [[ ! -f "$IO_PAYLOAD" ]]; then
  echo "prep payload $IO_PAYLOAD"
  dd if=/dev/urandom of="$IO_PAYLOAD" bs=1M count=64 status=none 2>/dev/null \
    || dd if=/dev/zero of="$IO_PAYLOAD" bs=1M count=64
fi

echo "MASTER_ADDR=$MASTER_ADDR NPROC=$NPROC RUN=$RUN"
echo "$RUN" > /tmp/xpu_p3extb_run.txt
echo "$DUMP_ROOT" > /tmp/xpu_p3extb_dump.txt

cat >"$DUMP_ROOT/manifest.yaml" <<EOF
case_id: P3-EXT-B
dose: loud
phase: contrast
run_id: $RUN
case_ref: $CASE_REF
world_size: $NPROC
pod: yysong-worker-2
pool: pool-xpu
mode: host_bound
inject_kind: stress_io
inject_args: "fio_nj=${FIO_NJ},iodepth=${FIO_IODEPTH},bs=${FIO_BS},size=${FIO_SIZE},ckpt_every=${CKPT_EVERY},io_read_kb=${IO_READ_KB}"
inject_window_measure: [${INJECT_START}, ${INJECT_STOP}]
victim_local_rank: ${VICTIM_LOCAL}
host_bound_matmul: 768
io_stress_dir: ${IO_STRESS_DIR}
ckpt_dir: ${CKPT_DIR}
seed: 42
iters: $ITERS
warmup: $WARMUP
tool: XPUTimer
label_prefix: yjr-as-b-xpu
script: platform/ascend/xputimer/contrast_p3extb.sh
accept_min_ratio: ${ACCEPT_MIN_RATIO}
EOF

stop_io() {
  pkill -TERM -x stress-ng 2>/dev/null || true
  pkill -TERM -f '[s]tress-ng' 2>/dev/null || true
  pkill -TERM -f 'fio.*io_stress' 2>/dev/null || true
  sleep 1
  pkill -9 -x stress-ng 2>/dev/null || true
  pkill -9 -f '[s]tress-ng' 2>/dev/null || true
  pkill -9 -f 'fio.*io_stress' 2>/dev/null || true
}

start_io() {
  local out="$1"
  mkdir -p "$IO_STRESS_DIR"
  : >"$out/injection.log"
  if command -v fio >/dev/null 2>&1; then
    nohup fio --name=io_stress --rw=randrw --bs="$FIO_BS" --size="$FIO_SIZE" \
      --numjobs="$FIO_NJ" --iodepth="$FIO_IODEPTH" --time_based --runtime=900 \
      --directory="$IO_STRESS_DIR" --group_reporting \
      >"$out/injection.log" 2>&1 &
    echo "SC=$!" | tee -a "$out/injection.log"
    echo "SIDECAR_START fio_loud_nj${FIO_NJ} dir=${IO_STRESS_DIR}" >>"$out/injection.log"
  else
    test -x "$STRESS" || { echo "missing fio and stress-ng"; return 2; }
    nohup "$STRESS" --temp-path "$IO_STRESS_DIR" \
      --hdd "$HDD_N" --hdd-bytes "$HDD_BYTES" \
      --iomix "$IOMIX_N" --iomix-bytes "$HDD_BYTES" \
      --timeout 900s >"$out/injection.log" 2>&1 &
    echo "SC=$!" | tee -a "$out/injection.log"
    echo "SIDECAR_START stress_io hdd_n=${HDD_N} hdd_bytes=${HDD_BYTES} iomix_n=${IOMIX_N} dir=${IO_STRESS_DIR} (no fio; fallback)" >>"$out/injection.log"
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

  stop_io
  echo "========== $arm port=$port inject=$do_inject fio_nj=${FIO_NJ} ckpt_every=${CKPT_EVERY} =========="
  rm -f "$out/node_0.done" "$out/node_0.fail"
  (
    LD_PRELOAD="$SO" \
    /root/miniconda3/envs/llm_test/bin/torchrun --nnodes=1 --nproc_per_node="$NPROC" --node_rank=0 \
      --master_addr="$MASTER_ADDR" --master_port="$port" \
      "$TBP" --iters="$ITERS" --warmup="$WARMUP" --seed=42 --mode=host_bound \
      --model=gpt2 --seq=1024 --batch=8 --flush-every="$FLUSH_EVERY" --ckpt-every="$CKPT_EVERY" \
      --io-payload="$IO_PAYLOAD" --io-read-kb="$IO_READ_KB" \
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
        echo "  measure step ${INJECT_START} (${e}s) — start stress_io"
        break
      fi
      if [[ -f "$out/node_0.fail" ]]; then echo "FAIL before inject"; tail -80 "$out/node_0.log"; return 1; fi
      sleep 2; e=$((e + 2))
    done
    if [[ $e -ge 2400 ]]; then echo "step ${INJECT_START} timeout"; return 1; fi

    start_io "$out"
    e=0
    while [[ $e -lt 30 ]]; do
      if grep -q 'SIDECAR_START' "$out/injection.log" 2>/dev/null; then
        echo "  stress_io START ok (${e}s)"; break
      fi
      sleep 1; e=$((e + 1))
    done

    e=0
    while [[ $e -lt 2400 ]]; do
      if [[ -f "$out/ranks/step_${INJECT_STOP}.marker" ]]; then
        echo "  measure step ${INJECT_STOP} → stop io"
        stop_io
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
      stop_io
      wait "$train_pid" || true
      return 0
    fi
    if [[ -f "$out/node_0.fail" ]]; then
      echo "  FAIL"; tail -100 "$out/node_0.log" || true
      stop_io
      wait "$train_pid" || true
      return 1
    fi
    sleep 5; e=$((e + 5))
    if (( e % 30 == 0 )); then
      echo "  waiting… t=${e}s prom=$(ls "$xdump"/*.prom 2>/dev/null | wc -l) ranks=$(ls "$out/ranks"/rank_*.jsonl 2>/dev/null | wc -l)"
    fi
  done
  echo "TIMEOUT"; tail -80 "$out/node_0.log" || true
  stop_io
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
  --case-id P3-EXT-B \
  --case-ref "$CASE_REF" \
  --dose-desc "stress_io fio_nj=${FIO_NJ},iodepth=${FIO_IODEPTH},bs=${FIO_BS},size=${FIO_SIZE},ckpt_every=${CKPT_EVERY},io_read_kb=${IO_READ_KB}; window [${INJECT_START},${INJECT_STOP}]" \
  --accept-min-ratio "$ACCEPT_MIN_RATIO" \
  --out "$DUMP_ROOT/CONTRAST_VERDICT.md" \
  --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json"
vrc=$?
set -e
test -f "$DUMP_ROOT/CONTRAST_VERDICT.md" || { echo "missing VERDICT rc=$vrc"; exit 1; }
echo "CONTRAST_DONE RUN=$RUN DUMP=$DUMP_ROOT verdict_rc=$vrc"
