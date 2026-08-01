#!/usr/bin/env bash
# P3-SW-C contrast: sidecar 8c (stress-ng+leak) + Greyhound collect-min.
# dose=loud (default): cpu_n=nproc,cpu_load=90,mb=1,leak_every=1.0,max_chunks=64；thr=1.3；金标≈2.49/2.33
# dose=quiet:          cpu_n=80,cpu_load=70,mb=1,leak_every=2.0,max_chunks=32；thr=1.15；金标≈1.95（formal `125953`）
# dose=masked:         =quiet lean cpu_n=80,cpu_load=70,mb=1,leak_every=2.0,max_chunks=32；thr=1.05；金标≈1.649（formal `135016`）
# Window [100,300]; mode=host_bound.
# Verdict: collect_seq 真实 per-rank + Rbeast + C0 假阳性对照（不改对手阈值）。
# Hold pod 默认今晚 GH 池 yysong-worker-2（勿用 master / grj）。
# Do NOT inherit hold-job MASTER_ADDR (often yysong-master-0.yysong); force 127.0.0.1.
set -euo pipefail

DOSE="${DOSE:-loud}"
HOLD_POD="${HOLD_POD:-yysong-worker-2}"
SO="${SO:-/data/yinjinrun.p-huawei/probe-bundle/greyhound/libhcclprobe.so}"
STUB="${STUB:-/data/yinjinrun.p-huawei/opt/rbeast-fix/libbuiltin_readcyclecounter.so}"
TBP="${TBP:-/data/yinjinrun.p-huawei/probe-bundle/train_bench_probe_npu.py}"
SIDECAR_PY="${SIDECAR_PY:-/data/yinjinrun.p-huawei/probe-bundle/sidecar_inject_8c.py}"
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
if [[ "$DOSE" == "quiet" ]]; then
  RUN="${RUN:-contrast-p3-sw-c-quiet-${TS}}"
  SIDECAR_8C_CPU_N="${SIDECAR_8C_CPU_N:-80}"
  SIDECAR_8C_CPU_LOAD="${SIDECAR_8C_CPU_LOAD:-70}"
  SIDECAR_8C_MB="${SIDECAR_8C_MB:-1}"
  SIDECAR_8C_LEAK_EVERY="${SIDECAR_8C_LEAK_EVERY:-2.0}"
  SIDECAR_8C_MAX_CHUNKS="${SIDECAR_8C_MAX_CHUNKS:-32}"
  CASE_REF="${CASE_REF:-20260726_125953-yjr-as-c-p3-sw-c-quiet}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}"
  GOLD_STEP_RATIO="${GOLD_STEP_RATIO:-1.95}"
  MASTER_PORT_C0="${MASTER_PORT_C0:-30420}"
  MASTER_PORT_C1="${MASTER_PORT_C1:-30421}"
elif [[ "$DOSE" == "masked" ]]; then
  RUN="${RUN:-contrast-p3-sw-c-masked-${TS}}"
  SIDECAR_8C_CPU_N="${SIDECAR_8C_CPU_N:-80}"
  SIDECAR_8C_CPU_LOAD="${SIDECAR_8C_CPU_LOAD:-70}"
  SIDECAR_8C_MB="${SIDECAR_8C_MB:-1}"
  SIDECAR_8C_LEAK_EVERY="${SIDECAR_8C_LEAK_EVERY:-2.0}"
  SIDECAR_8C_MAX_CHUNKS="${SIDECAR_8C_MAX_CHUNKS:-32}"
  CASE_REF="${CASE_REF:-20260726_135016-yjr-as-c-p3-sw-c-masked}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.05}"
  GOLD_STEP_RATIO="${GOLD_STEP_RATIO:-1.649}"
  MASTER_PORT_C0="${MASTER_PORT_C0:-30422}"
  MASTER_PORT_C1="${MASTER_PORT_C1:-30423}"
else
  RUN="${RUN:-contrast-p3-sw-c-${TS}}"
  # empty SIDECAR_8C_CPU_N → sidecar defaults to nproc
  SIDECAR_8C_CPU_N="${SIDECAR_8C_CPU_N:-}"
  SIDECAR_8C_CPU_LOAD="${SIDECAR_8C_CPU_LOAD:-90}"
  SIDECAR_8C_MB="${SIDECAR_8C_MB:-1}"
  SIDECAR_8C_LEAK_EVERY="${SIDECAR_8C_LEAK_EVERY:-1.0}"
  SIDECAR_8C_MAX_CHUNKS="${SIDECAR_8C_MAX_CHUNKS:-64}"
  CASE_REF="${CASE_REF:-20260725_135238-yjr-as-c-p3-sw-c-loud}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"
  GOLD_STEP_RATIO="${GOLD_STEP_RATIO:-2.49}"
  MASTER_PORT_C0="${MASTER_PORT_C0:-30380}"
  MASTER_PORT_C1="${MASTER_PORT_C1:-30381}"
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
# Hard constraint: single-pod contrast must not inherit yysong-master-0
MASTER_ADDR="${MASTER_ADDR:-127.0.0.1}"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate llm_test
# Ascend/driver：kubectl exec 非 login 时常缺 LD；与 run_s1s2_worker1 / contrast_p1swb 对齐
set +u
for f in \
  /usr/local/Ascend/ascend-toolkit/set_env.sh \
  /usr/local/Ascend/cann-8.5.0/set_env.sh \
  /usr/local/Ascend/nnal/atb/set_env.sh
