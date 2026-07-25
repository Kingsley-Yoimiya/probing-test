#!/usr/bin/env bash
# P2-SW-C Loud contrast on yysong-worker-1: topo_5c (device_rev + EXTRA_AR) + Greyhound collect-min.
# Frozen dose (dose_recipes calibrated):
#   device_rev=1,topo_extra_ar=512,topo_ar_elems=262144
# C1 only: reverse ASCEND_VISIBLE_DEVICES + TOPO_EXTRA_AR/TOPO_AR_ELEMS.
# Main evidence = comm_ms (Probing gold C1/C0_comm≈49.86; step≈5.06).
# Verdict: collect_seq 真实 per-rank + Rbeast + C0 假阳性对照（不改对手阈值）。
# Do NOT inherit hold-job MASTER_ADDR (often yysong-master-0.yysong).
set -euo pipefail

SO="${SO:-/data/yinjinrun.p-huawei/probe-bundle/greyhound/libhcclprobe.so}"
STUB="${STUB:-/data/yinjinrun.p-huawei/opt/rbeast-fix/libbuiltin_readcyclecounter.so}"
TBP="${TBP:-/data/yinjinrun.p-huawei/probe-bundle/train_bench_probe_npu.py}"
TS="$(date +%Y%m%d_%H%M%S)"
RUN="${RUN:-contrast-p2-sw-c-${TS}}"
DUMP_ROOT="${DUMP_ROOT:-/data/yinjinrun.p-huawei/results/ascend-ais/baseline/greyhound/$RUN}"
NPROC="${NPROC:-16}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
INJECT_START="${INJECT_START:-100}"
INJECT_STOP="${INJECT_STOP:-300}"
DOSE_DEVICE_REV="${TOPO_DEVICE_REV:-1}"
DOSE_EXTRA_AR="${TOPO_EXTRA_AR:-512}"
DOSE_AR_ELEMS="${TOPO_AR_ELEMS:-262144}"
MASTER_PORT_C0="${MASTER_PORT_C0:-30410}"
MASTER_PORT_C1="${MASTER_PORT_C1:-30411}"
# 单 pod 对照：强制本机环回，禁止继承 hold-job MASTER_ADDR=yysong-master-0
MASTER_ADDR="${MASTER_ADDR:-127.0.0.1}"
CASE_REF="${CASE_REF:-20260725_124102-yjr-as-c-p2-sw-c-loud}"
ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate llm_test
# Ascend/driver：kubectl exec 非 login 时常缺 LD；与 run_s1s2_worker1 对齐
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
export GLOO_SOCKET_IFNAME=${GLOO_SOCKET_IFNAME:-eth0}
export HCCL_CONNECT_TIMEOUT=${HCCL_CONNECT_TIMEOUT:-1800}
export HOST_BOUND_MATMUL=${HOST_BOUND_MATMUL:-768}
export CKPT_DIR="${CKPT_DIR:-/data/yinjinrun.p-huawei/probe-bundle/ckpt}"
export PROBING=0
export LD_LIBRARY_PATH="/tmp/stress_bundle:/usr/local/Ascend/cann-8.5.0/aarch64-linux/lib64:/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64:${LD_LIBRARY_PATH:-}"
unset PROBING_TORCH_PROFILING PROBING_GPU INLINE_INJECT 2>/dev/null || true

# 若外部误传 master DNS，强制改回本机
if [[ "$MASTER_ADDR" == *master* || "$MASTER_ADDR" == *yysong-master* ]]; then
  MASTER_ADDR=127.0.0.1
fi

test -f "$SO" || { echo "missing $SO"; exit 2; }
test -f "$STUB" || { echo "missing cyclecounter stub $STUB"; exit 2; }
test -f "$TBP" || { echo "missing $TBP"; exit 2; }
# Ensure tbp has TOPO_EXTRA_AR (probe-bundle may lag shared scripts)
if ! grep -q 'TOPO_EXTRA_AR' "$TBP"; then
  echo "WARN: $TBP missing TOPO_EXTRA_AR; sync from /tmp/tbp_npu.py if present"
  if [[ -f /tmp/tbp_npu.py ]] && grep -q 'TOPO_EXTRA_AR' /tmp/tbp_npu.py; then
    TBP=/tmp/tbp_npu.py
    echo "using TBP=$TBP"
  else
    echo "FAIL: no TOPO_EXTRA_AR in train script"; exit 3
  fi
