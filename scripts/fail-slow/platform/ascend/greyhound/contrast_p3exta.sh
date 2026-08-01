#!/usr/bin/env bash
# P3-EXT-A contrast: stress_cpu sidecar + Greyhound collect-min.
# dose=loud (default): cpu_n=nproc,cpu_load=90；thr=1.3；金标≈1.97
# dose=quiet:          cpu_n=128,cpu_load=70（cpu_frac=0.5）；thr=1.15；金标≈1.256
# dose=masked:         cpu_n=128,cpu_load=70（=quiet lean；formal `094648`）；thr=1.05；金标≈1.470
# Window [100,300]; mode=host_bound; victim local_rank=7.
# LD_PRELOAD = cyclecounter stub : libhcclprobe.so
# Verdict: collect_seq 真实 per-rank + Rbeast + C0 假阳性对照（不改对手阈值）。
# Hold pod 默认今晚 GH 池 yysong-worker-2（勿用 master / grj）。
set -euo pipefail

DOSE="${DOSE:-loud}"
HOLD_POD="${HOLD_POD:-yysong-worker-2}"
SO="${SO:-/data/yinjinrun.p-huawei/probe-bundle/greyhound/libhcclprobe.so}"
STUB="${STUB:-/data/yinjinrun.p-huawei/opt/rbeast-fix/libbuiltin_readcyclecounter.so}"
TBP="${TBP:-/data/yinjinrun.p-huawei/probe-bundle/train_bench_probe_npu.py}"
STRESS="${STRESS:-/tmp/stress_bundle/stress-ng}"
TS="$(date +%Y%m%d_%H%M%S)"
if [[ "$DOSE" == "quiet" ]]; then
  RUN="${RUN:-contrast-p3-ext-a-quiet-${TS}}"
  CPU_N="${CPU_N:-128}"
  CPU_LOAD="${CPU_LOAD:-70}"
  CASE_REF="${CASE_REF:-20260726_075912-yjr-as-c-p3-ext-a-quiet}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}"
  GOLD_STEP_RATIO="${GOLD_STEP_RATIO:-1.256}"
  MASTER_PORT_C0="${MASTER_PORT_C0:-30390}"
  MASTER_PORT_C1="${MASTER_PORT_C1:-30391}"
elif [[ "$DOSE" == "masked" ]]; then
  RUN="${RUN:-contrast-p3-ext-a-masked-${TS}}"
  CPU_N="${CPU_N:-128}"
  CPU_LOAD="${CPU_LOAD:-70}"
  CASE_REF="${CASE_REF:-20260726_094648-yjr-as-c-p3-ext-a-masked}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.05}"
  GOLD_STEP_RATIO="${GOLD_STEP_RATIO:-1.470}"
  MASTER_PORT_C0="${MASTER_PORT_C0:-30392}"
  MASTER_PORT_C1="${MASTER_PORT_C1:-30393}"
else
  RUN="${RUN:-contrast-p3-ext-a-${TS}}"
  CPU_N="${CPU_N:-}"
  CPU_LOAD="${CPU_LOAD:-90}"
  CASE_REF="${CASE_REF:-20260724_231918-yjr-as-c-p3exta-loud}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"
  GOLD_STEP_RATIO="${GOLD_STEP_RATIO:-1.97}"
  MASTER_PORT_C0="${MASTER_PORT_C0:-30310}"
  MASTER_PORT_C1="${MASTER_PORT_C1:-30311}"
fi
# Prefer AFS results when writable (hold pod may lack /data write); fallback /data
if [[ -z "${DUMP_ROOT:-}" ]]; then
  if [[ -d /afs-a3-weight-share/yinjinrun.p-huawei/results/ascend-ais ]]; then
    DUMP_ROOT="/afs-a3-weight-share/yinjinrun.p-huawei/results/ascend-ais/baseline/greyhound/$RUN"
  else
    DUMP_ROOT="/data/yinjinrun.p-huawei/results/ascend-ais/baseline/greyhound/$RUN"
  fi
fi
NPROC="${NPROC:-16}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
INJECT_START="${INJECT_START:-100}"
INJECT_STOP="${INJECT_STOP:-300}"
VICTIM_LOCAL="${VICTIM_LOCAL:-7}"
MASTER_ADDR="${MASTER_ADDR:-}"

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

