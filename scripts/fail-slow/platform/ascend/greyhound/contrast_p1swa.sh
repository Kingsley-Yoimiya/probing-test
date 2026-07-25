#!/usr/bin/env bash
# P1-SW-A Loud contrast on yysong-worker-1: INLINE 2a mem-frag + Greyhound collect-min.
# Frozen dose (dose_recipes calibrated):
#   chunks=12,stall_mb=768,stall_s=0.25
# Window [100,300]; mode=gpu_bound; victim local_rank=7.
# Verdict: collect_seq 真实 per-rank + Rbeast + C0 假阳性对照（不改对手阈值）。
# Do NOT inherit hold-job MASTER_ADDR (often yysong-master-0.yysong).
set -euo pipefail

SO="${SO:-/data/yinjinrun.p-huawei/probe-bundle/greyhound/libhcclprobe.so}"
STUB="${STUB:-/data/yinjinrun.p-huawei/opt/rbeast-fix/libbuiltin_readcyclecounter.so}"
TBP="${TBP:-/data/yinjinrun.p-huawei/probe-bundle/train_bench_probe_npu.py}"
TS="$(date +%Y%m%d_%H%M%S)"
RUN="${RUN:-contrast-p1-sw-a-${TS}}"
DUMP_ROOT="${DUMP_ROOT:-/data/yinjinrun.p-huawei/results/ascend-ais/baseline/greyhound/$RUN}"
NPROC="${NPROC:-16}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
INJECT_START="${INJECT_START:-100}"
INJECT_STOP="${INJECT_STOP:-300}"
CHUNKS="${INLINE_2A_CHUNKS:-12}"
STALL_MB="${INLINE_2A_STALL_MB:-768}"
STALL_S="${INLINE_2A_STALL_S:-0.25}"
VICTIM_LOCAL="${VICTIM_LOCAL:-7}"
MASTER_PORT_C0="${MASTER_PORT_C0:-30370}"
MASTER_PORT_C1="${MASTER_PORT_C1:-30371}"
MASTER_ADDR="${MASTER_ADDR:-}"
CASE_REF="${CASE_REF:-20260725_114556-yjr-as-c-p1-sw-a-loud}"
ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"

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

# Volcano 壳常注入 MASTER_ADDR=yysong-master-0；单 pod 对照必须用本机 eth0 / 127.0.0.1
if [[ -z "${MASTER_ADDR:-}" || "$MASTER_ADDR" == *master* || "$MASTER_ADDR" == *yysong-master* ]]; then
  MASTER_ADDR=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
  if [[ -z "$MASTER_ADDR" ]]; then
    MASTER_ADDR=$(python3 -c 'import socket; print(socket.gethostbyname(socket.gethostname()))' 2>/dev/null || true)
  fi
  MASTER_ADDR=${MASTER_ADDR:-127.0.0.1}
fi

test -f "$SO" || { echo "missing $SO"; exit 2; }
test -f "$STUB" || { echo "missing cyclecounter stub $STUB"; exit 2; }
test -f "$TBP" || { echo "missing $TBP"; exit 2; }

# only kill OUR leftovers on worker-1
pkill -9 -x stress-ng 2>/dev/null || true
pkill -9 -f '[t]bp_npu.py' 2>/dev/null || true
pkill -9 -f '[t]orchrun.*tbp_npu' 2>/dev/null || true
sleep 1

mkdir -p "$DUMP_ROOT" "$CKPT_DIR"

echo "MASTER_ADDR=$MASTER_ADDR NPROC=$NPROC RUN=$RUN chunks=${CHUNKS} stall_mb=${STALL_MB} stall_s=${STALL_S}"
echo "$RUN" > /tmp/gh_p1swa_run.txt
echo "$DUMP_ROOT" > /tmp/gh_p1swa_dump.txt

# ensure redis
if ! /data/yinjinrun.p-huawei/opt/redis/bin/redis-cli -h 127.0.0.1 -p 16379 ping 2>/dev/null | grep -q PONG; then
  bash /data/yinjinrun.p-huawei/probe-bundle/greyhound/greyhound-src/start_redis.sh || true
fi