fi

# only kill OUR leftovers on worker-1
pkill -9 -x stress-ng 2>/dev/null || true
pkill -9 -f '[t]bp_npu.py' 2>/dev/null || true
pkill -9 -f '[t]orchrun.*tbp_npu' 2>/dev/null || true
sleep 1

mkdir -p "$DUMP_ROOT" "$CKPT_DIR"

echo "MASTER_ADDR=$MASTER_ADDR NPROC=$NPROC RUN=$RUN device_rev=${DOSE_DEVICE_REV} extra_ar=${DOSE_EXTRA_AR} ar_elems=${DOSE_AR_ELEMS}"
echo "$RUN" > /tmp/gh_p2swc_run.txt
echo "$DUMP_ROOT" > /tmp/gh_p2swc_dump.txt

# ensure redis
if ! /data/yinjinrun.p-huawei/opt/redis/bin/redis-cli -h 127.0.0.1 -p 16379 ping 2>/dev/null | grep -q PONG; then
  bash /data/yinjinrun.p-huawei/probe-bundle/greyhound/greyhound-src/start_redis.sh || true
fi

cat >"$DUMP_ROOT/manifest.yaml" <<EOF
case_id: P2-SW-C
dose: loud
phase: contrast
run_id: $RUN
case_ref: $CASE_REF
world_size: $NPROC
pod: yysong-worker-1
pool: pool-gh
mode: gpu_bound
inject_kind: topo_5c
inject_args: "device_rev=${DOSE_DEVICE_REV},topo_extra_ar=${DOSE_EXTRA_AR},topo_ar_elems=${DOSE_AR_ELEMS}"
inject_window_measure: [${INJECT_START}, ${INJECT_STOP}]
host_bound_matmul: 768
seed: 42
iters: $ITERS
warmup: $WARMUP
tool: Greyhound
label_prefix: yjr-as-b-gh
preload: ${STUB}:${SO}
redis: 127.0.0.1:16379
fairness: collect_seq_real_per_rank + C0_fp_control
script: platform/ascend/greyhound/contrast_p2swc.sh
accept_min_ratio: ${ACCEPT_MIN_RATIO}
dose_note: "主证 comm_ms（金标 C1/C0_comm≈49.86）；step≈5.06 旁证；dose_check 优先 comm"
EOF