# Volcano 壳常注入 MASTER_ADDR=yysong-master-0；单 pod 对照必须用本机 / 127.0.0.1
if [[ -z "${MASTER_ADDR:-}" || "$MASTER_ADDR" == *master* || "$MASTER_ADDR" == *yysong-master* ]]; then
  MASTER_ADDR=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
  if [[ -z "$MASTER_ADDR" ]]; then
    MASTER_ADDR=$(python3 -c 'import socket; print(socket.gethostbyname(socket.gethostname()))' 2>/dev/null || true)
  fi
  MASTER_ADDR=${MASTER_ADDR:-127.0.0.1}
fi
# 硬约束：Loop 要求 MASTER_ADDR=127.0.0.1（单机 16 卡）
MASTER_ADDR="${FORCE_MASTER_ADDR:-127.0.0.1}"

# resolve CPU_N=nproc for loud default
if [[ -z "${CPU_N}" ]]; then
  CPU_N="$(nproc)"
fi
CPU_N_DESC="${CPU_N}"

chmod +x "$STRESS" 2>/dev/null || true
# fallback stress-ng locations
if [[ ! -x "$STRESS" ]]; then
  for c in /usr/bin/stress-ng /bin/stress-ng "$(command -v stress-ng 2>/dev/null || true)"; do
    if [[ -n "$c" && -x "$c" ]]; then STRESS="$c"; break; fi
  done
fi
test -f "$SO" || { echo "missing $SO"; exit 2; }
test -f "$STUB" || { echo "missing cyclecounter stub $STUB"; exit 2; }
test -f "$TBP" || { echo "missing $TBP"; exit 2; }
test -x "$STRESS" || { echo "missing stress-ng at $STRESS"; exit 2; }

# only kill OUR leftovers on this hold pod
pkill -9 -x stress-ng 2>/dev/null || true
pkill -9 -f '[s]tress-ng' 2>/dev/null || true
pkill -9 -f '[t]bp_npu.py' 2>/dev/null || true
pkill -9 -f '[t]orchrun.*tbp_npu' 2>/dev/null || true
pkill -9 -f '[t]rain_bench_probe_npu' 2>/dev/null || true
sleep 1

mkdir -p "$DUMP_ROOT" "$CKPT_DIR"

echo "MASTER_ADDR=$MASTER_ADDR NPROC=$NPROC RUN=$RUN dose=${DOSE} pod=${HOLD_POD} cpu_n=${CPU_N} cpu_load=${CPU_LOAD}"
echo "$RUN" > /tmp/gh_p3exta_run.txt
echo "$DUMP_ROOT" > /tmp/gh_p3exta_dump.txt

# ensure redis
if ! /data/yinjinrun.p-huawei/opt/redis/bin/redis-cli -h 127.0.0.1 -p 16379 ping 2>/dev/null | grep -q PONG; then
  bash /data/yinjinrun.p-huawei/probe-bundle/greyhound/greyhound-src/start_redis.sh || true
fi

cat >"$DUMP_ROOT/manifest.yaml" <<EOF
case_id: P3-EXT-A
dose: ${DOSE}
phase: contrast
run_id: $RUN
case_ref: $CASE_REF
world_size: $NPROC
pod: ${HOLD_POD}
pool: pool-gh
mode: host_bound
inject_kind: stress_cpu
inject_args: "cpu_n=${CPU_N},cpu_load=${CPU_LOAD}"
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
script: platform/ascend/greyhound/contrast_p3exta.sh
accept_min_ratio: ${ACCEPT_MIN_RATIO}
gold_step_ratio: ${GOLD_STEP_RATIO}
master_addr: ${MASTER_ADDR}
EOF

