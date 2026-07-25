#!/usr/bin/env bash
# P3-EXT-C Loud contrast on yysong-worker-1: stress_vm + Greyhound collect-min.
# Frozen dose (dose_recipes calibrated):
#   vm_n=96,vm_bytes=6G
# Window [100,300]; mode=host_bound.
# Verdict: collect_seq 真实 per-rank + Rbeast + C0 假阳性对照（不改对手阈值）。
# Do NOT inherit hold-job MASTER_ADDR (often yysong-master-0.yysong).
set -euo pipefail

SO="${SO:-/data/yinjinrun.p-huawei/probe-bundle/greyhound/libhcclprobe.so}"
STUB="${STUB:-/data/yinjinrun.p-huawei/opt/rbeast-fix/libbuiltin_readcyclecounter.so}"
TBP="${TBP:-/data/yinjinrun.p-huawei/probe-bundle/train_bench_probe_npu.py}"
STRESS="${STRESS:-/tmp/stress_bundle/stress-ng}"
TS="$(date +%Y%m%d_%H%M%S)"
RUN="${RUN:-contrast-p3-ext-c-${TS}}"
DUMP_ROOT="${DUMP_ROOT:-/data/yinjinrun.p-huawei/results/ascend-ais/baseline/greyhound/$RUN}"
NPROC="${NPROC:-16}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
INJECT_START="${INJECT_START:-100}"
INJECT_STOP="${INJECT_STOP:-300}"
VM_N="${VM_N:-96}"
VM_BYTES="${VM_BYTES:-6G}"
VICTIM_LOCAL="${VICTIM_LOCAL:-7}"
MASTER_PORT_C0="${MASTER_PORT_C0:-30350}"
MASTER_PORT_C1="${MASTER_PORT_C1:-30351}"
MASTER_ADDR="${MASTER_ADDR:-}"
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
export LD_LIBRARY_PATH="/tmp/stress_bundle:/usr/local/Ascend/cann-8.5.0/aarch64-linux/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
unset PROBING_TORCH_PROFILING PROBING_GPU INLINE_INJECT 2>/dev/null || true

# Volcano 壳常注入 MASTER_ADDR=yysong-master-0；单 pod 对照必须用本机 eth0
if [[ -z "${MASTER_ADDR:-}" || "$MASTER_ADDR" == *master* || "$MASTER_ADDR" == *yysong-master* ]]; then
  MASTER_ADDR=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
  MASTER_ADDR=${MASTER_ADDR:-127.0.0.1}
fi

chmod +x "$STRESS" 2>/dev/null || true
test -f "$SO" || { echo "missing $SO"; exit 2; }
test -f "$STUB" || { echo "missing cyclecounter stub $STUB"; exit 2; }
test -f "$TBP" || { echo "missing $TBP"; exit 2; }
test -x "$STRESS" || { echo "missing stress-ng at $STRESS"; exit 2; }

# only kill OUR leftovers on worker-1
pkill -9 -x stress-ng 2>/dev/null || true
pkill -9 -f '[s]tress-ng' 2>/dev/null || true
pkill -9 -f '[t]bp_npu.py' 2>/dev/null || true
pkill -9 -f '[t]orchrun.*tbp_npu' 2>/dev/null || true
sleep 1

mkdir -p "$DUMP_ROOT" "$CKPT_DIR"

echo "MASTER_ADDR=$MASTER_ADDR NPROC=$NPROC RUN=$RUN vm_n=${VM_N} vm_bytes=${VM_BYTES}"
echo "$RUN" > /tmp/gh_p3extc_run.txt
echo "$DUMP_ROOT" > /tmp/gh_p3extc_dump.txt

# ensure redis
if ! /data/yinjinrun.p-huawei/opt/redis/bin/redis-cli -h 127.0.0.1 -p 16379 ping 2>/dev/null | grep -q PONG; then
  bash /data/yinjinrun.p-huawei/probe-bundle/greyhound/greyhound-src/start_redis.sh || true
fi