do
  [[ -f "$f" ]] && source "$f" || true
done
set -u
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
export LD_LIBRARY_PATH="/tmp/stress_bundle:/usr/local/Ascend/cann-8.5.0/aarch64-linux/lib64:/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64:${LD_LIBRARY_PATH:-}"
unset PROBING_TORCH_PROFILING PROBING_GPU INLINE_INJECT 2>/dev/null || true

# Volcano 壳常注入 MASTER_ADDR=yysong-master-0；单 pod 对照强制本机回环
if [[ -z "${MASTER_ADDR:-}" || "$MASTER_ADDR" == *master* || "$MASTER_ADDR" == *yysong-master* ]]; then
  MASTER_ADDR=127.0.0.1
fi

test -f "$SO" || { echo "missing $SO"; exit 2; }
test -f "$STUB" || { echo "missing cyclecounter stub $STUB"; exit 2; }
test -f "$TBP" || { echo "missing $TBP"; exit 2; }
test -f "$SIDECAR_PY" || { echo "missing $SIDECAR_PY"; exit 2; }
if [[ -z "${STRESS_BIN:-}" ]] || ! command -v stress-ng >/dev/null 2>&1; then
  echo "WARN: stress-ng not on PATH (sidecar may fall back to busy workers)"
fi

# only kill OUR leftovers on worker-1
pkill -9 -x stress-ng 2>/dev/null || true
pkill -9 -f '[s]tress-ng' 2>/dev/null || true
pkill -9 -f '[s]idecar_inject_8c' 2>/dev/null || true
pkill -9 -f '[t]bp_npu.py' 2>/dev/null || true
pkill -9 -f '[t]orchrun.*tbp_npu' 2>/dev/null || true
sleep 1

mkdir -p "$DUMP_ROOT" "$CKPT_DIR"

CPU_N_DISP="${SIDECAR_8C_CPU_N:-nproc}"
echo "MASTER_ADDR=$MASTER_ADDR NPROC=$NPROC RUN=$RUN dose=${DOSE} pod=${HOLD_POD}"
echo "dose: cpu_n=${CPU_N_DISP} cpu_load=${SIDECAR_8C_CPU_LOAD} mb=${SIDECAR_8C_MB} leak_every=${SIDECAR_8C_LEAK_EVERY} max_chunks=${SIDECAR_8C_MAX_CHUNKS}"
echo "$RUN" > /tmp/gh_p3swc_run.txt
echo "$DUMP_ROOT" > /tmp/gh_p3swc_dump.txt

# ensure redis
if ! /data/yinjinrun.p-huawei/opt/redis/bin/redis-cli -h 127.0.0.1 -p 16379 ping 2>/dev/null | grep -q PONG; then
  bash /data/yinjinrun.p-huawei/probe-bundle/greyhound/greyhound-src/start_redis.sh || true
fi