_reverse_ascend_visible() {
  local avd="${ASCEND_VISIBLE_DEVICES:-0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}"
  if command -v tac >/dev/null 2>&1; then
    echo "$avd" | tr ',' '\n' | tac | paste -sd, -
  else
    echo "$avd" | tr ',' '\n' | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) printf "%s%s", a[i], (i>1?",":"")}'
  fi
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
        INLINE_2A_CHUNKS INLINE_2A_STALL_MB INLINE_2A_STALL_S INLINE_HBM_MB INLINE_HBM_COPIES \
        INLINE_CUBE_SIZE INLINE_CUBE_MM INLINE_GC_EVERY INLINE_GC_STALL_S \
        RARE_SHAPE_SEQ RARE_SHAPE_EVERY RARE_SHAPE_FRAC \
        HCCL_ALGO HCCL_BUFFSIZE HCCL_STRESS_MB \
        TOPO_EXTRA_AR TOPO_AR_ELEMS 2>/dev/null || true
  # Restore clean visible list for C0; C1 may reverse.
  export ASCEND_VISIBLE_DEVICES="${BASE_ASCEND_VISIBLE:-0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}"

  if [[ "$do_inject" == "1" ]]; then
    export TOPO_EXTRA_AR="$DOSE_EXTRA_AR"
    export TOPO_AR_ELEMS="$DOSE_AR_ELEMS"
    if [[ "$DOSE_DEVICE_REV" == "1" ]]; then
      export ASCEND_VISIBLE_DEVICES="$(_reverse_ascend_visible)"
    fi
  fi

  echo "========== $arm port=$port inject=$do_inject device_rev=${DOSE_DEVICE_REV} extra_ar=${DOSE_EXTRA_AR} ar_elems=${DOSE_AR_ELEMS} ASCEND_VISIBLE=${ASCEND_VISIBLE_DEVICES} =========="
  rm -f "$out/node_0.done" "$out/node_0.fail" "$out/ranks"/step_*.marker "$out/ranks"/warmup_done
  rm -f "$out/ranks"/rank_*.jsonl
  (
    LD_PRELOAD="${STUB}:${SO}${LD_PRELOAD:+:$LD_PRELOAD}" \
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
    while [[ $e -lt 3600 ]]; do
      if [[ -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
        echo "  measure step ${INJECT_START} (${e}s) — topo_5c active from process start"
        break
      fi
      if [[ -f "$out/node_0.fail" ]]; then echo "FAIL before inject"; tail -80 "$out/node_0.log"; return 1; fi
      if [[ -f "$out/node_0.done" ]]; then echo "FAIL train ended before inject start"; return 1; fi
      sleep 2; e=$((e + 2))
    done
    if [[ ! -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
      echo "FAIL never reached inject start"; return 1
    fi
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
  # C1 with EXTRA_AR=512 can be much slower than C0
  while [[ $e -lt 7200 ]]; do
    if [[ -f "$out/node_0.done" ]]; then
      echo "  done (${e}s) dump_lines=$(wc -l <"$GREYHOUND_DUMP" | tr -d ' ')"
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
      echo "  waiting… t=${e}s dump=$(wc -l <"$GREYHOUND_DUMP" 2>/dev/null | tr -d ' ') ranks=$(ls "$out/ranks"/rank_*.jsonl 2>/dev/null | wc -l)"
    fi
  done
  echo "TIMEOUT"; tail -80 "$out/node_0.log" || true
  kill "$train_pid" 2>/dev/null || true
  return 1
}

BASE_ASCEND_VISIBLE="${ASCEND_VISIBLE_DEVICES:-0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}"
export BASE_ASCEND_VISIBLE

run_arm C0_baseline "$MASTER_PORT_C0" 0
run_arm C1_inject_none "$MASTER_PORT_C1" 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="/data/yinjinrun.p-huawei/opt/pydeps${PYTHONPATH:+:$PYTHONPATH}"
export GREYHOUND_RBEAST_STUB="${STUB}"
DOSE_DESC="topo_5c device_rev=${DOSE_DEVICE_REV} topo_extra_ar=${DOSE_EXTRA_AR} topo_ar_elems=${DOSE_AR_ELEMS}; window [${INJECT_START},${INJECT_STOP}]"
LD_PRELOAD="${STUB}${LD_PRELOAD:+:$LD_PRELOAD}" \
  /root/miniconda3/envs/llm_test/bin/python3 "$SCRIPT_DIR/s4_verdict.py" \
  --dump-root "$DUMP_ROOT" \
  --inject-start "$INJECT_START" \
  --inject-stop "$INJECT_STOP" \
  --accept-min-ratio "$ACCEPT_MIN_RATIO" \
  --case-id P2-SW-C \
  --case-ref "$CASE_REF" \
  --dose-desc "$DOSE_DESC" \
  --tool greyhound \
  --run-id "$RUN" \
  --pod yysong-worker-1 \
  --out "$DUMP_ROOT/CONTRAST_VERDICT.md" \
  --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json"

# Primary dose_check = comm_ms
COMM_PY="${COMM_PY:-$SCRIPT_DIR/dose_check_comm_p2swc.py}"
if [[ -f "$COMM_PY" ]]; then
  /root/miniconda3/envs/llm_test/bin/python3 "$COMM_PY" \
    --ranks-c0 "$DUMP_ROOT/C0_baseline/ranks" \
    --ranks-c1 "$DUMP_ROOT/C1_inject_none/ranks" \
    --window-start "$INJECT_START" \
    --window-stop "$INJECT_STOP" \
    --accept-min-ratio "$ACCEPT_MIN_RATIO" \
    --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json" \
    --verdict "$DUMP_ROOT/CONTRAST_VERDICT.md" || true
fi

echo "CONTRAST_DONE RUN=$RUN DUMP=$DUMP_ROOT"