cat >"$DUMP_ROOT/manifest.yaml" <<EOF
case_id: P1-SW-A
dose: loud
phase: contrast
run_id: $RUN
case_ref: $CASE_REF
world_size: $NPROC
pod: yysong-worker-1
pool: pool-gh
mode: gpu_bound
inject_kind: inline_2a
inject_args: "chunks=${CHUNKS},stall_mb=${STALL_MB},stall_s=${STALL_S}"
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
script: platform/ascend/greyhound/contrast_p1swa.sh
accept_min_ratio: ${ACCEPT_MIN_RATIO}
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

  unset INLINE_INJECT INLINE_VICTIM_LOCAL_RANK INLINE_INJECT_START INLINE_INJECT_STOP \
        INLINE_2A_CHUNKS INLINE_2A_STALL_MB INLINE_2A_STALL_S INLINE_HBM_MB INLINE_HBM_COPIES \
        INLINE_CUBE_SIZE INLINE_CUBE_MM INLINE_GC_EVERY INLINE_GC_STALL_S 2>/dev/null || true
  if [[ "$do_inject" == "1" ]]; then
    export INLINE_INJECT=2a
    export INLINE_VICTIM_LOCAL_RANK="$VICTIM_LOCAL"
    export INLINE_INJECT_START="$INJECT_START"
    export INLINE_INJECT_STOP="$INJECT_STOP"
    export INLINE_2A_CHUNKS="$CHUNKS"
    export INLINE_2A_STALL_MB="$STALL_MB"
    export INLINE_2A_STALL_S="$STALL_S"
  fi

  echo "========== $arm port=$port inject=$do_inject 2a chunks=${CHUNKS} stall_mb=${STALL_MB} stall_s=${STALL_S} =========="
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
    while [[ $e -lt 2400 ]]; do
      if [[ -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
        echo "  measure step ${INJECT_START} (${e}s) — inline 2a frag active"
        break
      fi
      if [[ -f "$out/node_0.fail" ]]; then echo "FAIL before inject"; tail -80 "$out/node_0.log"; return 1; fi
      if [[ -f "$out/node_0.done" ]]; then echo "FAIL train ended before inject start"; return 1; fi
      sleep 1; e=$((e + 1))
    done
    if [[ ! -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
      echo "FAIL never reached inject start"; return 1
    fi
    grep -E "INLINE_2A|SIDECAR" "$out/node_0.log" 2>/dev/null | head -20 >"$out/injection.log" || true
    echo "SIDECAR_START kind=inline_2a chunks=${CHUNKS} stall_mb=${STALL_MB} stall_s=${STALL_S} victim=${VICTIM_LOCAL}" >>"$out/injection.log"
  fi

  e=0
  while [[ $e -lt 2400 ]]; do
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
      echo "  waiting… t=${e}s dump=$(wc -l <"$GREYHOUND_DUMP" 2>/dev/null | tr -d ' ')"
    fi
  done
  echo "TIMEOUT"; tail -80 "$out/node_0.log" || true
  kill "$train_pid" 2>/dev/null || true
  return 1
}

run_arm C0_baseline "$MASTER_PORT_C0" 0
run_arm C1_inject_none "$MASTER_PORT_C1" 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="/data/yinjinrun.p-huawei/opt/pydeps${PYTHONPATH:+:$PYTHONPATH}"
export GREYHOUND_RBEAST_STUB="${STUB}"
DOSE_DESC="INLINE 2a chunks=${CHUNKS} stall_mb=${STALL_MB} stall_s=${STALL_S} victim=${VICTIM_LOCAL}; window [${INJECT_START},${INJECT_STOP}]"
LD_PRELOAD="${STUB}${LD_PRELOAD:+:$LD_PRELOAD}" \
  /root/miniconda3/envs/llm_test/bin/python3 "$SCRIPT_DIR/s4_verdict.py" \
  --dump-root "$DUMP_ROOT" \
  --inject-start "$INJECT_START" \
  --inject-stop "$INJECT_STOP" \
  --accept-min-ratio "$ACCEPT_MIN_RATIO" \
  --case-id P1-SW-A \
  --case-ref "$CASE_REF" \
  --dose-desc "$DOSE_DESC" \
  --tool greyhound \
  --run-id "$RUN" \
  --pod yysong-worker-1 \
  --out "$DUMP_ROOT/CONTRAST_VERDICT.md" \
  --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json"
echo "CONTRAST_DONE RUN=$RUN DUMP=$DUMP_ROOT"