cat >"$DUMP_ROOT/manifest.yaml" <<EOF
case_id: P3-SW-C
dose: ${DOSE}
phase: contrast
run_id: $RUN
case_ref: $CASE_REF
world_size: $NPROC
pod: ${HOLD_POD}
pool: pool-gh
mode: host_bound
inject_kind: sidecar_8c
inject_args: "cpu_n=${CPU_N_DISP},cpu_load=${SIDECAR_8C_CPU_LOAD},mb=${SIDECAR_8C_MB},leak_every=${SIDECAR_8C_LEAK_EVERY},max_chunks=${SIDECAR_8C_MAX_CHUNKS}"
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
script: platform/ascend/greyhound/contrast_p3swc.sh
accept_min_ratio: ${ACCEPT_MIN_RATIO}
gold_step_ratio: ${GOLD_STEP_RATIO}
master_addr: ${MASTER_ADDR}
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
  # keep set -u safe: use :- after optional unset
  local cpu_n_opt="${SIDECAR_8C_CPU_N:-}"
  unset SIDECAR_8C_CPU_N 2>/dev/null || true
  export SIDECAR_8C_CPU_LOAD="$SIDECAR_8C_CPU_LOAD"
  export SIDECAR_8C_MB="$SIDECAR_8C_MB"
  export SIDECAR_8C_LEAK_EVERY="$SIDECAR_8C_LEAK_EVERY"
  export SIDECAR_8C_MAX_CHUNKS="$SIDECAR_8C_MAX_CHUNKS"
  if [[ -n "$cpu_n_opt" ]]; then
    export SIDECAR_8C_CPU_N="$cpu_n_opt"
  fi
  # ensure sidecar sees stress-ng
  if [[ -n "${STRESS_BIN:-}" && "$STRESS_BIN" == /tmp/stress_bundle/* ]]; then
    export PATH="/tmp/stress_bundle:${PATH}"
    export LD_LIBRARY_PATH="/tmp/stress_bundle${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  fi
  nohup /root/miniconda3/envs/llm_test/bin/python -u "$SIDECAR_PY" --case 8c --seconds 1800 \
    >"$out/injection.log" 2>&1 &
  echo "SC=$!" | tee -a "$out/injection.log"
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

  unset INLINE_INJECT INLINE_VICTIM_LOCAL_RANK INLINE_INJECT_START INLINE_INJECT_STOP \
        INLINE_GC_EVERY INLINE_GC_STALL_S INLINE_HBM_MB INLINE_HBM_COPIES \
        INLINE_CUBE_SIZE INLINE_CUBE_MM INLINE_8B_MB INLINE_8B_STALL_S 2>/dev/null || true
  stop_8c

  echo "========== $arm port=$port inject=$do_inject 8c cpu_n=${CPU_N_DISP} load=${SIDECAR_8C_CPU_LOAD} =========="
  rm -f "$out/node_0.done" "$out/node_0.fail" "$out/ranks"/step_*.marker "$out/ranks"/warmup_done
  rm -f "$out/ranks"/rank_*.jsonl
  (
    set +e
    LD_PRELOAD="${STUB}:${SO}${LD_PRELOAD:+:$LD_PRELOAD}" \
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
      if [[ -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
        echo "  measure step ${INJECT_START} (${e}s) — start sidecar 8c"
        break
      fi
      if [[ -f "$out/node_0.fail" ]]; then echo "FAIL before inject"; tail -80 "$out/node_0.log"; return 1; fi
      if [[ -f "$out/node_0.done" ]]; then echo "FAIL train ended before inject start"; return 1; fi
      sleep 1; e=$((e + 1))
    done
    if [[ ! -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
      echo "FAIL never reached inject start"; return 1
    fi

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
      sleep 1; e=$((e + 1))
    done
    if [[ $e -ge 60 ]]; then
      echo "  8c sidecar START timeout"; tail -80 "$out/injection.log" || true
      return 1
    fi

    e=0
    while [[ $e -lt 2400 ]]; do
      if [[ -f "$out/ranks/step_${INJECT_STOP}.marker" ]]; then
        echo "  measure step ${INJECT_STOP} → stop 8c (${e}s)"
        stop_8c
        echo "SIDECAR_STOP ts=$(date +%s) held_s=${e}" >>"$out/injection.log"
        break
      fi
      if [[ -f "$out/node_0.done" || -f "$out/node_0.fail" ]]; then
        echo "WARN train ended before inject stop"; break
      fi
      sleep 1; e=$((e + 1))
    done
  fi

  e=0
  while [[ $e -lt 2400 ]]; do
    if [[ -f "$out/node_0.done" ]]; then
      echo "  done (${e}s) dump_lines=$(wc -l <"$GREYHOUND_DUMP" | tr -d ' ')"
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
      echo "  waiting… t=${e}s dump=$(wc -l <"$GREYHOUND_DUMP" 2>/dev/null | tr -d ' ')"
    fi
  done
  echo "TIMEOUT"; tail -80 "$out/node_0.log" || true
  stop_8c
  kill "$train_pid" 2>/dev/null || true
  return 1
}

run_arm C0_baseline "$MASTER_PORT_C0" 0
run_arm C1_inject_none "$MASTER_PORT_C1" 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="/data/yinjinrun.p-huawei/opt/pydeps${PYTHONPATH:+:$PYTHONPATH}"
export GREYHOUND_RBEAST_STUB="${STUB}"
DOSE_DESC="sidecar 8c cpu_n=${CPU_N_DISP} cpu_load=${SIDECAR_8C_CPU_LOAD} mb=${SIDECAR_8C_MB} leak_every=${SIDECAR_8C_LEAK_EVERY} max_chunks=${SIDECAR_8C_MAX_CHUNKS}; window [${INJECT_START},${INJECT_STOP}]; gold≈${GOLD_STEP_RATIO}"
LD_PRELOAD="${STUB}${LD_PRELOAD:+:$LD_PRELOAD}" \
  /root/miniconda3/envs/llm_test/bin/python3 "$SCRIPT_DIR/s4_verdict.py" \
  --dump-root "$DUMP_ROOT" \
  --inject-start "$INJECT_START" \
  --inject-stop "$INJECT_STOP" \
  --accept-min-ratio "$ACCEPT_MIN_RATIO" \
  --case-id P3-SW-C \
  --case-ref "$CASE_REF" \
  --dose-desc "$DOSE_DESC" \
  --dose "$DOSE" \
  --tool greyhound \
  --run-id "$RUN" \
  --pod "$HOLD_POD" \
  --out "$DUMP_ROOT/CONTRAST_VERDICT.md" \
  --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json"
echo "CONTRAST_DONE RUN=$RUN DUMP=$DUMP_ROOT"