cat >"$DUMP_ROOT/manifest.yaml" <<EOF
case_id: P3-EXT-C
dose: loud
phase: contrast
run_id: $RUN
case_ref: $CASE_REF
world_size: $NPROC
pod: yysong-worker-1
pool: pool-gh
mode: host_bound
inject_kind: stress_vm
inject_args: "vm_n=${VM_N},vm_bytes=${VM_BYTES}"
inject_window_measure: [${INJECT_START}, ${INJECT_STOP}]
victim_local_rank: ${VICTIM_LOCAL}
host_bound_matmul: 768
seed: 42
iters: $ITERS
warmup: $WARMUP
tool: Greyhound
label_prefix: yjr-as-b-gh
preload: ${STUB}:${SO}
redis: 127.0.0.1:16379
fairness: collect_seq_real_per_rank + C0_fp_control
script: platform/ascend/greyhound/contrast_p3extc.sh
accept_min_ratio: ${ACCEPT_MIN_RATIO}
vm_prestart: warmup_done
vm_prestart_note: "page-in ramp before measure window; dose args unchanged"
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
  nohup env LD_LIBRARY_PATH=/tmp/stress_bundle "$STRESS" \
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
  mkdir -p "$out/ranks" "$out/greyhound"
  export GREYHOUND_DUMP="$out/greyhound/hcclprobe.collect.jsonl"
  export GREYHOUND_STUB_MARKER="$out/greyhound/hcclprobe.loaded"
  export GREYHOUND_DEBUG=1
  export GREYHOUND_HCCL_SO=/usr/local/Ascend/cann-8.5.0/aarch64-linux/lib64/libhccl.so
  : >"$GREYHOUND_DUMP"

  stop_vm
  echo "========== $arm port=$port inject=$do_inject vm_n=${VM_N} vm_bytes=${VM_BYTES} =========="
  rm -f "$out/node_0.done" "$out/node_0.fail" "$out/ranks"/step_*.marker "$out/ranks"/warmup_done
  rm -f "$out/ranks"/rank_*.jsonl
  (
    LD_PRELOAD="${STUB}:${SO}${LD_PRELOAD:+:$LD_PRELOAD}" \
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
    if [[ -f "$out/ranks/warmup_done" || -f "$out/ranks/step_1.marker" || -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
      echo "  warmup ok (${e}s)"; break
    fi
    if [[ -f "$out/node_0.fail" ]]; then echo "FAIL warmup"; tail -80 "$out/node_0.log"; return 1; fi
    if [[ -f "$out/node_0.done" ]]; then echo "  train finished during warmup wait"; break; fi
    sleep 1; e=$((e + 1))
  done
  if [[ ! -f "$out/ranks/warmup_done" && ! -f "$out/ranks/step_1.marker" && ! -f "$out/ranks/step_${INJECT_START}.marker" && ! -f "$out/node_0.done" ]]; then
    echo "FAIL warmup timeout"; tail -80 "$out/node_0.log"; return 1
  fi

  if [[ "$do_inject" == "1" ]]; then
    # Pre-start at warmup so --page-in can ramp before measure window [100,300].
    # Frozen dose args unchanged (vm_n×vm_bytes); only start timing for allocation.
    echo "  warmup reached — prestart stress_vm for page-in ramp"
    start_vm "$out"
    e=0
    while [[ $e -lt 30 ]]; do
      if grep -q 'SIDECAR_START' "$out/injection.log" 2>/dev/null; then
        echo "  stress_vm PRESTART ok (${e}s)"
        break
      fi
      sleep 1; e=$((e + 1))
    done
    # Wait until used mem climbs (≥150Gi over baseline) or 90s, whichever first.
    local mem0 mem_now delta
    mem0=$(awk '/^Mem:/{print $3}' <(free -b) 2>/dev/null || echo 0)
    e=0
    while [[ $e -lt 90 ]]; do
      mem_now=$(awk '/^Mem:/{print $3}' <(free -b) 2>/dev/null || echo 0)
      delta=$(( (mem_now - mem0) / 1024 / 1024 / 1024 ))
      if [[ $delta -ge 150 ]]; then
        echo "  page-in ramp ok used+${delta}Gi (${e}s)"
        echo "PAGEIN_RAMP_OK used_delta_gi=${delta} t=${e}" >>"$out/injection.log"
        break
      fi
      if [[ -f "$out/ranks/step_${INJECT_START}.marker" && $e -ge 30 ]]; then
        echo "  page-in partial used+${delta}Gi at step${INJECT_START} (${e}s) — continue"
        echo "PAGEIN_PARTIAL used_delta_gi=${delta} t=${e}" >>"$out/injection.log"
        break
      fi
      sleep 2; e=$((e + 2))
    done
    if [[ $e -ge 90 ]]; then
      mem_now=$(awk '/^Mem:/{print $3}' <(free -b) 2>/dev/null || echo 0)
      delta=$(( (mem_now - mem0) / 1024 / 1024 / 1024 ))
      echo "  page-in wait timeout used+${delta}Gi — continue"
      echo "PAGEIN_TIMEOUT used_delta_gi=${delta} t=${e}" >>"$out/injection.log"
    fi

    e=0
    while [[ $e -lt 2400 ]]; do
      if [[ -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
        echo "  measure step ${INJECT_START} (${e}s) — stress_vm already active"
        free -h | head -3 | tee -a "$out/injection.log" || true
        break
      fi
      if [[ -f "$out/node_0.fail" ]]; then echo "FAIL before inject"; tail -80 "$out/node_0.log"; return 1; fi
      if [[ -f "$out/node_0.done" ]]; then echo "FAIL train ended before inject start"; return 1; fi
      if ! pgrep -x stress-ng >/dev/null && ! pgrep -f '[s]tress-ng' >/dev/null; then
        echo "FAIL stress-ng died during ramp"; cat "$out/injection.log"; return 1
      fi
      sleep 1; e=$((e + 1))
    done
    if [[ ! -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
      echo "FAIL never reached inject start"; return 1
    fi

    e=0
    while [[ $e -lt 2400 ]]; do
      if [[ -f "$out/ranks/step_${INJECT_STOP}.marker" ]]; then
        echo "  measure step ${INJECT_STOP} → stop vm (${e}s)"
        free -h | head -3 | tee -a "$out/injection.log" || true
        stop_vm
        echo "SIDECAR_STOP ts=$(date +%s) held_s=${e}" >>"$out/injection.log"
        break
      fi
      if [[ -f "$out/node_0.done" || -f "$out/node_0.fail" ]]; then
        echo "WARN train ended before inject stop"; break
      fi
      if [[ $e -ge 2 ]]; then
        if ! pgrep -x stress-ng >/dev/null && ! pgrep -f '[s]tress-ng' >/dev/null; then
          echo "FAIL stress-ng died early"; cat "$out/injection.log"; return 1
        fi
      fi
      sleep 1; e=$((e + 1))
    done
  fi

  e=0
  while [[ $e -lt 2400 ]]; do
    if [[ -f "$out/node_0.done" ]]; then
      echo "  done (${e}s) dump_lines=$(wc -l <"$GREYHOUND_DUMP" | tr -d ' ')"
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
      echo "  waiting… t=${e}s dump=$(wc -l <"$GREYHOUND_DUMP" 2>/dev/null | tr -d ' ')"
    fi
  done
  echo "TIMEOUT"; tail -80 "$out/node_0.log" || true
  stop_vm
  kill "$train_pid" 2>/dev/null || true
  return 1
}

run_arm C0_baseline "$MASTER_PORT_C0" 0
run_arm C1_inject_none "$MASTER_PORT_C1" 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="/data/yinjinrun.p-huawei/opt/pydeps${PYTHONPATH:+:$PYTHONPATH}"
export GREYHOUND_RBEAST_STUB="${STUB}"
DOSE_DESC="stress_vm vm_n=${VM_N},vm_bytes=${VM_BYTES}; window [${INJECT_START},${INJECT_STOP}]"
LD_PRELOAD="${STUB}${LD_PRELOAD:+:$LD_PRELOAD}" \
  /root/miniconda3/envs/llm_test/bin/python3 "$SCRIPT_DIR/s4_verdict.py" \
  --dump-root "$DUMP_ROOT" \
  --inject-start "$INJECT_START" \
  --inject-stop "$INJECT_STOP" \
  --accept-min-ratio "$ACCEPT_MIN_RATIO" \
  --case-id P3-EXT-C \
  --case-ref "$CASE_REF" \
  --dose-desc "$DOSE_DESC" \
  --tool greyhound \
  --run-id "$RUN" \
  --pod yysong-worker-1 \
  --out "$DUMP_ROOT/CONTRAST_VERDICT.md" \
  --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json"
echo "CONTRAST_DONE RUN=$RUN DUMP=$DUMP_ROOT"