run_arm() {
  local arm="$1" port="$2" do_inject="$3"
  local out="$DUMP_ROOT/$arm"
  mkdir -p "$out/ranks" "$out/greyhound"
  export GREYHOUND_DUMP="$out/greyhound/hcclprobe.collect.jsonl"
  export GREYHOUND_STUB_MARKER="$out/greyhound/hcclprobe.loaded"
  export GREYHOUND_DEBUG=1
  export GREYHOUND_HCCL_SO=/usr/local/Ascend/cann-8.5.0/aarch64-linux/lib64/libhccl.so
  : >"$GREYHOUND_DUMP"

  echo "========== $arm port=$port inject=$do_inject stress_cpu cpu_n=${CPU_N} cpu_load=${CPU_LOAD} =========="
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
    e=0
    while [[ $e -lt 2400 ]]; do
      if [[ -f "$out/ranks/step_${INJECT_STOP}.marker" ]]; then
        echo "FAIL inject window already past step ${INJECT_STOP} before start"; return 1
      fi
      if [[ -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
        echo "  measure step ${INJECT_START} (${e}s) → start stress-ng"
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
    : >"$out/injection.log"
    nohup env LD_LIBRARY_PATH=/tmp/stress_bundle:${LD_LIBRARY_PATH:-} \
      "$STRESS" --cpu "$CPU_N" --cpu-load "$CPU_LOAD" --timeout 900s \
      >>"$out/injection.log" 2>&1 &
    echo "SC=$!" | tee -a "$out/injection.log"
    echo "SIDECAR_START stress_cpu cpu_n=${CPU_N} cpu_load=${CPU_LOAD} ts=$(date +%s)" >>"$out/injection.log"
    e=0
    while [[ $e -lt 2400 ]]; do
      if [[ -f "$out/ranks/step_${INJECT_STOP}.marker" ]]; then
        echo "  measure step ${INJECT_STOP} → stop stress (${e}s)"
        pkill -TERM -x stress-ng 2>/dev/null || true
        sleep 1
        pkill -9 -x stress-ng 2>/dev/null || true
        echo "SIDECAR_STOP ts=$(date +%s) held_s=${e}" >>"$out/injection.log"
        break
      fi
      if [[ -f "$out/node_0.done" || -f "$out/node_0.fail" ]]; then
        echo "WARN train ended before inject stop"; break
      fi
      if [[ $e -ge 2 ]] && ! pgrep -x stress-ng >/dev/null; then
        echo "FAIL stress-ng died early"; cat "$out/injection.log"; return 1
      fi
      sleep 1; e=$((e + 1))
    done
  fi

  e=0
  while [[ $e -lt 2400 ]]; do
    if [[ -f "$out/node_0.done" ]]; then
      echo "  done (${e}s) dump_lines=$(wc -l <"$GREYHOUND_DUMP" | tr -d ' ')"
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
      echo "  waiting… t=${e}s dump=$(wc -l <"$GREYHOUND_DUMP" 2>/dev/null | tr -d ' ')"
    fi
  done
  echo "TIMEOUT"; tail -80 "$out/node_0.log" || true
  pkill -9 -x stress-ng 2>/dev/null || true
  kill "$train_pid" 2>/dev/null || true
  return 1
}

run_arm C0_baseline "$MASTER_PORT_C0" 0
run_arm C1_inject_none "$MASTER_PORT_C1" 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="/data/yinjinrun.p-huawei/opt/pydeps${PYTHONPATH:+:$PYTHONPATH}"
export GREYHOUND_RBEAST_STUB="${STUB}"
DOSE_DESC="stress_cpu cpu_n=${CPU_N} cpu_load=${CPU_LOAD} victim=${VICTIM_LOCAL}; window [${INJECT_START},${INJECT_STOP}]; gold≈${GOLD_STEP_RATIO}"
LD_PRELOAD="${STUB}${LD_PRELOAD:+:$LD_PRELOAD}" \
  /root/miniconda3/envs/llm_test/bin/python3 "$SCRIPT_DIR/s4_verdict.py" \
  --dump-root "$DUMP_ROOT" \
  --inject-start "$INJECT_START" \
  --inject-stop "$INJECT_STOP" \
  --accept-min-ratio "$ACCEPT_MIN_RATIO" \
  --case-id P3-EXT-A \
  --case-ref "$CASE_REF" \
  --dose-desc "$DOSE_DESC" \
  --dose "$DOSE" \
  --tool greyhound \
  --run-id "$RUN" \
  --pod "$HOLD_POD" \
  --out "$DUMP_ROOT/CONTRAST_VERDICT.md" \
  --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json"
echo "CONTRAST_DONE RUN=$RUN DUMP=$DUMP_ROOT"
